import '../errors.dart';
import '../query/measure.dart';
import '../query/query_components.dart';
import '../query/query_enums.dart';
import '../query/query_spec.dart';
import '../results.dart';
import '../schema/schema.dart';
import '../schema/source_lookup.dart';
import '../schema/typed_value.dart';
import '../time_series/streak_executor.dart';
import '../validator.dart';
import 'aggregation_engine.dart';
import 'derived_engine.dart';
import 'filter_engine.dart';
import 'grouping_engine.dart';
import 'source_record.dart';

/// The analytics executor.
///
/// Pure function: takes a query, a record stream, and a source
/// catalog; returns a typed `Result<AnalyticsResult, AnalyticsError>`.
/// Never throws for validation failures — those come back as `Err`.
/// May throw `StateError` only for invariants the validator was
/// expected to enforce upstream (those are bugs, not data conditions).
///
/// ## Pipeline
///
/// 1. Validate the query against the catalog. On `Err`, short-circuit.
/// 2. Walk records once and reject any whose [TypedValue] subtype
///    doesn't match the declared [FieldType] on the source, returning
///    `Err(sourceRecordTypeMismatch)`. After this pass every downstream
///    engine can dispatch on the declared field type without runtime
///    sniffing.
/// 3. **Streak short-circuit** — if any measure is `StreakMeasure`
///    (which the validator guarantees means there's exactly one
///    measure, via `streakNotCombinable`), delegate to `StreakExecutor`
///    and return its `TableResult`. The streak pipeline ignores
///    `groupBys`, `sort`, `limit`, and `derivedOperation`.
/// 4. Filter records by the query's filter list.
/// 5. Build per-measure aggregator closures (one per measure; each
///    captures its field resolution / dispatch table). Pre-compute
///    effective labels (auto-labels for measures with null `label`)
///    and output `FieldType`s — both used by HAVING/sort target
///    resolution AND by the result-construction helpers.
/// 6. **0-`groupBy` short-circuit** — if `groupBys` is empty:
///       * Single measure → `ScalarResult` with the aggregated value.
///       * Multi-measure → single-row foundational `TableResult` with
///         zero group-key columns, N measure columns, and a length-0
///         tuple `RowKey([])`.
/// 7. **N-level partition** — every record contributes to one bucket
///    keyed by its `(groupBys-tuple)` row key, via
///    `GroupingEngine.keyTupleFor`. Same code path for 1, 2, or 3
///    group-bys.
/// 8. Aggregate each bucket: each of the N per-measure aggregators
///    runs once, producing a cell with a `values` list of length N
///    (index-aligned to `query.measures`).
/// 9. **Cross-product densification** (skipped if `densify: false`)
///    — per-axis observed keys are Cartesian-producted (with the
///    temporal axis extended via [dateRange] when present). Missing
///    combinations are filled with a shared `emptyValues` list (each
///    entry is its measure's empty-group aggregate — typed zero for
///    additive aggregations, `null` for non-additive). Filled cells
///    are marked `isSynthetic: true` so build helpers can propagate
///    the marker to the result types. Cells are emitted in
///    lexicographic row-key order. When `densify` is `false`, this
///    step is replaced by a sort-by-row-key pass over the observed
///    cells, preserving the same lex order without filling.
/// 10. **HAVING** — drops cells whose `values[measureIdx]` fails the
///     [HavingClause] comparison. `measureIdx` is resolved up front
///     from `HavingClause.measureLabel` (or `0` for single-measure
///     queries). Works for any non-empty `groupBys`.
/// 11. **Sort** — applies user-requested ordering. `GroupFieldSort`
///     resolves the target field to its axis index and sorts by
///     `rowKey.keys[axisIdx]`; `MeasureValueSort` resolves the target
///     measure to its index and sorts by `values[measureIdx]`. Works
///     for any non-empty `groupBys`.
/// 12. **Limit** — caps the cell list (SQL `LIMIT` semantics). For
///     2-`groupBy` queries, truncation may produce a wide-format
///     rendering with nulls at the dropped positions.
/// 13. **Result construction** — by `(groupBys.length, measures.length)`:
///       * (1, 1) → `SeriesResult` (chart-shape view).
///       * (2, 1) → `MultiSeriesResult` (chart-shape view; long-format
///         unflatten on `toTableResult`).
///       * (1, N≥2) → `MultiMeasureSeriesResult` (chart-shape view;
///         wide-format on `toTableResult`).
///       * (2, N≥2) → `TableResult` (4D shape; no chart-shape view).
///       * (3, anything) → `TableResult` (foundational).
///       * (0, *) and streak handled by earlier short-circuits.
/// 14. **Derived operation** — applies cumulative sum, delta, or
///     moving average to a `SeriesResult`. Validator restricts derived
///     ops to `SeriesResult`-shaped queries (single `groupBy`, single
///     numeric measure), so this step is a no-op for every other
///     result type.
///
/// Display labels on result types ([ScalarResult.measureLabel],
/// [SeriesBucket.displayLabel], [XAxisPosition.label], etc.) are
/// left at their defaults — consumer-supplied labels can be attached
/// by post-processing the result.
abstract class AnalyticsExecutor {
  /// Executes [query] against [records] using [sources] for validation.
  ///
  /// [asOf] is required by `StreakMeasure` as the reference date for
  /// "current streak" — the caller must supply it. For non-streak
  /// queries it is unused.
  ///
  /// [dateRange] is the resolved page-level date range the caller
  /// used to fetch [records]. When [densify] is `true` (the default)
  /// and the query uses `TimeGroupBy`, a non-null `dateRange` extends
  /// the temporal axis so every grain-aligned bucket in
  /// `[startInclusive, endExclusive)` is represented. When `densify`
  /// is `false`, `dateRange` is ignored — the executor only emits
  /// observed buckets.
  ///
  /// [densify] controls whether the executor fills missing bucket
  /// combinations. When `true` (default), the cross-product over
  /// per-axis observed keys is materialized — missing combinations
  /// get synthetic cells with additive-zero or non-additive-null
  /// values, matching what every chart renderer expects. When `false`,
  /// the result reflects only observed combinations and no synthetic
  /// cells are emitted. Use `false` for non-chart consumers (CSV
  /// export, raw aggregation pipelines) that want sparse data.
  ///
  /// Regardless of [densify], result types carry synthetic-tracking
  /// fields ([SeriesBucket.isSynthetic], [NamedSeries.syntheticValueIndices],
  /// [MultiMeasureSeriesResult.syntheticXAxisIndices],
  /// [TableResult.syntheticRowIndices]) so consumers can distinguish
  /// densified cells from observed cells even on the default path.
  /// These fields are always empty when `densify: false`.
  ///
  /// Bucket counts are the caller's responsibility — the executor
  /// produces as many buckets as the grain and range require. For
  /// queries that might produce impractically many buckets (e.g. a
  /// 5-year range at minute grain), the caller should choose a
  /// coarser grain or shorter range upstream.
  static Result<AnalyticsResult, AnalyticsError> execute({
    required AnalyticsQuerySpec query,
    required Iterable<SourceRecord> records,
    required List<SourceDef> sources,
    DateTime? asOf,
    (DateTime, DateTime)? dateRange,
    bool densify = true,
  }) {
    // Validate.
    if (QueryValidator.validateQuery(query, sources: sources) case Err(
      error: final e,
    )) {
      return Err(e);
    }

    final source = findSourceById(sources, query.source)!;

    // Walk records once and confirm each value's TypedValue subtype
    // agrees with the source's declared field types. After this pass,
    // every downstream engine can dispatch on the declared FieldType
    // without runtime sniffing.
    final validated = <SourceRecord>[];
    for (final r in records) {
      final mismatch = _firstTypeMismatch(r, source);
      if (mismatch != null) return Err(mismatch);
      validated.add(r);
    }

    // Streak takes its own pipeline — no group-by, no derived op.
    // `streakNotCombinable` (in the validator) ensures that whenever
    // a streak measure is present in `query.measures`, it is the only
    // measure; so checking `measures.length == 1 && measures.single is
    // StreakMeasure` is equivalent to "contains streak."
    final measures = query.measures;
    if (measures.length == 1 && measures.single is StreakMeasure) {
      if (asOf == null) {
        return const Err(
          AnalyticsError(
            kind: AnalyticsErrorKind.preconditionViolation,
            humanMessage:
                'StreakMeasure requires `asOf` to be supplied to '
                'AnalyticsExecutor.execute.',
          ),
        );
      }
      return Ok(
        StreakExecutor.execute(
          measures.single as StreakMeasure,
          validated,
          asOf: asOf,
        ),
      );
    }

    // Filter.
    final filtered = <SourceRecord>[];
    for (final r in validated) {
      if (FilterEngine.matchesAll(r, query.filters)) {
        filtered.add(r);
      }
    }

    // Build per-measure aggregator closures up front. Each closure
    // captures its measure's field resolution / dispatch table, so
    // per-bucket calls skip the measure-type dispatch entirely — N
    // aggregator calls per bucket, not N × per-record dispatches.
    final aggregators = [for (final m in measures) _aggregatorFor(m, source)];

    // Pre-compute effective labels (auto-labels filled in for measures
    // with null `label`) and output types — both used by HAVING/sort
    // target resolution AND by the result-construction helpers. Single
    // source of truth per execution.
    final effectiveLabels = Measure.effectiveLabelsFor(measures);
    final measureOutputTypes = [
      for (final m in measures) _resolveMeasureOutputType(m, source),
    ];

    final groupBys = query.groupBys;

    // 0-`groupBy` short-circuit: a single implicit bucket holding all
    // filtered records. Two branches based on measure cardinality:
    //
    // - Single measure → `ScalarResult` (one wrapped TypedValue).
    // - Multi-measure → a foundational `TableResult` with zero group-key
    //   columns, N measure columns, and a single row whose row key is
    //   the empty tuple `RowKey([])`. This is the natural extension of
    //   "single bucket, multiple aggregated values" to the column-
    //   oriented foundational shape; the empty-tuple row key signals
    //   "no grouping dimension."
    if (groupBys.isEmpty) {
      final aggregatedValues = [for (final agg in aggregators) agg(filtered)];
      if (measures.length == 1) {
        return Ok(ScalarResult(value: aggregatedValues[0]));
      }
      // Multi-measure 0-`groupBy`: single-row wide TableResult.
      final cell = _GroupedCell(
        rowKey: RowKey(const []),
        values: aggregatedValues,
      );
      return Ok(
        _buildTableResult(
          [cell],
          groupBys,
          source,
          measureLabels: effectiveLabels,
          measureFieldTypes: measureOutputTypes,
        ),
      );
    }

    // N-level partition. Every record contributes to exactly one
    // bucket, keyed by its (groupBys-tuple) row key.
    final buckets = <RowKey, List<SourceRecord>>{};
    for (final r in filtered) {
      final rowKey = GroupingEngine.keyTupleFor(r, groupBys);
      buckets.putIfAbsent(rowKey, () => []).add(r);
    }

    // Aggregate each bucket — every aggregator runs once per bucket,
    // producing one cell with a `values` list index-aligned to
    // `measures`. The bucket's records are walked once per aggregator
    // (internally), but the partition pass and densification pass each
    // touch each record at most once. The partition work is per-record;
    // adding more measures only multiplies the per-bucket aggregator
    // closure invocations, not the partition cost.
    var cells = <_GroupedCell>[
      for (final entry in buckets.entries)
        _GroupedCell(
          rowKey: entry.key,
          values: [for (final agg in aggregators) agg(entry.value)],
        ),
    ];

    // Cross-product densification (skippable). When `densify` is true
    // (default), per-axis observed keys are Cartesian-producted (with
    // the temporal axis extended if applicable). Missing combinations
    // share a single immutable `emptyValues` list — each aggregator's
    // empty-bucket value, in measure order — and are marked
    // `isSynthetic: true` so build helpers can propagate the marker to
    // the result types. Sharing the list is safe because cells are not
    // mutated downstream.
    //
    // When `densify` is false, the cells are sorted by row key (using
    // the same per-axis ordering as densification) so result ordering
    // is consistent regardless of the flag, but no synthetic cells are
    // emitted and no time-axis extension happens.
    //
    // Cross-product is documented as a footgun for 3-groupBy queries:
    // N-dimensional density with high cardinality on each axis can
    // explode bucket counts. Consumers are responsible for capping
    // cardinality upstream.
    if (densify) {
      final emptyValues = [
        for (final agg in aggregators) agg(const <SourceRecord>[]),
      ];
      cells = _crossProductDensify(
        observed: cells,
        groupBys: groupBys,
        dateRange: dateRange,
        emptyValues: emptyValues,
      );
    } else {
      cells = _sortCellsByRowKey(cells);
    }

    // HAVING — post-aggregation filtering on the target measure's
    // value. Resolve the measure index once: for single-measure
    // queries the label is allowed to be null (defaults to the only
    // measure); for multi-measure the validator has guaranteed a
    // non-null label that resolves to one of the effective labels.
    final having = query.having;
    if (having != null) {
      final havingMeasureIdx = having.measureLabel == null
          ? 0
          : effectiveLabels.indexOf(having.measureLabel!);
      cells = cells
          .where((c) => _cellSatisfiesHaving(c, having, havingMeasureIdx))
          .toList();
    }

    // User-requested sort. `GroupFieldSort` resolves to the matching
    // axis index inside `_applySortToCells`; `MeasureValueSort`
    // resolves its target measure here so the index is computed once
    // (not per comparator invocation). For `GroupFieldSort` the
    // measure index is unused — passing 0 is conventional.
    final sort = query.sort;
    if (sort != null) {
      final int sortMeasureIdx;
      if (sort.target case MeasureValueSort(measureLabel: final label)) {
        sortMeasureIdx = label == null ? 0 : effectiveLabels.indexOf(label);
      } else {
        sortMeasureIdx = 0; // unused for GroupFieldSort
      }
      _applySortToCells(cells, sort, groupBys, sortMeasureIdx);
    }

    // Limit. Truncates the cell list after sort, following SQL
    // `LIMIT` semantics: the first N cells from the sorted list are
    // kept. For 2-`groupBy` queries the truncation drops individual
    // `(primary, secondary)` cells; the wide-format renderer
    // surfaces this as null entries at the dropped positions.
    final limited = (query.limit != null && query.limit! < cells.length)
        ? cells.sublist(0, query.limit!)
        : cells;

    // Result-type branching by `(groupBys.length, measures.length)`:
    //
    // - (1, 1) → SeriesResult (chart-shape view)
    // - (2, 1) → MultiSeriesResult (chart-shape view; long-format unflatten)
    // - (1, N) → MultiMeasureSeriesResult (chart-shape view; wide-format)
    // - (2, N) → TableResult (4D shape; no chart-shape view)
    // - (3, anything) → TableResult (foundational)
    // - (0, *) handled by the 0-`groupBy` short-circuit above.
    //
    // The streak shape and the 0-`groupBy` shapes are handled by their
    // own short-circuits earlier. Reaching the `default` branches here
    // is a validator bug (cap-3 / cap-5 constraints).
    final AnalyticsResult result;
    if (measures.length == 1) {
      switch (groupBys.length) {
        case 1:
          result = _buildSeriesResult(
            limited,
            groupBys.single,
            source,
            measureLabel: effectiveLabels[0],
            measureFieldType: measureOutputTypes[0],
          );
        case 2:
          result = _buildMultiSeriesResult(
            limited,
            groupBys,
            source,
            measureLabel: effectiveLabels[0],
            measureFieldType: measureOutputTypes[0],
          );
        case 3:
          result = _buildTableResult(
            limited,
            groupBys,
            source,
            measureLabels: effectiveLabels,
            measureFieldTypes: measureOutputTypes,
          );
        default:
          throw StateError(
            'AnalyticsExecutor: unexpected groupBys cardinality '
            '${groupBys.length} (single-measure); validator should cap at 3.',
          );
      }
    } else {
      // Multi-measure (N >= 2).
      switch (groupBys.length) {
        case 1:
          result = _buildMultiMeasureSeriesResult(
            limited,
            groupBys.single,
            source,
            measureLabels: effectiveLabels,
            measureFieldTypes: measureOutputTypes,
          );
        case 2:
        case 3:
          result = _buildTableResult(
            limited,
            groupBys,
            source,
            measureLabels: effectiveLabels,
            measureFieldTypes: measureOutputTypes,
          );
        default:
          throw StateError(
            'AnalyticsExecutor: unexpected groupBys cardinality '
            '${groupBys.length} (multi-measure); validator should cap at 3.',
          );
      }
    }

    // Derived operation — only meaningful on SeriesResult (single
    // groupBy, single numeric measure). Validator enforces both, so
    // non-SeriesResult branches carry `NoDerivedOp` and the apply
    // step is a no-op.
    if (result is SeriesResult) {
      return Ok(DerivedEngine.apply(result, query.derivedOperation));
    }
    return Ok(result);
  }

