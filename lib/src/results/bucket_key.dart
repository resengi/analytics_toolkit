part of '../results.dart';

// ── BucketKey ───────────────────────────────────────────────────────────────

/// A typed bucket key.
///
/// Equality on [BucketKey] is value-based and lets paired-query
/// alignment happen without sniffing types — two buckets with equal
/// keys belong together.
///
/// Display labels are not the bucket key's concern; see
/// [SeriesBucket.displayLabel] / [XAxisPosition.label] for that.
sealed class BucketKey {
  const BucketKey();
}

class StringBucketKey extends BucketKey {
  const StringBucketKey(this.value);
  final String value;

  @override
  bool operator ==(Object other) =>
      other is StringBucketKey && value == other.value;

  @override
  int get hashCode => value.hashCode;
}

class EnumBucketKey extends BucketKey {
  const EnumBucketKey(this.value);
  final String value;

  @override
  bool operator ==(Object other) =>
      other is EnumBucketKey && value == other.value;

  @override
  int get hashCode => value.hashCode;
}

class BoolBucketKey extends BucketKey {
  const BoolBucketKey(this.value);
  final bool value;

  @override
  bool operator ==(Object other) =>
      other is BoolBucketKey && value == other.value;

  @override
  int get hashCode => value.hashCode;
}

/// Numeric bucket key for integer-valued group fields.
///
/// Used when `FieldGroupBy` targets an `integer` field. Equality is
/// value-based; ordering (when sorted by group-field) is numeric, not
/// lexical, which avoids the `[1, 10, 11, 2]` lexical-sort pitfall.
class IntBucketKey extends BucketKey {
  const IntBucketKey(this.value);
  final int value;

  @override
  bool operator ==(Object other) =>
      other is IntBucketKey && value == other.value;

  @override
  int get hashCode => value.hashCode;
}

/// Numeric bucket key for floating-point group fields.
///
/// Used when `FieldGroupBy` targets a `double` field. As with
/// [IntBucketKey], ordering when sorted by group-field is numeric.
class DoubleBucketKey extends BucketKey {
  const DoubleBucketKey(this.value);
  final double value;

  @override
  bool operator ==(Object other) =>
      other is DoubleBucketKey && value == other.value;

  @override
  int get hashCode => value.hashCode;
}

/// A temporal bucket key.
///
/// [instant] is the *start* of the bucket window per the [grain]'s
/// alignment rules — see `TimeGrain.startOfBucket` for the exact
/// semantics.
class TimeBucketKey extends BucketKey {
  const TimeBucketKey({required this.instant, required this.grain});
  final DateTime instant;
  final TimeGrain grain;

  @override
  bool operator ==(Object other) =>
      other is TimeBucketKey &&
      instant == other.instant &&
      grain == other.grain;

  @override
  int get hashCode => Object.hash(instant, grain);
}

/// Bucket key for "no key" — used when a record's group field is null.
/// Distinct from buckets that don't exist in the input.
class NullBucketKey extends BucketKey {
  const NullBucketKey();

  @override
  bool operator ==(Object other) => other is NullBucketKey;

  @override
  int get hashCode => runtimeType.hashCode;
}

// ── BucketKeyOrdering ──────────────────────────────────────────────────────

/// Single source of truth for comparing two [BucketKey] instances.
///
/// Used by the executor's group-field sort, the executor's temporal
/// series sort, and the grouping engine's two-level temporal x-axis
/// sort — every site that needs to order bucket keys goes through
/// this class so the comparison rules can't drift.
///
/// Comparison rules:
/// * Pairs of the same concrete subclass compare on their underlying
///   value: `IntBucketKey` and `DoubleBucketKey` numerically;
///   `TimeBucketKey` by `instant`; `StringBucketKey` / `EnumBucketKey`
///   on the underlying string; `BoolBucketKey` with `false < true`.
///   `Duration`-typed fields are bucketed as `IntBucketKey` of
///   microseconds rather than as a distinct `DurationBucketKey`, so
///   no separate `DurationBucketKey` rule is needed.
/// * Mismatched non-null pairs (e.g. `StringBucketKey` vs
///   `IntBucketKey`) compare as equal — there's no meaningful order
///   between unrelated key types.
/// * `NullBucketKey` is handled by [compareNullsLast]: nulls sort
///   last regardless of direction (matching SQL's `NULLS LAST`).
///   The lower-level [compare] doesn't have a position policy and
///   returns 0 for any pair where either side is `NullBucketKey`.
abstract class BucketKeyOrdering {
  /// Compares two [BucketKey]s ignoring null-positioning. Returns 0
  /// when either side is [NullBucketKey] or the types don't match.
  ///
  /// Callers wanting "nulls last" semantics should use
  /// [compareNullsLast] instead.
  static int compare(BucketKey a, BucketKey b) {
    if (a is NullBucketKey || b is NullBucketKey) return 0;
    if (a is IntBucketKey && b is IntBucketKey) {
      return a.value.compareTo(b.value);
    }
    if (a is DoubleBucketKey && b is DoubleBucketKey) {
      return a.value.compareTo(b.value);
    }
    if (a is TimeBucketKey && b is TimeBucketKey) {
      return a.instant.compareTo(b.instant);
    }
    if (a is StringBucketKey && b is StringBucketKey) {
      return a.value.compareTo(b.value);
    }
    if (a is EnumBucketKey && b is EnumBucketKey) {
      return a.value.compareTo(b.value);
    }
    if (a is BoolBucketKey && b is BoolBucketKey) {
      return (a.value ? 1 : 0).compareTo(b.value ? 1 : 0);
    }
    // Mismatched concrete subtypes — no defined order.
    return 0;
  }

  /// Compares with "nulls last" semantics: [NullBucketKey] always
  /// sorts after non-null keys, regardless of the requested direction.
  /// Two null keys compare as equal.
  static int compareNullsLast(BucketKey a, BucketKey b) {
    final aNull = a is NullBucketKey;
    final bNull = b is NullBucketKey;
    if (aNull && bNull) return 0;
    if (aNull) return 1;
    if (bNull) return -1;
    return compare(a, b);
  }
}

/// Converts a [BucketKey] back to the [TypedValue] it represents, for
/// inclusion in a group-key column when projecting a chart-shape view
/// to a [TableResult] — or, more generally, when round-tripping
/// between the executor's grouping-key representation and the
/// result's column-value representation.
///
/// [fieldType] disambiguates the ambiguous cases — specifically, the
/// `IntBucketKey` shape is used for both integer and duration fields
/// (duration keys hold microseconds), so the column's declared field
/// type is needed to round-trip them correctly to the right
/// `TypedValue` subtype.
TypedValue bucketKeyToTypedValue(BucketKey key, FieldType fieldType) {
  switch (key) {
    case NullBucketKey():
      return NullValue(fieldType);
    case StringBucketKey(value: final v):
      return StringValue(v);
    case EnumBucketKey(value: final v):
      return EnumValue(v);
    case BoolBucketKey(value: final v):
      return BoolValue(v);
    case IntBucketKey(value: final v):
      // IntBucketKey is shared between integer fields and duration
      // fields (the latter wraps microseconds). The column's
      // declared field type tells us which TypedValue subtype to
      // produce.
      if (fieldType == FieldType.duration) {
        return DurationValue(Duration(microseconds: v));
      }
      return IntValue(v);
    case DoubleBucketKey(value: final v):
      return DoubleValue(v);
    case TimeBucketKey(instant: final t):
      return DateTimeValue(t);
  }
}
