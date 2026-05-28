import '../query/query_components.dart';
import '../results.dart';
import '../schema/typed_value.dart';
import '../time_series/densify.dart';
import '../time_series/grain_arithmetic.dart';
import '../time_series/time_grain.dart';
import 'source_record.dart';

/// Computes the bucket key(s) for a record under one or more
/// `GroupBy` clauses, and densifies temporal bucket-key lists.
///
/// All time-bucket arithmetic delegates to the `TimeGrainArithmetic`
/// extension on [TimeGrain] — this engine never inlines grain math.
///
/// ## Single vs tuple key
///
/// - [keyFor] returns a single [BucketKey] for a single [GroupBy].
///   Used by callers (the executor's scalar/streak paths) that only
///   need per-axis keys.
/// - [keyTupleFor] returns a [RowKey] wrapping the tuple of bucket
///   keys, one per entry in the supplied [GroupBy] list. Used by the
///   executor's grouped-query path for N-level partitioning.
///
/// Both functions share the same per-axis logic — `keyTupleFor`
/// simply iterates [keyFor] over the list.
abstract class GroupingEngine {
  /// Returns the bucket key for [record] under [groupBy].
  ///
  /// Records with a missing or `NullValue` group field produce
  /// [NullBucketKey] so the executor doesn't drop them silently.
  static BucketKey keyFor(SourceRecord record, GroupBy groupBy) {
    switch (groupBy) {
      case FieldGroupBy(fieldRef: final ref):
        return _categoricalKey(record[ref.fieldId]);
      case TimeGroupBy(dateFieldRef: final ref, grain: final grain):
        return _temporalKey(record[ref.fieldId], grain);
    }
  }

  /// Returns the row-key tuple for [record] under a list of
  /// [groupBys]. The result is a [RowKey] whose `keys` are
  /// index-aligned with [groupBys] (so `keys[i]` is the bucket key
  /// from `groupBys[i]`).
  ///
  /// Used by the executor's N-level partition path. For an empty
  /// [groupBys] list this returns a zero-length [RowKey]; the
  /// executor's scalar short-circuit handles that case before
  /// partitioning so this branch never fires in practice.
  static RowKey keyTupleFor(SourceRecord record, List<GroupBy> groupBys) {
    return RowKey([for (final g in groupBys) keyFor(record, g)]);
  }

  // ── Categorical keys ──────────────────────────────────────────────────

  static BucketKey _categoricalKey(TypedValue? value) {
    if (value == null || value is NullValue) return const NullBucketKey();
    switch (value) {
      case StringValue(value: final v):
        return StringBucketKey(v);
      case EnumValue(value: final v):
        return EnumBucketKey(v);
      case BoolValue(value: final v):
        return BoolBucketKey(v);
      case IntValue(value: final v):
        // Numeric typed bucket key so consumers sorting by group
        // field get numeric ordering, not lexical.
        return IntBucketKey(v);
      case DoubleValue(value: final v):
        return DoubleBucketKey(v);
      case DateTimeValue():
        // Unreachable post-validation: the validator rejects
        // FieldGroupBy on dateTime fields (use TimeGroupBy(grain:
        // TimeGrain.day) for explicit day-bucket grouping). Listed
        // for Dart's exhaustiveness checker.
        throw StateError(
          'GroupingEngine._categoricalKey: FieldGroupBy on a dateTime '
          'field should have been rejected by the validator.',
        );
      case DurationValue(value: final v):
        // Durations are represented as integer microseconds in the
        // bucket key so equality is exact.
        return IntBucketKey(v.inMicroseconds);
      case StringListValue():
      case EnumListValue():
      case IntListValue():
        // List-valued types are not supported as record fields. If we
        // hit one here, a source provider violated the contract —
        // surface it loudly rather than silently bucketing into null.
        throw StateError(
          'GroupingEngine._categoricalKey: list-valued field appeared '
          'as a record field (${value.runtimeType}); not supported.',
        );
      case NullValue():
        // Unreachable: the early-return above handles NullValue. Dart's
        // exhaustiveness checker requires we list it.
        return const NullBucketKey();
    }
  }

  // ── Temporal keys ─────────────────────────────────────────────────────

  static BucketKey _temporalKey(TypedValue? value, TimeGrain grain) {
    // The executor's type-validation pass rejects records whose value
    // type doesn't match the declared field type, so a non-null
    // [value] is a [DateTimeValue] here. Only the null and explicit-
    // NullValue cases need their own bucket key.
    if (value == null || value is NullValue) return const NullBucketKey();
    if (value is! DateTimeValue) {
      throw StateError(
        'GroupingEngine._temporalKey: unreachable for non-DateTimeValue '
        '${value.runtimeType}; executor type-validation pass should '
        'have rejected.',
      );
    }
    return TimeBucketKey(
      instant: grain.startOfBucket(value.value),
      grain: grain,
    );
  }

  /// Densifies a list of [BucketKey] values from a temporal group-by
  /// to cover every grain-aligned position in [dateRange].
  ///
  /// Used by the executor's N-level cross-product densification to
  /// extend the temporal axis. Returns a new list containing every
  /// grain-aligned key in the half-open `[dateRange.$1, dateRange.$2)`
  /// range. Existing keys are preserved (via `==` on [TimeBucketKey]);
  /// missing keys are inserted as synthetic [TimeBucketKey] instances.
  /// Non-temporal keys in the input (e.g. [NullBucketKey]) are
  /// preserved at the end in their original order.
  static List<BucketKey> densifyTimeBucketKeys(
    List<BucketKey> observed,
    TimeGrain grain,
    (DateTime, DateTime) dateRange,
  ) {
    return densifyTimeBuckets<BucketKey>(
      input: observed,
      grain: grain,
      dateRange: dateRange,
      instantOf: (k) =>
          (k is TimeBucketKey && k.grain == grain) ? k.instant : null,
      synthesize: (instant) => TimeBucketKey(instant: instant, grain: grain),
    );
  }
}