  // ── Helpers ───────────────────────────────────────────────────────────

  /// Builds a per-query aggregator closure: a function that maps a
  /// record group to its aggregated value. For [FieldMeasure], the
  /// field is resolved once here rather than once per bucket.
  ///
  /// Throws `StateError` if the validator's invariants are violated
  /// (unknown field on a FieldMeasure; StreakMeasure routed here).
  /// Both should be unreachable for queries that passed validation.
  static TypedValue? Function(Iterable<SourceRecord>) _aggregatorFor(
    Measure measure,
    SourceDef source,
  ) {
    switch (measure) {
      case CountMeasure():
        return AggregationEngine.count;
      case FieldMeasure(fieldRef: final ref, aggregation: final agg):
        final field = source.fieldById(ref.fieldId);
        if (field == null) {
          throw StateError(
            'AnalyticsExecutor._aggregatorFor: unknown field '
            '${ref.fieldId} on source ${source.sourceId}; validator '
            'should have rejected this query.',
          );
        }
        return (group) => AggregationEngine.aggregateField(group, field, agg);
      case StreakMeasure():
        // Unreachable: streak has its own pipeline.
        throw StateError(
          'AnalyticsExecutor._aggregatorFor: called with StreakMeasure; '
          'streak queries should be routed to StreakExecutor.',
        );
    }
  }

