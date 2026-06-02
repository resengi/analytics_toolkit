import '../schema/schema.dart';
import '../schema/typed_value.dart';
import '../time_series/time_grain.dart';
import 'query_enums.dart';

// ── Filter ──────────────────────────────────────────────────────────────────

/// A filter condition on a single field.
///
/// Filters are AND-combined; OR is not supported.
///
/// ## Validation scope
///
/// The validator checks:
/// * the field exists on the source,
/// * the field is `filterable`,
/// * the operator is compatible with the field's `FieldType`,
/// * `inList` is paired with a list-valued `TypedValue` whose element
///   type matches the field type,
/// * non-`inList` operators are paired with a scalar `TypedValue`
///   whose type matches the field type, or with `NullValue` when the
///   operator is `equals` / `notEquals` (a "is this field null" test).
///   Ordered operators (`lessThan` / `lessThanOrEqual` / `greaterThan`
///   / `greaterThanOrEqual`) against `NullValue` are rejected.
///
/// A filter that passes validation is guaranteed to be executable
/// without runtime type-mismatch surprises.
class Filter {
  const Filter({
    required this.fieldRef,
    required this.operator,
    required this.value,
  });

  final FieldRef fieldRef;
  final FilterOperator operator;
  final TypedValue value;

  @override
  bool operator ==(Object other) =>
      other is Filter &&
      other.fieldRef == fieldRef &&
      other.operator == operator &&
      other.value == value;

  @override
  int get hashCode => Object.hash(fieldRef, operator, value);
}

// ── HavingClause ────────────────────────────────────────────────────────────

/// A post-aggregation filter on bucket measure values.
///
/// HAVING sits between aggregation/densification and sort in the
/// executor pipeline. Buckets whose measure value fails the
/// comparison against [threshold] are dropped before sort and limit
/// run, so `limit` correctly operates on the threshold-qualified set
/// (e.g., "top 10 customers with > $500 spend" returns 10 qualifying
/// customers, not 10 from a pre-HAVING list of which some may fall
/// below the threshold).
///
/// Buckets with a `null` measure value (the result of non-additive
/// aggregations over empty / all-null groups, including synthetic
/// densified buckets) are dropped: a null value has no defined
/// ordering against a non-null threshold.
///
/// ## Validation scope
///
/// The validator checks:
/// * the enclosing query has at least one group-by clause (a scalar
///   query has no buckets for HAVING to filter — fires
///   `havingRequiresGrouping`),
/// * [threshold]'s `fieldType` matches the measure's inferred output
///   type (resolved via [Measure.outputFieldType], which is the
///   single source of truth for the `(measure × source) → output-
///   type` mapping),
/// * in multi-measure queries, [measureLabel] resolves to exactly
///   one of the query's measures' labels.
///
/// ## `measureLabel`
///
/// In single-measure queries [measureLabel] is unambiguous and
/// callers can leave it `null`. In multi-measure queries it must
/// name one of the query's measures; the threshold is compared
/// against that measure's column.
class HavingClause {
  const HavingClause({
    required this.operator,
    required this.threshold,
    this.measureLabel,
  });

  /// The comparison operator. See [HavingOperator] for the closed
  /// set of supported operators; `inList` is deliberately not part of
  /// the HAVING operator family (bucket values are scalars, not
  /// list-membership tests).
  final HavingOperator operator;

  /// The threshold to compare each bucket's measure value against.
  /// Must be the same `TypedValue` subtype the measure produces
  /// — the validator enforces this.
  final TypedValue threshold;

  /// Optional measure-column reference for multi-measure queries.
  /// `null` is the unambiguous shape for single-measure queries.
  final String? measureLabel;

  @override
  bool operator ==(Object other) =>
      other is HavingClause &&
      other.operator == operator &&
      other.threshold == threshold &&
      other.measureLabel == measureLabel;

  @override
  int get hashCode => Object.hash(operator, threshold, measureLabel);
}

// ── GroupBy ─────────────────────────────────────────────────────────────────

/// How to group records before aggregation.
///
/// Sealed shape with two cases:
/// - [FieldGroupBy] — categorical grouping by any groupable field
/// - [TimeGroupBy]  — temporal grouping by a `dateTime` field at a
///                    specified grain
///
/// Up to three group-by clauses per query are allowed, stored as the
/// `AnalyticsQuerySpec.groupBys` list. The list's cardinality
/// determines the result shape: 0 → `ScalarResult`, 1 → `SeriesResult`,
/// 2 → `MultiSeriesResult`, 3 → `TableResult`.
sealed class GroupBy {
  const GroupBy({this.label});

