import '../schema/schema.dart';

/// What operation [FieldMeasure] applies to its field's values.
///
/// Sealed family. Each member has a deterministic output type per
/// [FieldType] — see [FieldAggregation.outputFieldType] for the full
/// mapping.
///
/// ## Cases
///
/// Zero-parameter members:
///
/// - [SumAgg]            — additive total over the field's values
/// - [AverageAgg]        — arithmetic mean over the field's values
/// - [MinAgg]            — minimum value
/// - [MaxAgg]            — maximum value
/// - [DistinctCountAgg]  — count of distinct non-null values
///
/// Parameterized members:
///
/// - [PercentileAgg]     — value at the given percentile via linear
///                         interpolation; `PercentileAgg(p: 0.5)` is
///                         the median
///
/// ## Why a sealed family rather than an enum
///
/// Parameterized aggregations like percentile do not fit a flat enum
/// — the parameter has nowhere to live without either a nullable
/// sibling field on `FieldMeasure` (which corrupts pattern matches
/// with invariants the type system doesn't enforce) or a separate
/// parallel-array shape (which has the same problem at a remove).
/// A sealed family puts the parameter on the variant that needs it,
/// leaves the parameterless variants clean, and matches the design
/// pattern used elsewhere for the same shape — see [DerivedOperation].
sealed class FieldAggregation {
  const FieldAggregation();

  /// Whether this aggregation can be applied to a field of [fieldType].
  ///
  /// The canonical compatibility table:
  ///
  /// - [SumAgg], [AverageAgg], [PercentileAgg] → numeric fields only
  ///   (integer, double, duration). String / enum / boolean / dateTime
  ///   are rejected.
  /// - [MinAgg], [MaxAgg] → ordered fields: integer, double, duration,
  ///   dateTime. String / enum / boolean are rejected.
  /// - [DistinctCountAgg] → any field type (counts distinct non-null
  ///   values; the value's type is irrelevant to the count).
  ///
  /// The validator consults this method when validating `FieldMeasure`
  /// queries; pattern-match against the same table when changing one
  /// to keep them in sync.
  bool compatibleWith(FieldType fieldType) {
    switch (this) {
      case SumAgg():
      case AverageAgg():
      case PercentileAgg():
        return fieldType == FieldType.integer ||
            fieldType == FieldType.double ||
            fieldType == FieldType.duration;
      case MinAgg():
      case MaxAgg():
        return fieldType == FieldType.integer ||
            fieldType == FieldType.double ||
            fieldType == FieldType.duration ||
            fieldType == FieldType.dateTime;
      case DistinctCountAgg():
        return true;
    }
  }

  /// The output [FieldType] for the `(this × fieldType)` combination.
  /// This method is the canonical source of truth for the table;
  /// validator and executor both call it rather than maintaining
  /// parallel tables.
  ///
  /// Throws [StateError] if [compatibleWith] returns false for the
  /// pair — callers (validator, executor) are expected to guard
  /// upstream; the defensive throw catches silent-wrong-answer bugs
  /// if that invariant ever breaks.
  FieldType outputFieldType(FieldType fieldType) {
    if (!compatibleWith(fieldType)) {
      throw StateError(
        'FieldAggregation.outputFieldType: unreachable combination '
        '($runtimeType on ${fieldType.name}); the validator should '
        'have rejected this query upstream.',
      );
    }
    switch (this) {
      case SumAgg():
        // int → int, double → double, duration → duration.
        return fieldType;
      case AverageAgg():
      case PercentileAgg():
        // int → double (means and percentiles of integers are
        // generally fractional), double → double, duration → duration.
        return fieldType == FieldType.integer ? FieldType.double : fieldType;
      case MinAgg():
      case MaxAgg():
        // Preserve input type (int → int, double → double,
        // duration → duration, dateTime → dateTime).
        return fieldType;
      case DistinctCountAgg():
        // Always returns a count.
        return FieldType.integer;
    }
  }
}

/// Additive total over the field's values.
///
/// Output type by field type:
///
/// - integer → `IntValue`
/// - double → `DoubleValue`
/// - duration → `DurationValue`
///
/// Rejected by the validator on string, enum, boolean, and dateTime
/// fields.
class SumAgg extends FieldAggregation {
  const SumAgg();

  @override
  bool operator ==(Object other) => other is SumAgg;

  @override
  int get hashCode => runtimeType.hashCode;
}