  /// Returns an [AnalyticsError] of kind [AnalyticsErrorKind.sourceRecordTypeMismatch]
  /// for the first field of [record] whose [TypedValue] subtype does
  /// not agree with the declared [FieldType] on [source]. Returns
  /// `null` when every declared field in the record is either of the
  /// declared type or [NullValue].
  ///
  /// Fields present in the record but not declared on [source] are
  /// ignored — they have no analytics meaning. [NullValue] of any
  /// declared type is treated as a valid "no data" signal.
  static AnalyticsError? _firstTypeMismatch(
    SourceRecord record,
    SourceDef source,
  ) {
    for (final entry in record.fields.entries) {
      final field = source.fieldById(entry.key);
      if (field == null) continue;
      final value = entry.value;
      if (value is NullValue) continue;
      if (value.fieldType != field.fieldType) {
        return AnalyticsError(
          kind: AnalyticsErrorKind.sourceRecordTypeMismatch,
          affectedField: field.ref,
          humanMessage:
              'Source record for field ${field.fieldId} on '
              '${source.sourceId} carries a ${value.fieldType.name} '
              'value, but the field is declared as ${field.fieldType.name}.',
        );
      }
    }
    return null;
  }

  /// Sorts [cells] in place per [sort].
  ///
  /// Null aggregation values and `NullBucketKey`s always sort last,
  /// regardless of direction — matching SQL's `NULLS LAST` convention.
  /// Non-null values sort according to [Sort.direction].
  ///
  /// Works for any row-key cardinality. For [GroupFieldSort] the
  /// target field is resolved to its axis index in [groupBys] (the
  /// validator has already verified the field matches one of the
  /// group-bys), and cells are sorted on `rowKey.keys[axisIdx]`. For
  /// [MeasureValueSort] cells are sorted on `values[measureIdx]` —
  /// [measureIdx] resolved by the caller from `MeasureValueSort.measureLabel`
  /// (or 0 for single-measure queries where the label is null).
  ///
  /// [measureIdx] is ignored when [sort.target] is [GroupFieldSort];
  /// callers may pass any value (e.g., 0) in that case.
  static void _applySortToCells(
    List<_GroupedCell> cells,
    Sort sort,
    List<GroupBy> groupBys,
    int measureIdx,
  ) {
    final descending = sort.direction == SortDirection.descending;

    // For GroupFieldSort, resolve the target field to an axis index
    // up front so the per-element comparator doesn't repeat the work.
    int? groupAxisIdx;
    if (sort.target case GroupFieldSort(fieldRef: final targetRef)) {
      for (var i = 0; i < groupBys.length; i++) {
        final g = groupBys[i];
        final ref = switch (g) {
          FieldGroupBy(fieldRef: final r) => r,
          TimeGroupBy(dateFieldRef: final r) => r,
        };
        if (ref == targetRef) {
          groupAxisIdx = i;
          break;
        }
      }
      if (groupAxisIdx == null) {
        // The validator's sort-target rule guarantees the field
        // matches one of the group-bys. Failing here would be a
        // validator bug.
        throw StateError(
          'AnalyticsExecutor._applySortToCells: GroupFieldSort target '
          '${targetRef.fieldId} does not match any group-by; validator '
          'should have rejected.',
        );
      }
    }

    int compare(_GroupedCell a, _GroupedCell b) {
      // Each case sets these three locals; the post-switch logic
      // applies null position and direction uniformly so the two
      // cases don't each duplicate the rule.
      final bool aNull;
      final bool bNull;
      final int rawCompare;
      switch (sort.target) {
        case GroupFieldSort():
          final aKey = a.rowKey.keys[groupAxisIdx!];
          final bKey = b.rowKey.keys[groupAxisIdx];
          aNull = aKey is NullBucketKey;
          bNull = bKey is NullBucketKey;
          rawCompare = (aNull || bNull)
              ? 0
              : BucketKeyOrdering.compare(aKey, bKey);
        case MeasureValueSort():
          final av = a.values[measureIdx];
          final bv = b.values[measureIdx];
          aNull = av == null;
          bNull = bv == null;
          rawCompare = (aNull || bNull)
              ? 0
              : (TypedValueOrdering.compare(av, bv) ?? 0);
      }

      if (aNull && bNull) return 0;
      if (aNull != bNull) {
        // Exactly one operand is null. Nulls go to the end when
        // `forceNullsLast` is set, or by default when the sort is
        // ascending (the SQL convention). Otherwise — a descending
        // sort with `forceNullsLast` off — nulls go to the start.
        final nullsLast = sort.forceNullsLast || !descending;
        if (nullsLast) return aNull ? 1 : -1;
        return aNull ? -1 : 1;
      }
      return descending ? -rawCompare : rawCompare;
    }

    cells.sort(compare);
  }