  /// Optional consumer-supplied column-label override for this
  /// group-by. When null, the group column's `TableColumn.label`
  /// falls back to the underlying field id. Set it to disambiguate
  /// when a group column and a measure column would otherwise share
  /// the same name (e.g. a measure with explicit `label: 'status'`
  /// against a `FieldGroupBy` on the `'status'` field).
  ///
  /// Excluded from `==` and `hashCode` on the subclasses so two
  /// queries that differ only by display label still compare as
  /// structurally equivalent — the same treatment that keeps
  /// paired-query alignability correct under aliasing.
  final String? label;

  /// Effective column label for this group-by: [label] when set,
  /// otherwise the underlying field id. This is the value the
  /// executor uses for `TableColumn.label` and that the validator
  /// uses for the column-label uniqueness check.
  String get effectiveLabel =>
      label ??
      switch (this) {
        FieldGroupBy(fieldRef: final r) => r.fieldId,
        TimeGroupBy(dateFieldRef: final r) => r.fieldId,
      };
}

class FieldGroupBy extends GroupBy {
  const FieldGroupBy({required this.fieldRef, super.label});
  final FieldRef fieldRef;

  @override
  bool operator ==(Object other) =>
      other is FieldGroupBy && other.fieldRef == fieldRef;

  @override
  int get hashCode => fieldRef.hashCode;
}

class TimeGroupBy extends GroupBy {
  const TimeGroupBy({
    required this.dateFieldRef,
    required this.grain,
    super.label,
  });
  final FieldRef dateFieldRef;
  final TimeGrain grain;

  @override
  bool operator ==(Object other) =>
      other is TimeGroupBy &&
      other.dateFieldRef == dateFieldRef &&
      other.grain == grain;

  @override
  int get hashCode => Object.hash(dateFieldRef, grain);
}

// ── Sort ────────────────────────────────────────────────────────────────────

/// What to sort the result buckets by.
sealed class SortTarget {
  const SortTarget();
}

class GroupFieldSort extends SortTarget {
  const GroupFieldSort({required this.fieldRef});
  final FieldRef fieldRef;

  @override
  bool operator ==(Object other) =>
      other is GroupFieldSort && other.fieldRef == fieldRef;

  @override
  int get hashCode => fieldRef.hashCode;
}

/// Sort target meaning "sort buckets by the value of an aggregated
/// measure."
///
/// In single-measure queries the [measureLabel] is unused — the sort
/// targets the only measure. In multi-measure queries, the label
/// disambiguates which measure to sort by:
///
/// - non-null label → must match one of the query's measures'
///   effective labels (explicit `Measure.label`, or auto-generated
///   `'measure_<index>'`)
/// - null label → ambiguous in multi-measure queries; the validator
///   rejects with `preconditionViolation`
class MeasureValueSort extends SortTarget {
  const MeasureValueSort({this.measureLabel});

  /// Identifier of the measure to sort by. See class doc for the
  /// resolution rules. The validator rejects unknown labels with
  /// `unknownMeasureLabel`.
  final String? measureLabel;

  @override
  bool operator ==(Object other) =>
      other is MeasureValueSort && other.measureLabel == measureLabel;

  @override
  int get hashCode => Object.hash(runtimeType, measureLabel);
}

/// One sort to apply to the result.
///
/// [target] selects what is being ordered (a group-key column or a
/// measure-value column); [direction] picks the direction.
///
/// ## Null handling
///
/// By default, null values follow [direction]: ascending sorts place
/// nulls last; descending sorts place nulls first. This matches the
/// SQL convention where null is treated as larger than any non-null
/// value, with position determined by the sort direction.
///
/// Set [forceNullsLast] to `true` to pin nulls at the end of the
/// result regardless of [direction]. Useful for ranked dashboards
/// where missing data should never appear at the top of the list.
class Sort {
  const Sort({
    required this.target,
    required this.direction,
    this.forceNullsLast = false,
  });
  final SortTarget target;
  final SortDirection direction;

  /// When `true`, null values are placed at the end of the sorted
  /// result regardless of [direction]. When `false` (the default),
  /// nulls follow [direction]: ascending places nulls last,
  /// descending places nulls first.
  final bool forceNullsLast;

  @override
  bool operator ==(Object other) =>
      other is Sort &&
      other.target == target &&
      other.direction == direction &&
      other.forceNullsLast == forceNullsLast;

  @override
  int get hashCode => Object.hash(target, direction, forceNullsLast);
}

// ── DerivedOperation ────────────────────────────────────────────────────────

