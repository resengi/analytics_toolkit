import '../query/measure.dart';
import '../schema/schema.dart';
import '../schema/typed_value.dart';
import 'source_record.dart';

/// Aggregates a group of `SourceRecord`s into a single typed value.
///
/// The validator has already ensured the aggregation is compatible
/// with the field type, and `AnalyticsExecutor` has already rejected
/// records whose [TypedValue] subtype does not match the declared
/// [FieldType] for that field. Each per-type branch therefore inspects
/// only the [TypedValue] subtype that matches the declared field type;
/// nothing is silently coerced or skipped here.
///
/// ## Output type table
///
/// Each (aggregation × field-type) combination has a deterministic
/// output type, used to populate `ScalarResult.value`,
/// `SeriesBucket.value`, `NamedSeries.values`, `MeasureSeries.values`,
/// and `TableColumn.values` for measure columns:
///
/// | Aggregation        | int            | double         | duration         | dateTime        |
/// |--------------------|----------------|----------------|------------------|-----------------|
/// | `count`*           | `IntValue`     | `IntValue`     | `IntValue`       | `IntValue`      |
/// | `SumAgg`           | `IntValue`     | `DoubleValue`  | `DurationValue`  | (rejected)      |
/// | `AverageAgg`       | `DoubleValue`  | `DoubleValue`  | `DurationValue`  | (rejected)      |
/// | `MinAgg`/`MaxAgg`  | `IntValue`     | `DoubleValue`  | `DurationValue`  | `DateTimeValue` |
/// | `DistinctCountAgg` | `IntValue`     | `IntValue`     | `IntValue`       | `IntValue`      |
/// | `PercentileAgg`    | `DoubleValue`  | `DoubleValue`  | `DurationValue`  | (rejected)      |
///
/// `count` does not take a field; it always returns `IntValue`.
/// String, enum, and bool fields support only `DistinctCountAgg` (the
/// validator rejects other aggregations on them).
///
/// ## Empty / all-null groups
///
/// * **Additive aggregations** (`count`, `SumAgg`, `DistinctCountAgg`)
///   return the additive identity (`IntValue(0)` / `DoubleValue(0)` /
///   `DurationValue(Duration.zero)`).
/// * **Non-additive aggregations** (`AverageAgg`, `MinAgg`, `MaxAgg`,
///   `PercentileAgg`) return `null` — the operation is undefined over
///   zero values.
///
/// Records with a `NullValue` or missing field are skipped by every
/// aggregation. They never contribute to the math.
abstract class AggregationEngine {
  /// Counts records in [group]. Used by `CountMeasure`.
  ///
  /// Returns `IntValue(group.length)`. Records with null field values
  /// are still counted — `count` does not look at any field.
  static TypedValue count(Iterable<SourceRecord> group) =>
      IntValue(group.length);

  /// Aggregates the values of [field] in [group] using [aggregation].
  ///
  /// Returns `null` for non-additive aggregations on empty / all-null
  /// groups; returns a typed zero for additive aggregations. See the
  /// class doc for the full output-type table.
  static TypedValue? aggregateField(
    Iterable<SourceRecord> group,
    FieldDef field,
    FieldAggregation aggregation,
  ) {
    switch (aggregation) {
      case SumAgg():
        return _sum(group, field);
      case AverageAgg():
        return _average(group, field);
      case MinAgg():
        return _extremum(group, field, ascending: true);
      case MaxAgg():
        return _extremum(group, field, ascending: false);
      case DistinctCountAgg():
        return _distinctCount(group, field);
      case PercentileAgg(p: final p):
        return _percentile(group, field, p);
    }
  }

  // ── sum ───────────────────────────────────────────────────────────────

  static TypedValue _sum(Iterable<SourceRecord> group, FieldDef field) {
    switch (field.fieldType) {
      case FieldType.integer:
        int total = 0;
        for (final r in group) {
          final v = r[field.fieldId];
          if (v is IntValue) total += v.value;
        }
        return IntValue(total);
      case FieldType.double:
        double total = 0;
        for (final r in group) {
          final v = r[field.fieldId];
          if (v is DoubleValue) total += v.value;
        }
        return DoubleValue(total);
      case FieldType.duration:
        var total = Duration.zero;
        for (final r in group) {
          final v = r[field.fieldId];
          if (v is DurationValue) total += v.value;
        }
        return DurationValue(total);
      case FieldType.string:
      case FieldType.enumeration:
      case FieldType.boolean:
      case FieldType.dateTime:
        // Unreachable: validator rejects sum on non-additive types.
        // Throw so validator gaps surface as bugs instead of being
        // silently masked by a bogus zero.
        throw StateError(
          'AggregationEngine._sum: unreachable for field type '
          '${field.fieldType.name}; validator should have rejected.',
        );
    }
  }