  /// Whether [cell]'s [measureIdx]th aggregated value satisfies
  /// [having]'s comparison against its threshold.
  ///
  /// [measureIdx] is the position of the measure HAVING targets in
  /// `AnalyticsQuerySpec.measures` — resolved by the caller from
  /// `HavingClause.measureLabel` (or 0 for single-measure queries
  /// where the label is null).
  ///
  /// Cells with a null value at that index (the result of non-additive
  /// aggregations over empty / all-null groups, including synthetic
  /// densified cells) never satisfy HAVING — a null value has no
  /// defined ordering against a non-null threshold, and the validator
  /// already rejected null thresholds.
  ///
  /// The validator has enforced that the target measure's value type
  /// matches the threshold's type, so `TypedValueOrdering.compare`
  /// returns a non-null comparison when the value is non-null.
  static bool _cellSatisfiesHaving(
    _GroupedCell cell,
    HavingClause having,
    int measureIdx,
  ) {
    final value = cell.values[measureIdx];
    if (value == null) return false;
    final cmp = TypedValueOrdering.compare(value, having.threshold);
    if (cmp == null) {
      // The validator's threshold-type check should have made this
      // unreachable. Failing closed (drop the cell) is safer than
      // silently passing one through with a meaningless comparison.
      return false;
    }
    switch (having.operator) {
      case HavingOperator.equals:
        return cmp == 0;
      case HavingOperator.notEquals:
        return cmp != 0;
      case HavingOperator.lessThan:
        return cmp < 0;
      case HavingOperator.lessThanOrEqual:
        return cmp <= 0;
      case HavingOperator.greaterThan:
        return cmp > 0;
      case HavingOperator.greaterThanOrEqual:
        return cmp >= 0;
    }
  }