/// A post-aggregation transformation applied to a `SeriesResult`.
///
/// Sealed typed family — each case is its own shape and may carry
/// parameters.
///
/// Derived operations transform the values of a `SeriesResult` and
/// produce another `SeriesResult` of the same shape. They never change
/// the result kind, bucket count, or bucket keys. They are applied
/// **after** grouping, aggregation, and sorting, and **before**
/// wrapping in the result type.
///
/// Derived operations are only meaningful over numeric-output
/// measures. Applying a derived operation to a measure whose output
/// type is non-numeric (e.g. `min`/`max` over a `dateTime` field
/// returns `DateTimeValue`) is rejected by the validator with
/// `derivedOpRequiresNumericMeasure`.
///
/// ## Output value types
///
/// * [CumulativeSumOp] and [DeltaOp] preserve the input value type:
///   `IntValue` in → `IntValue` out, `DoubleValue` in → `DoubleValue`
///   out, `DurationValue` in → `DurationValue` out.
/// * [MovingAverageOp] preserves `DurationValue` and otherwise
///   produces `DoubleValue` — `IntValue` in → `DoubleValue` out (the
///   average of integers is generally fractional); `DoubleValue` in →
///   `DoubleValue` out.
///
/// ## Null bucket handling
///
/// Null bucket values (produced by `average`/`min`/`max` over empty
/// groups, including synthetic empty buckets from time-bucket
/// densification) contribute `0` to each derived computation. The
/// output bucket is non-null whenever any non-null bucket exists in
/// the input — the op never propagates null through to its output.
///
/// **When this is correct:** the null means "no events occurred."
/// Cumulative counts over sparse data, deltas of event counts across
/// days, moving averages over densified empty buckets — in these
/// cases the underlying value really is zero, and treating it as
/// zero produces the intended result.
///
/// **When this is wrong:** the null means "value unknown." A metric
/// whose computation failed, a sensor reading that was unavailable,
/// or an aggregation over a field that wasn't populated upstream. In
/// these cases the derived op will report a flat plateau (cumulative
/// sum), a zero (delta), or a depressed average (moving average)
/// where the truthful answer is "we don't know." To preserve "value
/// unknown" semantics, post-process the result to re-introduce nulls
/// at the positions where the input was null, or filter the input
/// series to remove unknown-valued buckets before applying the
/// derived op.
///
/// As a corner case: if every bucket in the series is null, the
/// engine has no input type to box the result back to, so the
/// operation is a no-op and the all-null series is returned
/// unchanged. This rule is uniform across all three subtypes.
sealed class DerivedOperation {
  const DerivedOperation();
}

class NoDerivedOp extends DerivedOperation {
  const NoDerivedOp();
  @override
  bool operator ==(Object other) => other is NoDerivedOp;
  @override
  int get hashCode => runtimeType.hashCode;
}

/// Running total. At bucket index `i`, the output is the sum of all
/// input values at indices `[0, i]`. See [DerivedOperation] for null
/// handling and output-type rules.
class CumulativeSumOp extends DerivedOperation {
  const CumulativeSumOp();
  @override
  bool operator ==(Object other) => other is CumulativeSumOp;
  @override
  int get hashCode => runtimeType.hashCode;
}

/// Period-over-period difference. At bucket index `i > 0`, the output
/// is `values[i] - values[i - 1]`; index `0` is `0` (no prior period
/// to compare against). See [DerivedOperation] for null handling and
/// output-type rules.
class DeltaOp extends DerivedOperation {
  const DeltaOp();
  @override
  bool operator ==(Object other) => other is DeltaOp;
  @override
  int get hashCode => runtimeType.hashCode;
}

/// Rolling average over a sliding [window] of buckets.
///
/// At bucket index `i`, the output is the average of values at
/// indices `[max(0, i - window + 1), i]`. The first `window - 1`
/// buckets use a smaller-than-`window` partial window — they are
/// emitted, not padded with `null`. So a series of length N with
/// `window = 3` produces N outputs: indices 0 and 1 average over
/// their respective partial windows, and indices 2..N-1 over a full
/// window of 3.
///
/// See [DerivedOperation] for null handling and output-type rules.
class MovingAverageOp extends DerivedOperation {
  const MovingAverageOp({required this.window});

  /// Must be > 0. Rejected by the validator as
  /// `invalidDerivedOperationParameter` otherwise.
  final int window;

  @override
  bool operator ==(Object other) =>
      other is MovingAverageOp && other.window == window;

  @override
  int get hashCode => Object.hash(runtimeType, window);
}

// ── ScalarOp ────────────────────────────────────────────────────────────────

/// A per-value transformation of a single bucket value.
///
/// Sealed typed family. A scalar op maps one numeric value to one
/// numeric value of the same `FieldType`, independently of any other
/// bucket — unlike [DerivedOperation], which needs the whole series.
/// Scalar ops are evaluated per bucket while the value is computed, so
/// they apply both inside a query (via [TransformedMeasure]) and on a
/// held result (via `SeriesAlgebra.transform`).
///
/// ## Null handling
///
/// [NegateOp] and [AbsOp] propagate null: a null value maps to null.
/// [FillNullOp] is the opt-out — it replaces a null value with a chosen
/// number and passes a non-null value through unchanged. This is the
/// only scalar op that turns a null into a number, and it does so only
/// when the caller asks for it.
///
/// ## Output type
///
/// All three ops preserve the value's `FieldType`. Negate and absolute
/// value require a numeric value to operate on; fill-null boxes its
/// fill into the series' measure type. Applying a scalar op to a
/// non-numeric series is rejected with
/// `AnalyticsErrorKind.incompatibleSeriesCombination`.
sealed class ScalarOp {
  const ScalarOp();
}

