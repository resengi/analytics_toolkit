import 'schema/schema.dart';

/// The complete closed list of analytics error kinds.
///
/// Adding a new kind is a breaking change for any consumer that
/// pattern-matches the full set.
enum AnalyticsErrorKind {
  /// The query's `source` id does not match any source in the catalog
  /// passed to the validator.
  unknownSource,

  /// A query referenced a field id that does not exist on the
  /// resolved source. Surfaced for filter, group-by, sort,
  /// measure-field, and streak-field references.
  unknownField,

  /// A clause that targets a measure by label (e.g. `HavingClause` or
  /// `MeasureValueSort`) referenced a label that does not match any
  /// measure on the query. In single-measure queries, leaving the
  /// label `null` is unambiguous; in multi-measure queries, the
  /// label must resolve to exactly one of the query's measures.
  unknownMeasureLabel,

  /// A group-by clause referenced a field whose `groupable` flag is
  /// `false`.
  fieldNotGroupable,

  /// A filter referenced a field whose `filterable` flag is `false`.
  fieldNotFilterable,

  /// A `FieldMeasure` referenced a field whose `aggregatable` flag is
  /// `false`. `CountMeasure` is unaffected by this flag.
  fieldNotAggregatable,

  /// The selected `FieldAggregation` is not valid for the field's
  /// `FieldType` (e.g. `SumAgg` on a string field).
  incompatibleAggregation,

  /// The selected `FilterOperator` is not valid for the field's
  /// `FieldType` or for the supplied filter value (e.g. `lessThan` on
  /// a boolean field, or `inList` paired with a scalar value).
  incompatibleOperator,

  /// A `TimeGroupBy`, or a `StreakMeasure.scheduledDateField`,
  /// pointed at a field that is not `FieldType.dateTime`.
  timeGrainOnNonDateField,

  /// A query combined `StreakMeasure` with one or more entries in
  /// `groupBys`. Streaks produce per-entity rows and do not accept
  /// additional grouping.
  streakWithExplicitGrouping,

  /// A query's `measures` list is empty. At least one measure is
  /// required — without one, the query has nothing to aggregate.
  measuresEmpty,

  /// A query's `measures` list exceeds the cap of five entries. The
  /// cap exists to keep result table widths and aggregator per-bucket
  /// cost bounded; consumers needing wider results should split into
  /// multiple queries or pre-aggregate upstream.
  tooManyMeasures,

  /// Two or more measures in a query share the same effective label
  /// (either explicit [Measure.label]s collide, or one measure's
  /// auto-generated `'measure_<index>'` was unluckily reused by an
  /// explicit label on another measure). Effective labels must be
  /// unique because [HavingClause.measureLabel] and
  /// [MeasureValueSort.measureLabel] resolve by label.
  duplicateMeasureLabel,

  /// Two columns in the projected result would share the same label.
  /// The union of effective group-by labels (`GroupBy.label` when set,
  /// otherwise the underlying field id) and effective measure labels
  /// (explicit `Measure.label`, otherwise `'measure_<index>'`) must be
  /// unique within a query — `TableColumn.label` is the addressable
  /// key consumers use to look up columns, and a collision would make
  /// the lookup ambiguous. Resolve by setting an explicit `label` on
  /// the colliding group-by or measure.
  duplicateColumnLabel,

  /// `StreakMeasure` was combined with other measures in the same
  /// query. Streak has its own pipeline and produces a fixed table
  /// shape; it cannot be evaluated alongside aggregations.
  streakNotCombinable,

  /// A widget date-range mode was set for a measure whose
  /// `supportsDateRange` is `false` (i.e. `StreakMeasure`).
  dateRangeNotSupportedForMeasure,

  /// A widget's date-range mode is `NoDateRange` for a measure that
  /// supports — and is expected to be evaluated under — a date range.
  dateRangeRequiredForMeasure,

  /// A derived operation carried an out-of-range parameter
  /// (e.g. `MovingAverageOp` with `window` ≤ 0).
  invalidDerivedOperationParameter,

  /// A `FieldAggregation` carried an out-of-range parameter (e.g.
  /// `PercentileAgg` with `p` outside `[0, 1]`). Parallels
  /// [invalidDerivedOperationParameter] in shape.
  invalidAggregationParameter,

  /// The two halves of a `PairedQuerySpec` cannot be aligned: their
  /// sources differ without a shared `TimeGroupBy` alignment, or
  /// their grains or primary-date-field requirements disagree.
  incompatiblePairedQueryShapes,

  /// A `Sort` target is meaningless for the result shape — for
  /// example, a `GroupFieldSort` without a group-by, a sort field
  /// that isn't sortable, or a sort field that isn't the group-by
  /// field.
  incompatibleSortTarget,

  /// More than three group-by clauses were supplied on a query. The
  /// cap exists because densification with N group-bys produces a
  /// full cross-product of bucket combinations, which becomes
  /// intractable past three dimensions. Consumers needing higher-
  /// dimensional analyses should pre-aggregate upstream.
  tooManyGroupBys,

  /// More than one `TimeGroupBy` was supplied in the same query's
  /// `groupBys`. The pipeline can only meaningfully apply temporal
  /// densification along a single time axis; two `TimeGroupBy`
  /// dimensions would either disagree on the time axis or duplicate
  /// it. Use exactly one `TimeGroupBy` per query.
  multipleTemporalGroupBys,

  /// A `HavingClause` was supplied on a query that has no grouping.
  /// HAVING filters aggregated bucket values; a scalar (ungrouped)
  /// query produces a single value, not a set of buckets, so there
  /// is nothing for HAVING to operate on.
  havingRequiresGrouping,