  // ── Cross-product densification ───────────────────────────────────────

  /// Sorts cells in-place-equivalent order by their row key,
  /// per-axis using [BucketKeyOrdering.compareNullsLast]. Used by
  /// the `densify: false` path to match the lexicographic ordering
  /// that [_crossProductDensify] produces on the `densify: true`
  /// path, so callers see consistent row ordering regardless of the
  /// flag.
  ///
  /// Returns a new list — does not mutate the input.
  static List<_GroupedCell> _sortCellsByRowKey(List<_GroupedCell> cells) {
    final sorted = [...cells];
    sorted.sort((a, b) {
      for (var i = 0; i < a.rowKey.keys.length; i++) {
        final cmp = BucketKeyOrdering.compareNullsLast(
          a.rowKey.keys[i],
          b.rowKey.keys[i],
        );
        if (cmp != 0) return cmp;
      }
      return 0;
    });
    return sorted;
  }

  /// Cartesian-products the observed per-axis bucket keys (with the
  /// temporal axis, if any, extended via [dateRange]) and fills every
  /// resulting `RowKey` with either the observed `values` list or the
  /// pre-computed [emptyValues] list (one empty-bucket aggregate per
  /// measure, index-aligned to `query.measures`).
  ///
  /// Output ordering: cells are emitted in lexicographic row-key
  /// order — outermost loop is `groupBys[0]`, innermost is the last
  /// group-by. Per-axis ordering uses [BucketKeyOrdering.compareNullsLast]
  /// so categorical keys appear in canonical order and the temporal
  /// axis is chronological.
  ///
  /// For 1 group-by this collapses to single-axis time-densification
  /// (via `densifyTimeBuckets`) when the group-by is temporal, or to
  /// a sorted pass-through of observed keys when the group-by is
  /// categorical.
  ///
  /// For 2 group-bys this produces a cross-product over observed
  /// keys, with the temporal axis (if any) extended via [dateRange].
  ///
  /// For 3 group-bys this produces the documented 3-dimensional
  /// cross-product — large-cardinality footgun, capped at this size
  /// by the validator's three-group-by limit.
  static List<_GroupedCell> _crossProductDensify({
    required List<_GroupedCell> observed,
    required List<GroupBy> groupBys,
    required (DateTime, DateTime)? dateRange,
    required List<TypedValue?> emptyValues,
  }) {
    // Per-axis distinct observed keys.
    final perAxisKeys = <List<BucketKey>>[];
    for (var i = 0; i < groupBys.length; i++) {
      final seen = <BucketKey>{};
      for (final cell in observed) {
        seen.add(cell.rowKey.keys[i]);
      }
      var keys = seen.toList()..sort(BucketKeyOrdering.compareNullsLast);
      // Extend the temporal axis (if any) to cover the date range.
      final g = groupBys[i];
      if (g is TimeGroupBy && dateRange != null) {
        keys = GroupingEngine.densifyTimeBucketKeys(keys, g.grain, dateRange);
      }
      perAxisKeys.add(keys);
    }

    // Map observed (RowKey → values) for O(1) lookup during the
    // cross-product walk. Uses `RowKey`'s value-based equality.
    final observedMap = <RowKey, List<TypedValue?>>{};
    for (final cell in observed) {
      observedMap[cell.rowKey] = cell.values;
    }

    // Walk the cross-product recursively.
    final result = <_GroupedCell>[];
    void recurse(int axis, List<BucketKey> partial) {
      if (axis == groupBys.length) {
        final rk = RowKey(partial);
        // Distinguish "observed and value happens to be null" from
        // "missing combination" by checking key presence rather than
        // value nullness. Synthetic cells share a single immutable
        // reference to the `emptyValues` list — they're never mutated
        // downstream, so sharing is safe and avoids allocating one
        // list per synthetic cell. The `isSynthetic` flag travels with
        // the cell so build helpers can propagate it to the result
        // types' synthetic-tracking fields.
        final observed = observedMap.containsKey(rk);
        result.add(
          _GroupedCell(
            rowKey: rk,
            values: observed ? observedMap[rk]! : emptyValues,
            isSynthetic: !observed,
          ),
        );
        return;
      }
      for (final k in perAxisKeys[axis]) {
        recurse(axis + 1, [...partial, k]);
      }
    }

    recurse(0, []);

    return result;
  }