/// Arithmetic mean over the field's values.
///
/// Output type by field type:
///
/// - integer → `DoubleValue` (the mean of integers is generally
///   fractional)
/// - double → `DoubleValue`
/// - duration → `DurationValue`
///
/// Rejected by the validator on string, enum, boolean, and dateTime
/// fields. Returns `null` for empty / all-null groups.
class AverageAgg extends FieldAggregation {
  const AverageAgg();

  @override
  bool operator ==(Object other) => other is AverageAgg;

  @override
  int get hashCode => runtimeType.hashCode;
}

/// Minimum value.
///
/// Output type by field type:
///
/// - integer → `IntValue`
/// - double → `DoubleValue`
/// - duration → `DurationValue`
/// - dateTime → `DateTimeValue`
///
/// Rejected by the validator on string, enum, and boolean fields.
/// Returns `null` for empty / all-null groups.
class MinAgg extends FieldAggregation {
  const MinAgg();

  @override
  bool operator ==(Object other) => other is MinAgg;

  @override
  int get hashCode => runtimeType.hashCode;
}

/// Maximum value.
///
/// Output type by field type:
///
/// - integer → `IntValue`
/// - double → `DoubleValue`
/// - duration → `DurationValue`
/// - dateTime → `DateTimeValue`
///
/// Rejected by the validator on string, enum, and boolean fields.
/// Returns `null` for empty / all-null groups.
class MaxAgg extends FieldAggregation {
  const MaxAgg();

  @override
  bool operator ==(Object other) => other is MaxAgg;

  @override
  int get hashCode => runtimeType.hashCode;
}

/// Count of distinct non-null values.
///
/// Output type is always `IntValue` regardless of input field type.
/// Compatible with every field type the package supports.
class DistinctCountAgg extends FieldAggregation {
  const DistinctCountAgg();

  @override
  bool operator ==(Object other) => other is DistinctCountAgg;

  @override
  int get hashCode => runtimeType.hashCode;
}

/// Value at the [p]th percentile via linear interpolation between
/// the two surrounding sample indices ("type 7" interpolation, as
/// used by NumPy and most BI tools).
///
/// `PercentileAgg(p: 0.5)` is the median; the package does not
/// provide a separate `MedianAgg` since the two would be structurally
/// redundant.
///
/// Output type by field type:
///
/// - integer → `DoubleValue` (linear interpolation generally produces
///   fractional values)
/// - double → `DoubleValue`
/// - duration → `DurationValue` (durations interpolate naturally via
///   microsecond arithmetic)
///
/// Rejected by the validator on string, enum, boolean, and dateTime
/// fields. Returns `null` for empty / all-null groups.
///
/// ## Parameter
///
/// [p] must be in the closed interval `[0, 1]`. The validator rejects
/// out-of-range values as `AnalyticsErrorKind.invalidAggregationParameter`.
///
/// The constructor does not assert the range — invalid values fail
/// at validation time, paralleling how `MovingAverageOp` handles
/// `window` parameters.
class PercentileAgg extends FieldAggregation {
  const PercentileAgg({required this.p});

  /// The percentile to compute, in `[0, 1]`. `0.5` is the median;
  /// `0.95` is the 95th percentile.
  final double p;

  @override
  bool operator ==(Object other) => other is PercentileAgg && other.p == p;

  @override
  int get hashCode => Object.hash(runtimeType, p);
}

/// What to compute on a group of records.
///
/// Sealed shape with three cases:
///
/// - [CountMeasure]   — count records
/// - [FieldMeasure]   — aggregate a numeric or temporal field
/// - [StreakMeasure]  — compute streak statistics over scheduled vs.
///                      completed events per entity
///
/// Every measure carries a [supportsDateRange] capability flag. The
/// validator enforces that the `dateRangeMode` on the enclosing widget
/// agrees with this flag.
///
/// Each measure also has a well-defined output type used to populate
/// `ScalarResult.value`, `SeriesBucket.value`, `NamedSeries.values`,
/// `MeasureSeries.values`, and `TableColumn.values` for measure
/// columns. See [Measure.outputFieldType] for the full per-subtype
/// rule.
sealed class Measure {
  const Measure({this.label});