  // ── average ───────────────────────────────────────────────────────────

  static TypedValue? _average(Iterable<SourceRecord> group, FieldDef field) {
    switch (field.fieldType) {
      case FieldType.integer:
        int total = 0;
        int count = 0;
        for (final r in group) {
          final v = r[field.fieldId];
          if (v is IntValue) {
            total += v.value;
            count++;
          }
        }
        return count == 0 ? null : DoubleValue(total / count);
      case FieldType.double:
        double total = 0;
        int count = 0;
        for (final r in group) {
          final v = r[field.fieldId];
          if (v is DoubleValue) {
            total += v.value;
            count++;
          }
        }
        return count == 0 ? null : DoubleValue(total / count);
      case FieldType.duration:
        int totalMicros = 0;
        int count = 0;
        for (final r in group) {
          final v = r[field.fieldId];
          if (v is DurationValue) {
            totalMicros += v.value.inMicroseconds;
            count++;
          }
        }
        return count == 0
            ? null
            : DurationValue(Duration(microseconds: totalMicros ~/ count));
      case FieldType.string:
      case FieldType.enumeration:
      case FieldType.boolean:
      case FieldType.dateTime:
        // Unreachable: validator rejects average on non-numeric types.
        throw StateError(
          'AggregationEngine._average: unreachable for field type '
          '${field.fieldType.name}; validator should have rejected.',
        );
    }
  }

  // ── min / max ─────────────────────────────────────────────────────────

  /// Min when `ascending == true`, max when `ascending == false`.
  /// Returns `null` if [group] has no non-null values for [field].
  static TypedValue? _extremum(
    Iterable<SourceRecord> group,
    FieldDef field, {
    required bool ascending,
  }) {
    bool wins<T extends Comparable<T>>(T a, T b) =>
        ascending ? a.compareTo(b) < 0 : a.compareTo(b) > 0;

    switch (field.fieldType) {
      case FieldType.integer:
        int? best;
        for (final r in group) {
          final v = r[field.fieldId];
          if (v is IntValue) {
            if (best == null || wins(v.value, best)) best = v.value;
          }
        }
        return best == null ? null : IntValue(best);
      case FieldType.double:
        double? best;
        for (final r in group) {
          final v = r[field.fieldId];
          if (v is DoubleValue) {
            if (best == null || wins(v.value, best)) best = v.value;
          }
        }
        return best == null ? null : DoubleValue(best);
      case FieldType.duration:
        Duration? best;
        for (final r in group) {
          final v = r[field.fieldId];
          if (v is DurationValue) {
            if (best == null || wins(v.value, best)) best = v.value;
          }
        }
        return best == null ? null : DurationValue(best);
      case FieldType.dateTime:
        DateTime? best;
        for (final r in group) {
          final v = r[field.fieldId];
          if (v is DateTimeValue) {
            if (best == null || wins(v.value, best)) best = v.value;
          }
        }
        return best == null ? null : DateTimeValue(best);
      case FieldType.string:
      case FieldType.enumeration:
      case FieldType.boolean:
        // Unreachable: validator rejects min/max on non-ordered types.
        throw StateError(
          'AggregationEngine._extremum: unreachable for field type '
          '${field.fieldType.name}; validator should have rejected.',
        );
    }
  }

  // ── distinctCount ─────────────────────────────────────────────────────