  // ── Result construction ───────────────────────────────────────────────

  /// Builds a [SeriesResult] from cells with single-element `values`
  /// lists. Used when `(groupBys.length, measures.length) == (1, 1)`.
  ///
  /// [measureLabel] and [measureFieldType] are passed in (precomputed
  /// at the top of `execute()`) rather than recomputed here, since the
  /// same data drives several pipeline steps (HAVING/sort label
  /// resolution, the helper signatures below) and the precomputation
  /// keeps a single source of truth per-execution.
  static SeriesResult _buildSeriesResult(
    List<_GroupedCell> cells,
    GroupBy groupBy,
    SourceDef source, {
    required String measureLabel,
    required FieldType measureFieldType,
  }) {
    final groupInfo = _groupByFieldInfo(groupBy, source);
    return SeriesResult(
      buckets: [
        for (final cell in cells)
          SeriesBucket(
            key: cell.rowKey.singleKey,
            value: cell.values[0],
            isSynthetic: cell.isSynthetic,
          ),
      ],
      groupKind: groupBy is TimeGroupBy
          ? SeriesGroupKind.temporal
          : SeriesGroupKind.categorical,
      groupColumnLabel: groupInfo.label,
      groupColumnFieldType: groupInfo.fieldType,
      measureLabel: measureLabel,
      measureFieldType: measureFieldType,
    );
  }

