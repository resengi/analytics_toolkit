import '../query/query_components.dart';
import '../results.dart';
import '../schema/schema.dart';
import 'series_numeric.dart';

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
  /// no-op (there is no value to transform).
  static SeriesResult apply(SeriesResult series, DerivedOperation op) {
    // No operation requested — return the input untouched without
    // scanning the buckets.
    if (op is NoDerivedOp) return series;

    // An all-null series has no values to transform, so every derived
    // operation is a no-op. Checking first also avoids building a
    // transformed bucket list for that case.
    final hasValue = series.buckets.any((b) => b.value != null);
    if (!hasValue) return series;

    final outType = _outputType(op, series.measureFieldType);
    switch (op) {
      case NoDerivedOp():
        // Unreachable: handled by the early return above. Listed for
        // the exhaustiveness checker.
        return series;
      case CumulativeSumOp():
        return _withTransformedValues(
          series,
          _cumulativeSum(series.buckets),
          outType,
        );
      case DeltaOp():
        return _withTransformedValues(series, _delta(series.buckets), outType);
      case MovingAverageOp(window: final window):
        return _withTransformedValues(
          series,
          _movingAverage(series.buckets, window),
          outType,
        );
    }
  }

  /// The `FieldType` each derived op boxes its `double` results into,
  /// given the series' measure type. Cumulative sum and delta preserve
  /// the measure type; moving average preserves `duration` but produces
  /// a `double` for integer and double inputs (the average of integers
  /// is generally fractional).
  static FieldType _outputType(DerivedOperation op, FieldType measureType) {
    switch (op) {
      case NoDerivedOp():
      case CumulativeSumOp():
      case DeltaOp():
        return measureType;
      case MovingAverageOp():
        return measureType == FieldType.duration
            ? FieldType.duration
            : FieldType.double;
    }
  }

  // ── Transformations ───────────────────────────────────────────────────

  static List<double> _cumulativeSum(List<SeriesBucket> buckets) {
    double running = 0;
    return [
      for (final b in buckets) running += (projectToDouble(b.value) ?? 0),
    ];
  }

  /// Period-over-period delta. First bucket has delta 0.
  static List<double> _delta(List<SeriesBucket> buckets) {
    if (buckets.isEmpty) return const [];
    final out = <double>[0];
    for (int i = 1; i < buckets.length; i++) {
      final cur = projectToDouble(buckets[i].value) ?? 0;
      final prev = projectToDouble(buckets[i - 1].value) ?? 0;
      out.add(cur - prev);
    }
    return out;
  }

  /// Simple moving average. Buckets before the window is full use a
  /// partial window. Callers must ensure `window > 0` (via
  /// `derivedOperationParameterError`); behavior is undefined otherwise.
  static List<double> _movingAverage(List<SeriesBucket> buckets, int window) {
    if (buckets.isEmpty) return const [];
    final out = <double>[];
    for (int i = 0; i < buckets.length; i++) {
      final start = (i - window + 1).clamp(0, i);
      double sum = 0;
      for (int j = start; j <= i; j++) {
        sum += projectToDouble(buckets[j].value) ?? 0;
      }
      out.add(sum / (i - start + 1));
    }
    return out;
  }

  // ── Helpers ───────────────────────────────────────────────────────────

  static SeriesResult _withTransformedValues(
    SeriesResult series,
    List<double> newValues,
    FieldType outType,
  ) {
    final newBuckets = <SeriesBucket>[
      for (int i = 0; i < series.buckets.length; i++)
        SeriesBucket(
          key: series.buckets[i].key,
          value: boxFromDouble(
            i < newValues.length ? newValues[i] : 0,
            outType,
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
      measureFieldType: outType,
      semanticTag: series.semanticTag,
    );
  }
}