  /// Returns the count of distinct non-null values in [group] for
  /// [field], boxed as an [IntValue].
  ///
  /// Relies on [TypedValue.raw] being a scalar value with structural
  /// equality (string, num, bool, DateTime, Duration). No `FieldType`
  /// corresponds to a list-valued record field — the list-shaped
  /// [TypedValue]s exist only as `inList` filter operands — so the
  /// identity-equality problem of using a `List` as a `Set` key never
  /// arises in this code path.
  static TypedValue _distinctCount(
    Iterable<SourceRecord> group,
    FieldDef field,
  ) {
    final seen = <Object>{};
    for (final r in group) {
      final v = r[field.fieldId];
      if (v == null || v is NullValue) continue;
      final raw = v.raw;
      if (raw != null) seen.add(raw);
    }
    return IntValue(seen.length);
  }

  // ── percentile ────────────────────────────────────────────────────────

  /// Returns the value at percentile [p] of the non-null values of
  /// [field] in [group], using linear interpolation between the two
  /// surrounding sample indices ("type 7" interpolation, as used by
  /// NumPy and most BI tools).
  ///
  /// Concretely: collect the non-null values, sort, compute the
  /// fractional index `p × (n - 1)`, and interpolate linearly between
  /// the values at floor and ceiling of that index. When floor and
  /// ceiling coincide (the boundary cases p=0 and p=1, or when the
  /// fractional index lands on an integer), the value at that index
  /// is returned directly.
  ///
  /// Returns `null` for empty / all-null groups — percentile of zero
  /// values is undefined, matching the convention `_average` and
  /// `_extremum` use for the same case.
  ///
  /// [p] is assumed to be in `[0, 1]`; the validator enforces this
  /// upstream. Calling with an out-of-range value will produce a
  /// nonsensical (but non-crashing) result — this branch trusts the
  /// validator.
  static TypedValue? _percentile(
    Iterable<SourceRecord> group,
    FieldDef field,
    double p,
  ) {
    switch (field.fieldType) {
      case FieldType.integer:
        final values = <int>[];
        for (final r in group) {
          final v = r[field.fieldId];
          if (v is IntValue) values.add(v.value);
        }
        if (values.isEmpty) return null;
        values.sort();
        return DoubleValue(_interpolateInt(values, p));
      case FieldType.double:
        final values = <double>[];
        for (final r in group) {
          final v = r[field.fieldId];
          if (v is DoubleValue) values.add(v.value);
        }
        if (values.isEmpty) return null;
        values.sort();
        return DoubleValue(_interpolateDouble(values, p));
      case FieldType.duration:
        final values = <int>[]; // microseconds
        for (final r in group) {
          final v = r[field.fieldId];
          if (v is DurationValue) values.add(v.value.inMicroseconds);
        }
        if (values.isEmpty) return null;
        values.sort();
        final micros = _interpolateInt(values, p).round();
        return DurationValue(Duration(microseconds: micros));
      case FieldType.string:
      case FieldType.enumeration:
      case FieldType.boolean:
      case FieldType.dateTime:
        // Unreachable: validator rejects percentile on non-numeric /
        // non-duration types.
        throw StateError(
          'AggregationEngine._percentile: unreachable for field type '
          '${field.fieldType.name}; validator should have rejected.',
        );
    }
  }

  /// Linear interpolation between the two surrounding indices of a
  /// sorted `List<int>`. Treats the input as numeric for the purpose
  /// of interpolation; the caller is responsible for boxing the
  /// result into the appropriate `TypedValue` subtype.
  static double _interpolateInt(List<int> sortedValues, double p) {
    final n = sortedValues.length;
    if (n == 1) return sortedValues[0].toDouble();
    final idx = p * (n - 1);
    final lo = idx.floor();
    final hi = idx.ceil();
    if (lo == hi) return sortedValues[lo].toDouble();
    final frac = idx - lo;
    return sortedValues[lo] * (1 - frac) + sortedValues[hi] * frac;
  }

  /// Same as [_interpolateInt] but for a sorted `List<double>`.
  /// Separate function rather than a generic-over-`num` version
  /// because Dart's `num` arithmetic returns `num`, which would
  /// require additional casts at every call site.
  static double _interpolateDouble(List<double> sortedValues, double p) {
    final n = sortedValues.length;
    if (n == 1) return sortedValues[0];
    final idx = p * (n - 1);
    final lo = idx.floor();
    final hi = idx.ceil();
    if (lo == hi) return sortedValues[lo];
    final frac = idx - lo;
    return sortedValues[lo] * (1 - frac) + sortedValues[hi] * frac;
  }
}