  /// Builds a [MultiSeriesResult] from cells with single-element
  /// `values` lists. Used when `(groupBys.length, measures.length) == (2, 1)`.
  static MultiSeriesResult _buildMultiSeriesResult(
    List<_GroupedCell> cells,
    List<GroupBy> groupBys,
    SourceDef source, {
    required String measureLabel,
    required FieldType measureFieldType,
  }) {
    final primaryInfo = _groupByFieldInfo(groupBys[0], source);
    final secondaryInfo = _groupByFieldInfo(groupBys[1], source);

    // Walk cells (lexicographic order: primary varies slowest) and
    // collect distinct primary / secondary keys in encounter order.
    // After cross-product densification every (p, s) combination is
    // present, so the cell-encounter order is the canonical order
    // for both axes. On the `densify: false` path some combinations
    // may be absent, but the sort-by-row-key pass produces the same
    // lex order for whichever cells do exist.
    final primaryKeys = <BucketKey>[];
    final secondaryKeys = <BucketKey>[];
    final seenPrimary = <BucketKey>{};
    final seenSecondary = <BucketKey>{};
    for (final cell in cells) {
      final p = cell.rowKey.keys[0];
      final s = cell.rowKey.keys[1];
      if (seenPrimary.add(p)) primaryKeys.add(p);
      if (seenSecondary.add(s)) secondaryKeys.add(s);
    }

    // Lookup table for value and synthetic flag at (primary, secondary).
    final cellMap = <RowKey, TypedValue?>{};
    final syntheticMap = <RowKey, bool>{};
    for (final cell in cells) {
      cellMap[cell.rowKey] = cell.values[0];
      syntheticMap[cell.rowKey] = cell.isSynthetic;
    }

    final namedSeries = <NamedSeries>[
      for (final sKey in secondaryKeys)
        NamedSeries(
          key: sKey,
          values: [
            for (final pKey in primaryKeys) cellMap[RowKey([pKey, sKey])],
          ],
          syntheticValueIndices: {
            for (var i = 0; i < primaryKeys.length; i++)
              if (syntheticMap[RowKey([primaryKeys[i], sKey])] ?? false) i,
          },
        ),
    ];

    return MultiSeriesResult(
      xAxis: [for (final p in primaryKeys) XAxisPosition(key: p)],
      series: namedSeries,
      groupKind: groupBys[0] is TimeGroupBy
          ? SeriesGroupKind.temporal
          : SeriesGroupKind.categorical,
      primaryColumnLabel: primaryInfo.label,
      primaryColumnFieldType: primaryInfo.fieldType,
      secondaryColumnLabel: secondaryInfo.label,
      secondaryColumnFieldType: secondaryInfo.fieldType,
      measureLabel: measureLabel,
      measureFieldType: measureFieldType,
    );
  }

  /// Builds a [MultiMeasureSeriesResult] from cells with N-element
  /// `values` lists. Used when `(groupBys.length, measures.length) == (1, N)`
  /// with N >= 2.
  ///
  /// Each measure becomes one [MeasureSeries]; the single x-axis is
  /// the observed (and densified, if temporal) bucket keys of the
  /// single group-by. Per-measure values are extracted by index from
  /// each cell's `values` list, alongside the precomputed effective
  /// label and output `FieldType` for each measure.
  static MultiMeasureSeriesResult _buildMultiMeasureSeriesResult(
    List<_GroupedCell> cells,
    GroupBy groupBy,
    SourceDef source, {
    required List<String> measureLabels,
    required List<FieldType> measureFieldTypes,
  }) {
    final groupInfo = _groupByFieldInfo(groupBy, source);

    final xAxis = [
      for (final cell in cells) XAxisPosition(key: cell.rowKey.singleKey),
    ];

    // One MeasureSeries per measure. Each carries its own label and
    // output FieldType — no parallel lists on the result type.
    final series = <MeasureSeries>[
      for (var m = 0; m < measureLabels.length; m++)
        MeasureSeries(
          label: measureLabels[m],
          fieldType: measureFieldTypes[m],
          values: [for (final cell in cells) cell.values[m]],
        ),
    ];

    // Synthetic-ness is uniform across measures per x-axis position
    // because the cell is either observed (every measure aggregated
    // real records) or synthesized (every measure's value is filler).
    final syntheticXAxisIndices = {
      for (var i = 0; i < cells.length; i++)
        if (cells[i].isSynthetic) i,
    };

    return MultiMeasureSeriesResult(
      xAxis: xAxis,
      series: series,
      groupKind: groupBy is TimeGroupBy
          ? SeriesGroupKind.temporal
          : SeriesGroupKind.categorical,
      groupColumnLabel: groupInfo.label,
      groupColumnFieldType: groupInfo.fieldType,
      syntheticXAxisIndices: syntheticXAxisIndices,
    );
  }

