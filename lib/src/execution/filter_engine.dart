import '../query/query_components.dart';
import '../query/query_enums.dart';
import '../schema/typed_value.dart';
import 'source_record.dart';

/// Applies a list of `Filter`s to a stream of `SourceRecord`s.
///
/// Filters are AND-combined; a record passes only if every filter
/// accepts it. Records missing the filtered field (or holding a
/// `NullValue` for it) are rejected by every operator except `equals`
/// against another null.
///
/// All comparisons are typed via the `TypedValue` shape — there is no
/// runtime sniffing. The validator has already ensured the filter's
/// value type matches the field type.
abstract class FilterEngine {
  /// Returns true if [record] satisfies all of [filters].
  static bool matchesAll(SourceRecord record, List<Filter> filters) {
    for (final f in filters) {
      if (!_matchesOne(record, f)) return false;
    }
    return true;
  }

  static bool _matchesOne(SourceRecord record, Filter filter) {
    final fieldValue = record[filter.fieldRef.fieldId];

    // Missing field is treated as NullValue for uniformity.
    final lhs = fieldValue ?? NullValue(filter.value.fieldType);

    switch (filter.operator) {
      case FilterOperator.equals:
        return _equals(lhs, filter.value);
      case FilterOperator.notEquals:
        return !_equals(lhs, filter.value);
      case FilterOperator.lessThan:
      case FilterOperator.lessThanOrEqual:
      case FilterOperator.greaterThan:
      case FilterOperator.greaterThanOrEqual:
        // Any ordered comparison involving null on either side is
        // always false — null is unordered with respect to non-null.
        if (lhs is NullValue || filter.value is NullValue) return false;
        final cmp = TypedValueOrdering.compare(lhs, filter.value);
        // Type-mismatched values never match. The validator ensures
        // operands share a type for ordered operators, so a null here
        // signals an invariant violation rather than a normal path —
        // but failing closed is safer than failing equal.
        if (cmp == null) return false;
        return _applyOrderedOp(filter.operator, cmp);
      case FilterOperator.inList:
        return _inList(lhs, filter.value);
    }
  }

  /// Maps an ordered operator + a signed comparison result to a bool.
  /// Pure dispatch — assumes the operator is one of the four ordered
  /// operators (validated by the validator and gated by the caller's
  /// outer switch).
  static bool _applyOrderedOp(FilterOperator op, int cmp) {
    switch (op) {
      case FilterOperator.lessThan:
        return cmp < 0;
      case FilterOperator.lessThanOrEqual:
        return cmp <= 0;
      case FilterOperator.greaterThan:
        return cmp > 0;
      case FilterOperator.greaterThanOrEqual:
        return cmp >= 0;
      case FilterOperator.equals:
      case FilterOperator.notEquals:
      case FilterOperator.inList:
        throw StateError(
          'FilterEngine._applyOrderedOp: called with non-ordered '
          'operator $op; should be unreachable.',
        );
    }
  }

  // ── equals ────────────────────────────────────────────────────────────

  static bool _equals(TypedValue a, TypedValue b) {
    if (a is NullValue && b is NullValue) return true;
    if (a is NullValue || b is NullValue) return false;
    return a.raw == b.raw;
  }

  // ── inList ────────────────────────────────────────────────────────────

  static bool _inList(TypedValue lhs, TypedValue listValue) {
    if (lhs is NullValue) return false;
    // The validator pairs `inList` with a list-typed value whose
    // element type matches the field type, and `AnalyticsExecutor`
    // rejects records whose value type doesn't match the field type.
    // So whenever [listValue] is one of the list variants, [lhs] is
    // already the matching scalar subtype.
    switch (listValue) {
      case StringListValue(values: final values):
        return lhs is StringValue && values.contains(lhs.value);
      case EnumListValue(values: final values):
        return lhs is EnumValue && values.contains(lhs.value);
      case IntListValue(values: final values):
        return lhs is IntValue && values.contains(lhs.value);
      case StringValue():
      case EnumValue():
      case IntValue():
      case DoubleValue():
      case BoolValue():
      case DateTimeValue():
      case DurationValue():
      case NullValue():
        // Validator guarantees `inList` is paired with a list-valued
        // TypedValue. Reaching this branch means validation was bypassed
        // or has a gap.
        throw StateError(
          'FilterEngine._inList: unreachable for non-list value '
          '${listValue.runtimeType}; validator should have rejected.',
        );
    }
  }
}