/// Negates the value: `v` maps to `-v`. Propagates null.
class NegateOp extends ScalarOp {
  const NegateOp();
  @override
  bool operator ==(Object other) => other is NegateOp;
  @override
  int get hashCode => runtimeType.hashCode;
}

/// Maps the value to its absolute value. Propagates null.
class AbsOp extends ScalarOp {
  const AbsOp();
  @override
  bool operator ==(Object other) => other is AbsOp;
  @override
  int get hashCode => runtimeType.hashCode;
}

/// Replaces a null value with [fill]; passes a non-null value through
/// unchanged.
///
/// [fill] is boxed into the series' measure type. For a `duration`
/// series the fill is interpreted in microseconds, so `FillNullOp(0)`
/// yields `Duration.zero` and a non-zero fill is a microsecond count.
class FillNullOp extends ScalarOp {
  const FillNullOp(this.fill);

  /// The number substituted for a null value, boxed into the series'
  /// measure type.
  final num fill;

  @override
  bool operator ==(Object other) => other is FillNullOp && other.fill == fill;

  @override
  int get hashCode => Object.hash(runtimeType, fill);
}

// ── SeriesCombination ─────────────────────────────────────────────────────────

/// A binary operation that combines two aligned bucket values into one.
///
/// Sealed typed family. A combination folds two numeric values into a
/// single result. It is the per-bucket rule behind both the in-query
/// [CalculatedMeasure] (whose operands share the query's buckets, so
/// they are inherently aligned) and the result-level
/// `SeriesAlgebra.combine` (which aligns two held series by bucket key
/// first).
///
/// ## Null handling
///
/// All combinations propagate null: if either operand value is null,
/// the result is null. [RatioCombination] additionally yields null when
/// the denominator is null or zero.
///
/// ## Output type
///
/// [SumCombination] and [DifferenceCombination] preserve the unit
/// family: duration with duration yields duration, integer with integer
/// yields integer, and any pair involving a double yields double;
/// mixing a duration with a non-duration is rejected.
/// [ProductCombination] and [RatioCombination] always yield a unitless
/// double. See `combineOutputType` for the full table.
sealed class SeriesCombination {
  const SeriesCombination();
}

/// Adds the two values: `a + b`.
class SumCombination extends SeriesCombination {
  const SumCombination();
  @override
  bool operator ==(Object other) => other is SumCombination;
  @override
  int get hashCode => runtimeType.hashCode;
}

/// Subtracts the second value from the first: `a - b`.
class DifferenceCombination extends SeriesCombination {
  const DifferenceCombination();
  @override
  bool operator ==(Object other) => other is DifferenceCombination;
  @override
  int get hashCode => runtimeType.hashCode;
}

/// Multiplies the two values: `a * b`. Always yields a unitless double.
class ProductCombination extends SeriesCombination {
  const ProductCombination();
  @override
  bool operator ==(Object other) => other is ProductCombination;
  @override
  int get hashCode => runtimeType.hashCode;
}

/// Divides the first value by the second: `a / b`. Always yields a
/// unitless double; yields null when the denominator is null or zero.
class RatioCombination extends SeriesCombination {
  const RatioCombination();
  @override
  bool operator ==(Object other) => other is RatioCombination;
  @override
  int get hashCode => runtimeType.hashCode;
}

// ── UnmatchedBucketPolicy ─────────────────────────────────────────────────────

/// How `SeriesAlgebra.combine` treats a bucket key present in only one
/// of the two series being combined.
///
/// This governs an **absent key** only — a key one series has and the
/// other lacks. It is unrelated to a **null value** (a present key whose
/// value is null), which always propagates regardless of policy. The
/// two are independent: control absent keys with this policy, and null
/// values with [FillNullOp].
///
/// The policy applies only to the result-level combine path. The
/// in-query [CalculatedMeasure] computes both operands over the same
/// buckets, so it never has an absent key to resolve.
enum UnmatchedBucketPolicy {
  /// Keep only keys present in both series (the intersection). A key
  /// absent on either side is omitted from the output.
  drop,

  /// Keep the union of keys. For a key present on only one side, the
  /// absent side is treated as the combination's identity (zero for sum
  /// and difference, one for product). A ratio has no identity, so a
  /// key absent on either side is omitted even under this policy.
  fillIdentity,
}