  /// Builds a [TableResult] from cells with N-element `values` lists.
  ///
  /// Used for all shapes that fall through to a foundational table:
  /// 3-`groupBy` queries (single- or multi-measure), 2-`groupBy`
  /// multi-measure queries (the 4D shape with no chart-shape view), and
  /// 0-`groupBy` multi-measure queries (a single-row wide table —
  /// cells is a length-1 list containing one cell with `RowKey([])`).
  ///
  /// Layout: one group-key column per group-by (zero columns when
  /// `groupBys` is empty), followed by one measure column per measure
  /// (always at least one). Row order matches the cell order.
  static TableResult _buildTableResult(
    List<_GroupedCell> cells,
    List<GroupBy> groupBys,
    SourceDef source, {
    required List<String> measureLabels,
    required List<FieldType> measureFieldTypes,
  }) {
    final groupInfos = [for (final g in groupBys) _groupByFieldInfo(g, source)];

    final columns = <TableColumn>[
      // One group-key column per groupBy, in order. Zero columns when
      // groupBys is empty (0-groupBy multi-measure path).
      for (var i = 0; i < groupBys.length; i++)
        TableColumn(
          label: groupInfos[i].label,
          fieldType: groupInfos[i].fieldType,
          kind: TableColumnKind.groupKey,
          values: [
            for (final cell in cells)
              bucketKeyToTypedValue(
                cell.rowKey.keys[i],
                groupInfos[i].fieldType,
              ),
          ],
        ),
      // One measure column per measure, in order.
      for (var m = 0; m < measureLabels.length; m++)
        TableColumn(
          label: measureLabels[m],
          fieldType: measureFieldTypes[m],
          kind: TableColumnKind.measure,
          values: [for (final cell in cells) cell.values[m]],
        ),
    ];

    return TableResult(
      columns: columns,
      rowKeys: [for (final cell in cells) cell.rowKey],
      syntheticRowIndices: {
        for (var i = 0; i < cells.length; i++)
          if (cells[i].isSynthetic) i,
      },
    );
  }

  /// Resolves a [GroupBy] into the `(label, fieldType)` pair used for
  /// constructing column metadata on the result. The label is
  /// `GroupBy.label` when set, otherwise the underlying field id. The
  /// field type comes from the resolved `FieldDef` on [source].
  static ({String label, FieldType fieldType}) _groupByFieldInfo(
    GroupBy groupBy,
    SourceDef source,
  ) {
    final FieldRef ref = switch (groupBy) {
      FieldGroupBy(fieldRef: final r) => r,
      TimeGroupBy(dateFieldRef: final r) => r,
    };
    final field = source.fieldById(ref.fieldId);
    if (field == null) {
      throw StateError(
        'AnalyticsExecutor._groupByFieldInfo: unknown field '
        '${ref.fieldId} on source ${source.sourceId}; validator should '
        'have rejected this query.',
      );
    }
    return (label: groupBy.effectiveLabel, fieldType: field.fieldType);
  }

  /// Resolves [measure]'s output [FieldType], throwing if the result
  /// is `null` (i.e., the measure is `StreakMeasure`).
  ///
  /// The result-construction helpers are only reached after the streak
  /// short-circuit at the top of `execute()`, so any measure here is
  /// guaranteed not to be streak. The defensive throw catches the
  /// impossible case loudly rather than letting a downstream null
  /// surface as a confusing later failure.
  ///
  /// All output-type knowledge lives on the `Measure` family
  /// ([Measure.outputFieldType]); this wrapper exists only to convert
  /// the nullable result into a non-nullable one at the call sites
  /// where streak is structurally impossible.
  static FieldType _resolveMeasureOutputType(
    Measure measure,
    SourceDef source,
  ) {
    final output = measure.outputFieldType(source);
    if (output == null) {
      throw StateError(
        'AnalyticsExecutor._resolveMeasureOutputType: streak measure '
        'reached a result-construction helper; the streak short-circuit '
        'at the top of execute() should have intercepted.',
      );
    }
    return output;
  }
}

/// Internal: one bucket of aggregated data — the executor's working
/// representation between aggregation and result construction.
///
/// Holds the same `(RowKey, values)` shape regardless of how many
/// group-bys or measures the query has:
/// - The `rowKey` has length 0 (for 0-`groupBy` multi-measure queries),
///   1 (single `groupBy`), 2, or 3 (3-`groupBy` queries).
/// - The `values` list is index-aligned to `AnalyticsQuerySpec.measures`,
///   with one entry per measure (entries are `null` when the
///   corresponding aggregator returned `null` — e.g., average over an
///   empty bucket, or a non-additive aggregation over a synthetic
///   densified cell).
///
/// All measures in a query aggregate over the same bucket in a single
/// pass at construction time, so building this cell is one walk of the
/// bucket's records regardless of measure count.
class _GroupedCell {
  _GroupedCell({
    required this.rowKey,
    required this.values,
    this.isSynthetic = false,
  });

  final RowKey rowKey;
  final List<TypedValue?> values;

  /// `true` when this cell was produced by densification (cross-
  /// product or time-axis extension) rather than by aggregating
  /// observed records. Build helpers propagate this to the result
  /// types' synthetic-tracking fields.
  final bool isSynthetic;
}