  /// A derived operation (cumulative sum, delta, moving average) was
  /// applied to a measure whose output is not numeric (e.g. min/max
  /// over a `dateTime` field returns a `DateTimeValue`). Derived
  /// operations are only meaningful over numeric outputs.
  derivedOpRequiresNumericMeasure,

  /// Date-range projection or cross-source temporal alignment was
  /// requested against a source whose [SourceDef.primaryDateFieldId]
  /// is null. The primary date field is the page-level default for
  /// date-range filtering and the alignment axis for paired queries;
  /// sources without one cannot participate in either.
  ///
  /// Note: `TimeGroupBy` does not require a primary date field — it
  /// operates on whatever `dateTime` field its `dateFieldRef` points
  /// to.
  primaryDateFieldRequiredForOperation,

  /// A required precondition for the operation was not satisfied by
  /// the caller. Used for programmer errors that aren't expressible
  /// as a type — for example, calling `AnalyticsExecutor.execute`
  /// with a `StreakMeasure` query but without supplying the required
  /// `asOf` argument.
  ///
  /// Indicates a bug at the call site, not a problem with the user's
  /// data or query.
  preconditionViolation,

  /// A [SourceRecord] supplied a [TypedValue] whose subtype does not
  /// match the declared [FieldType] for that field on the source.
  /// Indicates a source-provider contract violation; the executor does
  /// not coerce or silently skip these records.
  sourceRecordTypeMismatch,

  /// Fallback for unexpected failures at integration boundaries.
  /// Core validator and executor code prefers more specific error
  /// kinds when the failure is anticipated. This kind is reserved for
  /// catch-all exception mapping at consumer integration points where
  /// no more precise kind applies.
  unexpected,
}

/// A typed error returned by the executor instead of thrown.
///
/// The executor returns `Err(AnalyticsError)` for every validation
/// failure; it never throws for these cases.
class AnalyticsError {
  const AnalyticsError({
    required this.kind,
    required this.humanMessage,
    this.affectedField,
  });

  final AnalyticsErrorKind kind;

  /// Null for source-level or shape-level errors that don't pertain
  /// to a specific field.
  final FieldRef? affectedField;

  /// Default user-facing message in English. Consumers that need
  /// localization should switch on [kind] and produce their own copy.
  final String humanMessage;

  @override
  String toString() =>
      'AnalyticsError(${kind.name}'
      '${affectedField != null ? ', $affectedField' : ''}'
      ': $humanMessage)';
}

// ── Result<T, E> ────────────────────────────────────────────────────────────

/// A sealed Ok/Err result type for operations that can fail with a
/// typed error rather than an exception.
///
/// Functions like `AnalyticsExecutor.execute` and `QueryValidator.*`
/// return `Result<T, AnalyticsError>` so callers get a compile-time
/// signal that both branches must be handled — no silent null returns,
/// no thrown exceptions for normal validation failures.
///
/// ## Consuming a `Result`
///
/// The idiomatic Dart 3 approach is pattern matching, which gives the
/// compiler exhaustiveness checks and lets you bind the inner value
/// in one step:
///
/// ```dart
/// switch (result) {
///   case Ok(value: final v):
///     // use v
///   case Err(error: final e):
///     // handle e
/// }
/// ```
///
/// For one-branch handling (e.g. only the success path), the
/// [okOrNull] and [errOrNull] accessors are simpler:
///
/// ```dart
/// final v = result.okOrNull;
/// if (v == null) return; // handle error
/// // use v
/// ```
///
/// Use pattern matching when both branches matter. Use the accessors
/// for quick early-return idioms.
sealed class Result<T, E> {
  const Result();

  bool get isOk => this is Ok<T, E>;
  bool get isErr => this is Err<T, E>;

  /// Returns the Ok value or null. Prefer pattern matching for code
  /// that needs to handle both branches.
  T? get okOrNull => switch (this) {
    Ok<T, E>(value: final v) => v,
    Err<T, E>() => null,
  };

  /// Returns the Err value or null.
  E? get errOrNull => switch (this) {
    Ok<T, E>() => null,
    Err<T, E>(error: final e) => e,
  };

  /// Chains another Result-returning step onto an Ok value, threading
  /// the error case through untouched. Lets callers express a sequence
  /// of validation checks without the unwrap-pattern-match boilerplate.
  Result<U, E> andThen<U>(Result<U, E> Function(T value) next) =>
      switch (this) {
        Ok<T, E>(value: final v) => next(v),
        Err<T, E>(error: final e) => Err<U, E>(e),
      };
}

class Ok<T, E> extends Result<T, E> {
  const Ok(this.value);
  final T value;
}

class Err<T, E> extends Result<T, E> {
  const Err(this.error);
  final E error;
}

// ── Unit ────────────────────────────────────────────────────────────────────

/// A zero-information value used as the success type of a `Result`
/// when the operation either succeeds or fails — no meaningful return
/// data beyond that.
///
/// `Result<Unit, E>` is preferred over `Result<bool, E>` for void-like
/// operations because the `true` in `Result<bool, E>` carries no
/// meaning. With `Unit`, the success case is honest: "it worked, here
/// is the sentinel."
///
/// Use the single canonical instance, [Unit.value]:
///
/// ```dart
/// Result<Unit, MyError> doThing() {
///   if (somethingWrong) return Err(MyError(...));
///   return const Ok(Unit.value);
/// }
/// ```
class Unit {
  const Unit._();

  /// The single canonical [Unit] value.
  static const Unit value = Unit._();

  @override
  String toString() => 'Unit';
}
