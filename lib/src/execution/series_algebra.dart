import '../errors.dart';
import '../query/query_components.dart';
import '../results.dart';
import 'derived_engine.dart';
import 'series_numeric.dart';

/// Applies series operations to a `SeriesResult` already in hand.
///
/// This is the imperative counterpart to declaring an operation inside a
/// query. It requires no query, no re-fetch, and no re-aggregation:
/// pass a result and an operation, get a new result back. Results are
/// immutable, so the input series is never modified.
///
/// Three entry points cover the three operation families:
///
/// * [apply] — a whole-series [DerivedOperation] (cumulative sum, delta,
///   moving average).
/// * [transform] — a per-value [ScalarOp] (negate, absolute value,
///   fill-null).
/// * [combine] — a binary [SeriesCombination] of two held series (sum,
///   difference, product, ratio).
///
/// Every entry point validates its own operands and returns a [Result];
/// none throws for an invalid combination. Because operations chain
/// freely here, this is also the way to express an ordering a single
/// query spec cannot — for example a per-value op layered on top of a
/// whole-series op, `series.cumulativeSum().andThen((s) => s.negated())`.
///
/// The arithmetic and type rules are shared with the in-query path, so
/// the two never disagree.
abstract class SeriesAlgebra {
  /// Applies a whole-series [op] to [series].
  ///
  /// Returns the input unchanged for [NoDerivedOp]. Returns an
  /// `incompatibleSeriesCombination` error when [series] is not numeric.
  static Result<SeriesResult, AnalyticsError> apply(
    SeriesResult series,
    DerivedOperation op,
  ) {
    if (op is NoDerivedOp) return Ok(series);
    if (!isNumericFieldType(series.measureFieldType)) {
      return _incompatible(
        'A derived operation requires a numeric series; '
        '${series.measureFieldType.name} is not numeric.',
      );
    }
    return Ok(DerivedEngine.apply(series, op));
  }

  /// Applies a per-value [op] to every bucket of [series], preserving
  /// the series' keys, ordering, synthetic flags, and measure type.
  ///
  /// Returns an `incompatibleSeriesCombination` error when [series] is
  /// not numeric.
  static Result<SeriesResult, AnalyticsError> transform(
    SeriesResult series,
    ScalarOp op,
  ) {
    if (!isNumericFieldType(series.measureFieldType)) {
      return _incompatible(
        'A per-value operation requires a numeric series; '
        '${series.measureFieldType.name} is not numeric.',
      );
    }
    final buckets = <SeriesBucket>[
      for (final b in series.buckets)
        SeriesBucket(
          key: b.key,
          value: applyScalarValue(op, b.value, series.measureFieldType),
          isSynthetic: b.isSynthetic,
          displayLabel: b.displayLabel,
        ),
    ];
    return Ok(
      SeriesResult(
        buckets: buckets,
        groupKind: series.groupKind,
        groupColumnLabel: series.groupColumnLabel,
        groupColumnFieldType: series.groupColumnFieldType,
        measureLabel: series.measureLabel,
        measureFieldType: series.measureFieldType,
        semanticTag: series.semanticTag,
      ),
    );
  }

