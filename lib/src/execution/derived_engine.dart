import '../query/query_components.dart';
import '../results.dart';
import '../schema/typed_value.dart';

/// Applies a `DerivedOperation` to a `SeriesResult`.
///
/// Derived operations transform the values of a series and produce
/// another series of the same shape — they never change the result
/// kind, bucket count, or bucket keys. Output value types and null
/// handling are documented on [DerivedOperation]; this class is the
/// engine that implements those rules.
abstract class DerivedEngine {
  /// Returns a new `SeriesResult` with [op] applied to the values of
  /// [series]. `NoDerivedOp` returns the input unchanged.
  ///
  /// If [series] has no non-null buckets at all, the operation is a
  /// no-op (there is no input type to infer).
  static SeriesResult apply(SeriesResult series, DerivedOperation op) {
    if (op is NoDerivedOp) return series;

    // Find a reference TypedValue from the first non-null bucket. If
    // every bucket is null, the operation is a no-op — short-circuit
    // before computing any transformed values.
    TypedValue? reference;
    for (final b in series.buckets) {
      if (b.value != null) {
        reference = b.value;
        break;
      }
    }
    if (reference == null) return series;

    switch (op) {
      case NoDerivedOp():
        // Unreachable: handled by the early return above. Listed for
        // Dart's exhaustiveness checker.
        return series;
      case CumulativeSumOp():
        return _withTransformedValues(
          series,
          _cumulativeSum(series.buckets),
          reference,
          preserveInputType: true,
        );
      case DeltaOp():
        return _withTransformedValues(
          series,
          _delta(series.buckets),
          reference,
          preserveInputType: true,
        );
      case MovingAverageOp(window: final window):
        return _withTransformedValues(
          series,
          _movingAverage(series.buckets, window),
          reference,
          preserveInputType: reference is DurationValue,
        );
    }
  }

  // ── Transformations ───────────────────────────────────────────────────

  static List<double> _cumulativeSum(List<SeriesBucket> buckets) {
    double running = 0;
    return [for (final b in buckets) running += (_toDouble(b.value) ?? 0)];
  }

  /// Period-over-period delta. First bucket has delta 0.
  static List<double> _delta(List<SeriesBucket> buckets) {
    if (buckets.isEmpty) return const [];
    final out = <double>[0];
    for (int i = 1; i < buckets.length; i++) {
      final cur = _toDouble(buckets[i].value) ?? 0;
      final prev = _toDouble(buckets[i - 1].value) ?? 0;
      out.add(cur - prev);
    }
    return out;
  }

  /// Simple moving average. Buckets before the window is full use a
  /// partial window. The validator has already ensured `window > 0`.
  static List<double> _movingAverage(List<SeriesBucket> buckets, int window) {
    if (buckets.isEmpty) return const [];
    final out = <double>[];
    for (int i = 0; i < buckets.length; i++) {
      final start = (i - window + 1).clamp(0, i);
      double sum = 0;
      for (int j = start; j <= i; j++) {
        sum += _toDouble(buckets[j].value) ?? 0;
      }
      out.add(sum / (i - start + 1));
    }
    return out;
  }

  // ── Helpers ───────────────────────────────────────────────────────────

  /// Projects a numeric typed value to a `double` for arithmetic.
  /// Returns `null` only when the input itself is `null` (signalling
  /// an empty / undefined bucket). Throws for non-numeric concrete
  /// values — those should have been rejected by the validator's
  /// `derivedOpRequiresNumericMeasure` check.
  static double? _toDouble(TypedValue? v) {
    if (v == null) return null;
    switch (v) {
      case IntValue(value: final n):
        return n.toDouble();
      case DoubleValue(value: final n):
        return n;
      case DurationValue(value: final d):
        return d.inMicroseconds.toDouble();
      case StringValue():
      case EnumValue():
      case BoolValue():
      case DateTimeValue():
      case StringListValue():
      case EnumListValue():
      case IntListValue():
      case NullValue():
        throw StateError(
          'DerivedEngine._toDouble: unreachable for non-numeric '
          'TypedValue ${v.runtimeType}; validator should have '
          'rejected this derived operation.',
        );
    }
  }

  /// Boxes a `double` result back to a typed value of the same family
  /// as [reference] (when [preserveInputType] is true), or always to
  /// `DoubleValue` (when false).
  static TypedValue _fromDouble(
    double n,
    TypedValue reference, {
    required bool preserveInputType,
  }) {
    if (!preserveInputType) return DoubleValue(n);
    switch (reference) {
      case IntValue():
        return IntValue(n.round());
      case DoubleValue():
        return DoubleValue(n);
      case DurationValue():
        return DurationValue(Duration(microseconds: n.round()));
      case StringValue():
      case EnumValue():
      case BoolValue():
      case DateTimeValue():
      case StringListValue():
      case EnumListValue():
      case IntListValue():
      case NullValue():
        throw StateError(
          'DerivedEngine._fromDouble: unreachable for non-numeric '
          'reference ${reference.runtimeType}; validator should have '
          'rejected this derived operation.',
        );
    }
  }

  static SeriesResult _withTransformedValues(
    SeriesResult series,
    List<double> newValues,
    TypedValue reference, {
    required bool preserveInputType,
  }) {
    final newBuckets = <SeriesBucket>[
      for (int i = 0; i < series.buckets.length; i++)
        SeriesBucket(
          key: series.buckets[i].key,
          value: _fromDouble(
            i < newValues.length ? newValues[i] : 0,
            reference,
            preserveInputType: preserveInputType,
          ),
          isSynthetic: series.buckets[i].isSynthetic,
          displayLabel: series.buckets[i].displayLabel,
        ),
    ];
    return SeriesResult(
      buckets: newBuckets,
      groupKind: series.groupKind,
      groupColumnLabel: series.groupColumnLabel,
      groupColumnFieldType: series.groupColumnFieldType,
      measureLabel: series.measureLabel,
      measureFieldType: series.measureFieldType,
      semanticTag: series.semanticTag,
    );
  }
}