  /// Optional consumer-supplied label for this measure. Used by
  /// `HavingClause.measureLabel` and `MeasureValueSort.measureLabel`
  /// to disambiguate which measure they target in multi-measure
  /// queries, and used as the measure column label in `TableResult`
  /// projections and as `measureLabel` on chart-shape view types.
  ///
  /// When null, the executor falls back to a stable auto-generated
  /// label of the form `'measure_<index>'` where index is the
  /// measure's position in the query's `measures` list. The
  /// auto-generated label is addressable by `HavingClause` and
  /// `MeasureValueSort` in the same way as an explicit label.
  ///
  /// Within a single query the validator requires every measure's
  /// effective label (explicit or auto-generated) to be unique —
  /// otherwise label-based disambiguation would be ambiguous.
  final String? label;

  /// Whether this measure has a meaningful interpretation under a
  /// widget date range. `StreakMeasure` returns false because streaks
  /// are computed over an entity's full lifetime, not a date window.
  bool get supportsDateRange;

  /// The output [FieldType] this measure produces per bucket — the
  /// type that populates `ScalarResult.value`, `SeriesBucket.value`,
  /// `NamedSeries.values`, and `TableColumn.values` (for the measure
  /// column).
  ///
  /// Resolution by subtype:
  ///
  /// - [CountMeasure] → `FieldType.integer`.
  /// - [FieldMeasure] → delegates to
  ///   [FieldAggregation.outputFieldType] using the resolved field's
  ///   `fieldType`.
  /// - [StreakMeasure] → `null`. Streak does not produce a single
  ///   per-bucket aggregated value; it produces a multi-column result
  ///   table (one group-key column for the entity ID, plus three
  ///   measure columns: entity label, current streak, longest streak).
  ///   Callers (validator, executor) special-case this branch.
  ///
  /// Throws [StateError] if a [FieldMeasure]'s field cannot be
  /// resolved against [source]; the validator should have rejected
  /// such queries upstream, so reaching this branch is a bug.
  ///
  /// This is the single source of truth for the
  /// `(measure × source) → output-type` mapping. Validator and
  /// executor both call it; they must not maintain parallel tables.
  FieldType? outputFieldType(SourceDef source) {
    switch (this) {
      case CountMeasure():
        return FieldType.integer;
      case FieldMeasure(fieldRef: final ref, aggregation: final agg):
        final field = source.fieldById(ref.fieldId);
        if (field == null) {
          throw StateError(
            'Measure.outputFieldType: unknown field ${ref.fieldId} on '
            'source ${source.sourceId}; validator should have rejected '
            'this query upstream.',
          );
        }
        return agg.outputFieldType(field.fieldType);
      case StreakMeasure():
        return null;
    }
  }

  /// Returns the effective labels for [measures], applying the
  /// canonical auto-label rule for measures whose [label] is `null`.
  ///
  /// The rule: if a measure has an explicit `label`, that label is its
  /// effective label; otherwise the effective label is
  /// `'measure_<index>'` where `index` is the measure's position in
  /// [measures] (0-based). The result is index-aligned to [measures].
  ///
  /// This is the single source of truth for the auto-label rule:
  ///
  /// - The validator uses it to enforce effective-label uniqueness
  ///   (`duplicateMeasureLabel`) and to resolve
  ///   `HavingClause.measureLabel` and `MeasureValueSort.measureLabel`
  ///   references.
  /// - The executor uses it to label measure columns in `TableResult`
  ///   results and to populate the per-series `key` /
  ///   `measureLabels` entries (and the per-`MeasureSeries` labels in
  ///   `MultiMeasureSeriesResult`).
  ///
  /// Auto-labels are stable across builds — index-based — so consumers
  /// building round-trippable JSON references can rely on them without
  /// having to set explicit labels.
  static List<String> effectiveLabelsFor(List<Measure> measures) {
    return [
      for (var i = 0; i < measures.length; i++)
        measures[i].label ?? 'measure_$i',
    ];
  }
}

class CountMeasure extends Measure {
  const CountMeasure({super.label});

  @override
  bool get supportsDateRange => true;

  @override
  bool operator ==(Object other) =>
      other is CountMeasure && other.label == label;

  @override
  int get hashCode => Object.hash(runtimeType, label);
}

class FieldMeasure extends Measure {
  const FieldMeasure({
    required this.fieldRef,
    required this.aggregation,
    super.label,
  });

  final FieldRef fieldRef;
  final FieldAggregation aggregation;

  @override
  bool get supportsDateRange => true;

