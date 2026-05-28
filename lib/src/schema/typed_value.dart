import '../equality.dart';
import 'schema.dart';

/// A typed value carrier used wherever the executor needs to know both
/// the value and its declared type.
///
/// Used in `Filter.value`, `SourceRecord.fields`, aggregation results
/// (`ScalarResult.value`, `SeriesBucket.value`, `NamedSeries.values`),
/// and `TableColumn.values`.
///
/// `TypedValue` is a sealed shape — every concrete subclass declares
/// the `FieldType` it represents via the [fieldType] getter, so the
/// executor can validate filter compatibility without runtime sniffing.
///
/// The list-valued cases (`StringListValue`, `IntListValue`,
/// `EnumListValue`) are used by the `inList` filter operator. All other
/// operators take scalar values.
///
/// All subtypes implement value equality.
sealed class TypedValue {
  const TypedValue();

  /// The field type this value represents.
  FieldType get fieldType;

  /// The raw underlying value, useful for executor logic that needs to
  /// compare or aggregate without dispatching on the case shape.
  Object? get raw;
}

class StringValue extends TypedValue {
  const StringValue(this.value);
  final String value;
  @override
  FieldType get fieldType => FieldType.string;
  @override
  Object? get raw => value;
  @override
  bool operator ==(Object other) =>
      other is StringValue && other.value == value;
  @override
  int get hashCode => value.hashCode;
}

class EnumValue extends TypedValue {
  const EnumValue(this.value);
  final String value;
  @override
  FieldType get fieldType => FieldType.enumeration;
  @override
  Object? get raw => value;
  @override
  bool operator ==(Object other) => other is EnumValue && other.value == value;
  @override
  int get hashCode => value.hashCode;
}

class IntValue extends TypedValue {
  const IntValue(this.value);
  final int value;
  @override
  FieldType get fieldType => FieldType.integer;
  @override
  Object? get raw => value;
  @override
  bool operator ==(Object other) => other is IntValue && other.value == value;
  @override
  int get hashCode => value.hashCode;
}

class DoubleValue extends TypedValue {
  const DoubleValue(this.value);
  final double value;
  @override
  FieldType get fieldType => FieldType.double;
  @override
  Object? get raw => value;
  @override
  bool operator ==(Object other) =>
      other is DoubleValue && other.value == value;
  @override
  int get hashCode => value.hashCode;
}

class BoolValue extends TypedValue {
  const BoolValue(this.value);
  final bool value;
  @override
  FieldType get fieldType => FieldType.boolean;
  @override
  Object? get raw => value;
  @override
  bool operator ==(Object other) => other is BoolValue && other.value == value;
  @override
  int get hashCode => value.hashCode;
}

class DateTimeValue extends TypedValue {
  const DateTimeValue(this.value);
  final DateTime value;
  @override
  FieldType get fieldType => FieldType.dateTime;
  @override
  Object? get raw => value;
  @override
  bool operator ==(Object other) =>
      other is DateTimeValue && other.value == value;
  @override
  int get hashCode => value.hashCode;
}

class DurationValue extends TypedValue {
  const DurationValue(this.value);
  final Duration value;
  @override
  FieldType get fieldType => FieldType.duration;
  @override
  Object? get raw => value;
  @override
  bool operator ==(Object other) =>
      other is DurationValue && other.value == value;
  @override
  int get hashCode => value.hashCode;
}

/// Used by `inList` over string fields.
class StringListValue extends TypedValue {
  StringListValue(List<String> values) : values = List.unmodifiable(values);
  final List<String> values;
  @override
  FieldType get fieldType => FieldType.string;
  @override
  Object? get raw => values;
  @override
  bool operator ==(Object other) =>
      other is StringListValue && listEqualsByValue(other.values, values);
  @override
  int get hashCode => listHashByValue(values);
}

/// Used by `inList` over enum fields.
class EnumListValue extends TypedValue {
  EnumListValue(List<String> values) : values = List.unmodifiable(values);
  final List<String> values;
  @override
  FieldType get fieldType => FieldType.enumeration;
  @override
  Object? get raw => values;
  @override
  bool operator ==(Object other) =>
      other is EnumListValue && listEqualsByValue(other.values, values);
  @override
  int get hashCode => listHashByValue(values);
}

/// Used by `inList` over integer fields.
class IntListValue extends TypedValue {
  IntListValue(List<int> values) : values = List.unmodifiable(values);
  final List<int> values;
  @override
  FieldType get fieldType => FieldType.integer;
  @override
  Object? get raw => values;
  @override
  bool operator ==(Object other) =>
      other is IntListValue && listEqualsByValue(other.values, values);
  @override
  int get hashCode => listHashByValue(values);
}

/// A null value, distinguished from "field absent" — used when a record
/// has the field but its value is unset.
///
/// Filter semantics: `nullValue == nullValue` is true; `nullValue` is
/// not less-than or greater-than anything.
class NullValue extends TypedValue {
  const NullValue(this.declaredType);
  final FieldType declaredType;
  @override
  FieldType get fieldType => declaredType;
  @override
  Object? get raw => null;
  @override
  bool operator ==(Object other) =>
      other is NullValue && other.declaredType == declaredType;
  @override
  int get hashCode => declaredType.hashCode;
}

// ── TypedValueOrdering ─────────────────────────────────────────────────────

/// Total-ish ordering for [TypedValue] instances.
///
/// Single source of truth for "how do I compare two typed values."
/// Used by the filter engine for ordered filter operators and by the
/// executor for series sorting.
///
/// Returns:
/// * Negative if `a` orders before `b`.
/// * Zero if they're equal.
/// * Positive if `a` orders after `b`.
/// * `null` if the pair is unordered — either side is a [NullValue]
///   or the underlying raw types are unrelated.
///
/// Null-handling policy is per-caller. The filter engine null-checks
/// before delegating and treats a `null` return as "no match." The
/// executor's `MeasureValueSort` null-checks before delegating and
/// relies on the aggregator producing same-typed values per column.
abstract class TypedValueOrdering {
  /// Compares two [TypedValue]s. See class doc for return semantics.
  static int? compare(TypedValue a, TypedValue b) {
    if (a is NullValue || b is NullValue) return null;
    final ar = a.raw;
    final br = b.raw;
    if (ar is num && br is num) return ar.compareTo(br);
    if (ar is DateTime && br is DateTime) return ar.compareTo(br);
    if (ar is Duration && br is Duration) return ar.compareTo(br);
    if (ar is String && br is String) return ar.compareTo(br);
    if (ar is bool && br is bool) {
      return (ar ? 1 : 0).compareTo(br ? 1 : 0);
    }
    return null;
  }
}