  /// Combines two held series [x] and [y] under [op], aligning them by
  /// bucket key.
  ///
  /// [policy] decides how a key present in only one series is treated
  /// ([UnmatchedBucketPolicy.drop] keeps the intersection;
  /// [UnmatchedBucketPolicy.fillIdentity] keeps the union, filling an
  /// absent side with the combination's identity — though a ratio,
  /// having no identity, still omits a key absent on either side). A
  /// present key whose combined value is null is always retained; null
  /// propagates and is never dropped.
  ///
  /// The result inherits [x]'s group metadata and uses [op]'s output
  /// type for the measure. [measureLabel], [groupColumnLabel], and
  /// [semanticTag] override the inherited values when supplied.
  ///
  /// Returns an `incompatibleSeriesCombination` error when either series
  /// is non-numeric, when the two series have incompatible group
  /// dimensions (different group kind or group field type), or when the
  /// measure types cannot be combined under [op]. Empty or fully
  /// unmatched inputs yield an empty but valid series, not an error.
  static Result<SeriesResult, AnalyticsError> combine(
    SeriesResult x,
    SeriesResult y, {
    required SeriesCombination op,
    UnmatchedBucketPolicy policy = UnmatchedBucketPolicy.drop,
    String? measureLabel,
    String? groupColumnLabel,
    String? semanticTag,
  }) {
    if (!isNumericFieldType(x.measureFieldType) ||
        !isNumericFieldType(y.measureFieldType)) {
      return _incompatible(
        'Both series must be numeric to combine; got '
        '${x.measureFieldType.name} and ${y.measureFieldType.name}.',
      );
    }
    if (x.groupKind != y.groupKind ||
        x.groupColumnFieldType != y.groupColumnFieldType) {
      return _incompatible(
        'Series have incompatible group dimensions: '
        '${x.groupKind.name}/${x.groupColumnFieldType.name} versus '
        '${y.groupKind.name}/${y.groupColumnFieldType.name}.',
      );
    }
    final outType = combineOutputType(
      x.measureFieldType,
      y.measureFieldType,
      op,
    );
    if (outType == null) {
      return _incompatible(
        'Series of ${x.measureFieldType.name} and '
        '${y.measureFieldType.name} cannot be combined under this '
        'operation.',
      );
    }

    final xByKey = {for (final b in x.buckets) b.key: b};
    final yByKey = {for (final b in y.buckets) b.key: b};

    final outBuckets = <SeriesBucket>[];
    switch (policy) {
      case UnmatchedBucketPolicy.drop:
        // Intersection, in x's order. A key absent on either side is
        // omitted; a present key with a null combined value is kept.
        for (final xb in x.buckets) {
          final yb = yByKey[xb.key];
          if (yb == null) continue;
          outBuckets.add(
            SeriesBucket(
              key: xb.key,
              value: combinePerValue(xb.value, yb.value, op, outType),
              isSynthetic: xb.isSynthetic && yb.isSynthetic,
            ),
          );
        }
      case UnmatchedBucketPolicy.fillIdentity:
        // Union, sorted nulls-last. An absent side is filled with the
        // combination's identity; a ratio has none, so a key absent on
        // either side is omitted.
        final identity = combinationIdentity(op);
        for (final key in _unionKeysSorted(x.buckets, y.buckets)) {
          final xb = xByKey[key];
          final yb = yByKey[key];
          if (xb != null && yb != null) {
            outBuckets.add(
              SeriesBucket(
                key: key,
                value: combinePerValue(xb.value, yb.value, op, outType),
                isSynthetic: xb.isSynthetic && yb.isSynthetic,
              ),
            );
            continue;
          }
          if (identity == null) continue;
          if (xb == null) {
            final xValue = boxFromDouble(identity, x.measureFieldType);
            outBuckets.add(
              SeriesBucket(
                key: key,
                value: combinePerValue(xValue, yb!.value, op, outType),
                isSynthetic: yb.isSynthetic,
              ),
            );
          } else {
            final yValue = boxFromDouble(identity, y.measureFieldType);
            outBuckets.add(
              SeriesBucket(
                key: key,
                value: combinePerValue(xb.value, yValue, op, outType),
                isSynthetic: xb.isSynthetic,
              ),
            );
          }
        }
    }

    return Ok(
      SeriesResult(
        buckets: outBuckets,
        groupKind: x.groupKind,
        groupColumnLabel: groupColumnLabel ?? x.groupColumnLabel,
        groupColumnFieldType: x.groupColumnFieldType,
        measureLabel: measureLabel ?? x.measureLabel,
        measureFieldType: outType,
        semanticTag: semanticTag ?? x.semanticTag,
      ),
    );
  }

  /// The union of the two bucket lists' keys, deduplicated by value
  /// equality and sorted with [BucketKeyOrdering.compareNullsLast].
  static List<BucketKey> _unionKeysSorted(
    List<SeriesBucket> x,
    List<SeriesBucket> y,
  ) {
    final keys = <BucketKey>{
      for (final b in x) b.key,
      for (final b in y) b.key,
    };
    final ordered = keys.toList();
    ordered.sort(BucketKeyOrdering.compareNullsLast);
    return ordered;
  }

  static Err<SeriesResult, AnalyticsError> _incompatible(String message) => Err(
    AnalyticsError(
      kind: AnalyticsErrorKind.incompatibleSeriesCombination,
      humanMessage: message,
    ),
  );
}

/// Ergonomic chaining over [SeriesAlgebra]. Each method is thin sugar
/// over the corresponding static and returns a [Result], so calls chain
/// with [Result.andThen] regardless of which operation family they
/// belong to.
extension SeriesAlgebraX on SeriesResult {
  /// Running total. See [CumulativeSumOp].
  Result<SeriesResult, AnalyticsError> cumulativeSum() =>
      SeriesAlgebra.apply(this, const CumulativeSumOp());

  /// Period-over-period difference. See [DeltaOp].
  Result<SeriesResult, AnalyticsError> delta() =>
      SeriesAlgebra.apply(this, const DeltaOp());

  /// Rolling average over a sliding window. See [MovingAverageOp].
  Result<SeriesResult, AnalyticsError> movingAverage(int window) =>
      SeriesAlgebra.apply(this, MovingAverageOp(window: window));

  /// Negates every value. See [NegateOp].
  Result<SeriesResult, AnalyticsError> negated() =>
      SeriesAlgebra.transform(this, const NegateOp());

  /// Maps every value to its absolute value. See [AbsOp].
  Result<SeriesResult, AnalyticsError> absolute() =>
      SeriesAlgebra.transform(this, const AbsOp());

  /// Replaces null values with [fill]. See [FillNullOp].
  Result<SeriesResult, AnalyticsError> fillNull(num fill) =>
      SeriesAlgebra.transform(this, FillNullOp(fill));

  /// Combines this series with [other] under [op]. See
  /// [SeriesAlgebra.combine].
  Result<SeriesResult, AnalyticsError> combineWith(
    SeriesResult other,
    SeriesCombination op, {
    UnmatchedBucketPolicy policy = UnmatchedBucketPolicy.drop,
  }) => SeriesAlgebra.combine(this, other, op: op, policy: policy);
}