  @override
  bool operator ==(Object other) =>
      other is FieldMeasure &&
      other.fieldRef == fieldRef &&
      other.aggregation == aggregation &&
      other.label == label;

  @override
  int get hashCode => Object.hash(fieldRef, aggregation, label);
}

/// Streak measure — counts consecutive successful events per entity.
///
/// Computes, for each entity in a source, the current and longest
/// streak of consecutive scheduled dates whose status matches a
/// "success" value. The result is a `TableResult` with one row per
/// entity and four columns: entity ID (group-key), entity label,
/// current streak, longest streak.
///
/// Use cases include habit trackers (consecutive days a habit was
/// performed), study streaks, fitness logs, task completion runs, etc.
/// The measure is source-agnostic — it needs four field references
/// and a string value that marks the "success" status.
///
/// `StreakMeasure` ignores `groupBys`, `sort`, and `derivedOperation`
/// at execution time. The validator rejects queries that try to
/// combine it with any of those.
///
/// ## Worked example
///
/// Consider one entity tracked over 10 consecutive scheduled days,
/// with the following completion pattern (`✓` = done, `✗` = missed):
///
/// ```
/// day:    1 2 3 4 5 6 7 8 9 10
/// status: ✓ ✓ ✓ ✓ ✓ ✗ ✗ ✓ ✓ ✓
/// ```
///
/// Walking left to right, the run of consecutive ✓s grows to 5 across
/// days 1–5, breaks at day 6, then a new run begins at day 8 and is
/// at length 3 when the walk reaches day 10. With `asOf` set to day
/// 10 (or any later date), the streak row for this entity is:
///
/// * `longestStreak = 5` — the days 1–5 run, the longest anywhere in
///   the entity's history.
/// * `currentStreak = 3` — the days 8–10 run, still active at the
///   most recent scheduled day.
///
/// "Current" is the run that ends at — or has not yet been broken
/// before — the reference date `asOf`. "Longest" is the longest run
/// anywhere in the entity's full schedule. The two are independent;
/// one entity's current streak can equal, exceed (when the active
/// run is itself the longest), or fall short of its longest.
class StreakMeasure extends Measure {
  const StreakMeasure({
    required this.entityIdField,
    required this.scheduledDateField,
    required this.statusField,
    required this.completedStatusValue,
    this.entityLabelField,
    this.topN,
    super.label,
  });

  /// Identity field used to group records into per-entity streaks.
  /// Each unique value here produces one row in the result table.
  final FieldRef entityIdField;

  /// The scheduled-date field; the streak walks consecutive values of
  /// this field looking for successful completions. Must be a
  /// `dateTime` field — the validator enforces this.
  final FieldRef scheduledDateField;

  /// The status field whose value is compared against
  /// [completedStatusValue] to decide whether a scheduled day counts
  /// as completed. Must be a `string` or `enumeration` field — the
  /// validator enforces this.
  final FieldRef statusField;

  /// The value of [statusField] that means "completed". Compared as a
  /// string.
  final String completedStatusValue;

  /// Optional field providing a human-readable label for each entity.
  /// When set, the executor uses this field's value as the
  /// `entityLabel` column in the result table. When null, the
  /// [entityIdField] value is used instead.
  ///
  /// Must be a `string` field — the validator enforces this. The
  /// executor picks the first non-empty value it encounters per
  /// entity.
  final FieldRef? entityLabelField;

  /// Optional cap on the number of rows returned. `null` means no
  /// cap. Must be non-negative when set; the validator rejects
  /// negative values as `preconditionViolation`. The total row count
  /// is preserved as `TableResult.truncatedCount` so a renderer can
  /// show "+N more" if desired.
  ///
  /// Streak-specific. Do not lift onto the generic `AnalyticsQuerySpec`
  /// — the streak result is the only one currently shaped as a ranked
  /// leaderboard.
  final int? topN;

  @override
  bool get supportsDateRange => false;

  @override
  bool operator ==(Object other) =>
      other is StreakMeasure &&
      other.entityIdField == entityIdField &&
      other.scheduledDateField == scheduledDateField &&
      other.statusField == statusField &&
      other.completedStatusValue == completedStatusValue &&
      other.entityLabelField == entityLabelField &&
      other.topN == topN &&
      other.label == label;

  @override
  int get hashCode => Object.hash(
    entityIdField,
    scheduledDateField,
    statusField,
    completedStatusValue,
    entityLabelField,
    topN,
    label,
  );
}
