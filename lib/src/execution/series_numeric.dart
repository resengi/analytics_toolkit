/// Value-level arithmetic and type rules shared by every series
/// operation.
///
/// Both invocation paths route through this module: the executor uses
/// it to fold a calculated measure's operands and to apply a per-value
/// op while a bucket value is computed, and `SeriesAlgebra` uses it to
/// transform or combine a held `SeriesResult`. Keeping the rules here
/// means the two paths cannot diverge.
///
/// All arithmetic happens in `double`. A `Duration` projects to its
/// microsecond count and boxes back from microseconds, so
/// duration-with-duration sums and differences stay exact and typed.
/// `double` rounding is confined to the boxing step, where an `integer`
/// or `duration` result is rounded to the nearest whole unit.
///
/// Because the intermediate is always `double`, `integer` or `duration`
/// magnitudes beyond 2^53 (in whole units / microseconds) can lose
/// precision before boxing. This is an accepted bound for an in-memory
/// analytics engine and is well outside realistic dashboard ranges; it
/// is documented here rather than guarded against.
library;

import '../errors.dart';
import '../query/query_components.dart';
import '../schema/schema.dart';
import '../schema/typed_value.dart';

/// Whether [t] is one of the numeric field types the series algebra
/// operates on: `integer`, `double`, or `duration`.
bool isNumericFieldType(FieldType t) =>
    t == FieldType.integer || t == FieldType.double || t == FieldType.duration;

/// Projects a numeric [TypedValue] to a `double` for arithmetic.
///
/// Returns null only when [v] is null (an undefined bucket). A
/// `Duration` projects to its microsecond count. Throws [StateError]
/// for a non-numeric concrete value; callers guard with
/// [isNumericFieldType] before projecting.
double? projectToDouble(TypedValue? v) {
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
        'projectToDouble: non-numeric TypedValue ${v.runtimeType}; '
        'guard with isNumericFieldType before projecting.',
      );
  }
}

/// Boxes a `double` into the [TypedValue] for [t]:
///
/// * `integer`  -> `IntValue(n.round())`
/// * `double`   -> `DoubleValue(n)`
/// * `duration` -> `DurationValue(Duration(microseconds: n.round()))`
///
/// Throws [StateError] for a non-numeric [t]; callers guard with
/// [isNumericFieldType] before boxing.
TypedValue boxFromDouble(double n, FieldType t) {
  switch (t) {
    case FieldType.integer:
      return IntValue(n.round());
    case FieldType.double:
      return DoubleValue(n);
    case FieldType.duration:
      return DurationValue(Duration(microseconds: n.round()));
    case FieldType.string:
    case FieldType.enumeration:
    case FieldType.boolean:
    case FieldType.dateTime:
      throw StateError(
        'boxFromDouble: non-numeric FieldType ${t.name}; guard with '
        'isNumericFieldType before boxing.',
      );
  }
}

/// The output [FieldType] of combining operands of type [a] and [b]
/// under [op], or null when the combination is invalid.
///
/// Returns null when either operand type is null or non-numeric, or
/// when a sum or difference mixes a duration with a non-duration.
///
/// * Sum, Difference: `duration` with `duration` -> `duration`;
///   `integer` with `integer` -> `integer`; any pair in
///   `{integer, double}` with at least one `double` -> `double`; a
///   `duration` with a non-`duration` -> null.
/// * Product, Ratio: any numeric pair (durations included) -> `double`.
///   These are unitless and apply no unit-family guard; a duration
///   operand contributes its microsecond magnitude.
FieldType? combineOutputType(FieldType? a, FieldType? b, SeriesCombination op) {
  if (a == null || b == null) return null;
  if (!isNumericFieldType(a) || !isNumericFieldType(b)) return null;
  switch (op) {
    case SumCombination():
    case DifferenceCombination():
      final aDuration = a == FieldType.duration;
      final bDuration = b == FieldType.duration;
      if (aDuration && bDuration) return FieldType.duration;
      // One side is a duration and the other is not: incompatible.
      if (aDuration || bDuration) return null;
      // Neither is a duration, so both are integer or double.
      if (a == FieldType.integer && b == FieldType.integer) {
        return FieldType.integer;
      }
      return FieldType.double;
    case ProductCombination():
    case RatioCombination():
      return FieldType.double;
  }
}

/// The parameter error for [op], or null when its own parameters are
/// well-formed.
///
/// "Own parameters" are intrinsic to the operation, independent of the
/// series it is applied to — currently only [MovingAverageOp.window],
/// which must be > 0. The numeric-measure requirement is series-
/// dependent and is checked separately by each caller.
///
/// Single source of truth for derived-op parameter validity, shared by
/// `QueryValidator` (in-query) and `SeriesAlgebra.apply` (result-level)
/// so the two paths never disagree — the same split `combineOutputType`
/// uses for combinations.
AnalyticsError? derivedOperationParameterError(DerivedOperation op) {
  switch (op) {
    case MovingAverageOp(window: final window) when window <= 0:
      return AnalyticsError(
        kind: AnalyticsErrorKind.invalidDerivedOperationParameter,
        humanMessage: 'MovingAverageOp.window must be > 0; got $window.',
      );
    case NoDerivedOp():
    case CumulativeSumOp():
    case DeltaOp():
    case MovingAverageOp():
      return null;
  }
}

/// Folds two typed values under [op], boxing the result into [outType].
///
/// Null-propagating: a null operand yields null. [RatioCombination]
/// additionally yields null when the denominator value is null or
/// projects to zero. A null result means "undefined for this bucket";
/// it is never converted to a number here.
///
/// Used by both the executor (per bucket of a calculated measure) and
/// `SeriesAlgebra.combine` (per aligned key).
TypedValue? combinePerValue(
  TypedValue? a,
  TypedValue? b,
  SeriesCombination op,
  FieldType outType,
) {
  if (a == null || b == null) return null;
  final ad = projectToDouble(a)!;
  final bd = projectToDouble(b)!;
  switch (op) {
    case SumCombination():
      return boxFromDouble(ad + bd, outType);
    case DifferenceCombination():
      return boxFromDouble(ad - bd, outType);
    case ProductCombination():
      return boxFromDouble(ad * bd, outType);
    case RatioCombination():
      if (bd == 0) return null;
      return boxFromDouble(ad / bd, outType);
  }
}

/// Applies a per-value [op] to a single value, given the series'
/// [measureType] (used to box a fill value or a negated/absolute
/// result).
///
/// [NegateOp] and [AbsOp] propagate null. [FillNullOp] substitutes its
/// fill (boxed into [measureType]) for a null value and passes a
/// non-null value through unchanged.
TypedValue? applyScalarValue(
  ScalarOp op,
  TypedValue? v,
  FieldType measureType,
) {
  switch (op) {
    case NegateOp():
      if (v == null) return null;
      return boxFromDouble(-projectToDouble(v)!, measureType);
    case AbsOp():
      if (v == null) return null;
      return boxFromDouble(projectToDouble(v)!.abs(), measureType);
    case FillNullOp(fill: final fill):
      if (v == null) return boxFromDouble(fill.toDouble(), measureType);
      return v;
  }
}

/// The identity element of [op] as a `double` — `0` for sum and
/// difference, `1` for product — or null when [op] has no identity
/// ([RatioCombination]).
///
/// Used by `SeriesAlgebra.combine` under
/// [UnmatchedBucketPolicy.fillIdentity] to stand in for an absent side.
double? combinationIdentity(SeriesCombination op) {
  switch (op) {
    case SumCombination():
    case DifferenceCombination():
      return 0;
    case ProductCombination():
      return 1;
    case RatioCombination():
      return null;
  }
}
