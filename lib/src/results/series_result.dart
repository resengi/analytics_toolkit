part of '../results.dart';

// ── ScalarResult ────────────────────────────────────────────────────────────

/// A single aggregated value with no grouping.
///
/// [value] is `null` when the measure returns undefined over an empty
/// input (e.g. `average` over zero records).
///
/// [measureLabel] is consumer-supplied; the executor leaves it `null`.
class ScalarResult extends AnalyticsResult {
  const ScalarResult({required this.value, this.measureLabel});

  final TypedValue? value;
  final String? measureLabel;
}

// ── SeriesResult ────────────────────────────────────────────────────────────

/// Whether a series' buckets are categorical (e.g. by status, by label)
/// or temporal (e.g. by day, by week, by month).
///
/// Drives downstream rendering decisions without requiring the
/// consumer to inspect the original query.
enum SeriesGroupKind { categorical, temporal }

/// A series of buckets, one per group key.
///
/// `SeriesResult` is a chart-shape view: it materializes the
/// ergonomic representation that line, bar, and area chart renderers
/// most often want — an ordered list of `(BucketKey, TypedValue?)`
/// pairs — and exposes [toTableResult] for consumers that want the
/// generalized foundational shape.
///
/// The view does not retain a `TableResult` reference internally;
/// [toTableResult] reconstructs one on demand. Result types are
/// immutable so this is safe (no read-after-write hazards), and the
/// reconstruction is linear in bucket count.
///
/// ## Projection contract
///
/// `view.toTableResult()` produces a `TableResult` with one
/// group-key column (labeled by [groupColumnLabel], typed by
/// [groupColumnFieldType]) and one measure column (labeled by
/// [measureLabel], typed by [measureFieldType]), one row per bucket.
/// The shape is structurally equivalent to what a single-`groupBy`
/// single-measure query against the same data would have produced
/// as a foundational result.
class SeriesResult extends AnalyticsResult {
  SeriesResult({
    required List<SeriesBucket> buckets,
    required this.groupKind,
    required this.groupColumnLabel,
    required this.groupColumnFieldType,
    required this.measureLabel,
    required this.measureFieldType,
    this.semanticTag,
  }) : buckets = List.unmodifiable(buckets);

  final List<SeriesBucket> buckets;
  final SeriesGroupKind groupKind;

  /// Stable identifier for the group-by dimension this series'
  /// buckets are keyed by — typically the `FieldRef.fieldId` of the
  /// query's group-by field. Used as the column label in
  /// [toTableResult] projections so that table-shape consumers see a
  /// consistent name for the dimension.
  final String groupColumnLabel;

  /// The `FieldType` of the group-by field. Carried explicitly (rather
  /// than inferred from bucket keys) so projection works correctly
  /// for empty series and ambiguous bucket-key shapes — for example,
  /// `IntBucketKey` is used by both integer fields and duration
  /// fields, so the bucket key alone can't disambiguate.
  final FieldType groupColumnFieldType;

  /// Stable identifier for the measure this series carries — the
  /// measure's effective label, either its explicit `Measure.label`
  /// or the auto-generated `'measure_<index>'` (always `'measure_0'`
  /// for `SeriesResult`, which is the single-measure shape). Used as
  /// the column label in [toTableResult] projections.
  final String measureLabel;

  /// The `FieldType` of the measure's output. Determined by
  /// [Measure.outputFieldType] (which in turn delegates to
  /// [FieldAggregation.outputFieldType] for `FieldMeasure`). The
  /// executor sets this at construction.
  final FieldType measureFieldType;

  /// Optional opaque semantic identifier for the series as a whole.
  ///
  /// Consumers (renderers, visualization mappers) can use this as a
  /// stable signal for color or styling decisions that should not
  /// depend on label or bucket-key formatting. The package treats it
  /// as an opaque string — meaning is consumer-defined.
  ///
  /// `null` means "no semantic identity".
  final String? semanticTag;

  bool get isEmpty => buckets.isEmpty;

  /// Projects this series to the foundational `TableResult` shape.
  ///
  /// Returns a fresh `TableResult` with one group-key column holding
  /// the bucket keys' flattened values, one measure column holding
  /// the bucket values, and one `RowKey` per bucket wrapping the
  /// bucket's key as a length-1 tuple. The result is structurally
  /// equivalent to what a single-groupBy single-measure query would
  /// have produced if it had been routed to `TableResult` directly.
  ///
  /// The projection allocates a new table each call — view types
  /// do not retain a `TableResult` reference internally.
  TableResult toTableResult() {
    return TableResult(
      columns: [
        TableColumn(
          label: groupColumnLabel,
          fieldType: groupColumnFieldType,
          kind: TableColumnKind.groupKey,
          values: [
            for (final b in buckets)
              bucketKeyToTypedValue(b.key, groupColumnFieldType),
          ],
        ),
        TableColumn(
          label: measureLabel,
          fieldType: measureFieldType,
          kind: TableColumnKind.measure,
          values: [for (final b in buckets) b.value],
        ),
      ],
      rowKeys: [
        for (final b in buckets) RowKey([b.key]),
      ],
      syntheticRowIndices: {
        for (var i = 0; i < buckets.length; i++)
          if (buckets[i].isSynthetic) i,
      },
    );
  }
}

/// One bucket inside a [SeriesResult].
///
/// [value] is `null` when the measure returns undefined over an empty
/// bucket (e.g. `average` of zero records, including synthetic empty
/// buckets produced by time-bucket densification).
///
/// [isSynthetic] is `true` when this bucket was produced by the
/// executor's densification step (cross-product or time-axis
/// extension) rather than by aggregating observed records. Consumers
/// that need to distinguish "engine-filled" from "real data" can
/// gate on this flag — for example, a CSV exporter might skip
/// synthetic buckets entirely, while a chart renderer might render
/// them with a different visual treatment.
///
/// [displayLabel] is consumer-supplied; the executor leaves it `null`.
/// To attach labels, post-process by mapping over the buckets and
/// constructing replacements with the label filled in. The raw key
/// data ([BucketKey] subtypes' `value` / `instant` / etc.) is
/// available for the consumer's formatting logic.
class SeriesBucket {
  const SeriesBucket({
    required this.key,
    required this.value,
    this.isSynthetic = false,
    this.displayLabel,
  });

  /// Typed bucket key. Equality on this is what consumers use to align
  /// paired-query results.
  final BucketKey key;

  /// The aggregated value for this bucket.
  final TypedValue? value;

  /// Whether this bucket was produced by densification rather than
  /// by aggregating observed records. `false` for buckets that
  /// reflect at least one record from the input; `true` for buckets
  /// inserted by the executor to fill a missing cross-product
  /// combination or to extend a temporal axis to cover the requested
  /// date range. Always `false` when `Executor.execute` is called
  /// with `densify: false`.
  final bool isSynthetic;

  /// Consumer-supplied display label. `null` by default.
  final String? displayLabel;
}

// ── MultiSeriesResult ───────────────────────────────────────────────────────

/// One x-axis position inside a [MultiSeriesResult].
///
/// Pairs a [BucketKey] with an optional consumer-supplied [label].
/// Bundled into a class (rather than parallel `List<BucketKey>` and
/// `List<String?>` on [MultiSeriesResult]) so the two stay in lockstep
/// and consumers can't accidentally desync them.
class XAxisPosition {
  const XAxisPosition({required this.key, this.label});

  /// Typed bucket key for this position. Used for value-based equality
  /// and alignment with [NamedSeries.values].
  final BucketKey key;

  /// Consumer-supplied label. `null` by default; the executor leaves
  /// it unset.
  final String? label;
}

/// One named series inside a [MultiSeriesResult].
///
/// `values` is index-aligned to the parent result's `xAxis`. Missing
/// (primary, secondary) combinations follow the same rule as
/// [SeriesBucket.value]: additive aggregations get a typed zero,
/// non-additive aggregations get `null`.
///
/// [syntheticValueIndices] identifies which positions in [values]
/// were produced by densification rather than by aggregating observed
/// records. A position `i` in this set means `values[i]` is engine-
/// filled; positions not in the set reflect actual data. Always empty
/// when `Executor.execute` is called with `densify: false`.
class NamedSeries {
  NamedSeries({
    required this.key,
    required List<TypedValue?> values,
    Set<int> syntheticValueIndices = const <int>{},
    this.semanticTag,
  }) : values = List.unmodifiable(values),
       syntheticValueIndices = Set.unmodifiable(syntheticValueIndices);

  /// The secondary-groupBy value this series represents.
  final BucketKey key;

  /// Aggregated values aligned to the parent's `xAxis`.
  final List<TypedValue?> values;

  /// Indices into [values] that came from densification. Always a
  /// subset of `[0, values.length)`. Empty for non-densified results.
  final Set<int> syntheticValueIndices;

  /// Optional opaque semantic identifier for this series — same rules
  /// as [SeriesResult.semanticTag].
  final String? semanticTag;
}

/// A multi-series result: one primary x-axis with N named series.
///
/// Produced by the executor when an `AnalyticsQuerySpec` has exactly
/// two group-bys (and a single measure). The wide format —
/// `xAxis × series` — is the ergonomic shape for stacked bar, grouped
/// bar, and multi-line chart renderers, where each `NamedSeries` is
/// one drawn line or stack within the chart.
///
/// Like [SeriesResult], `MultiSeriesResult` is a chart-shape view: it
/// does not retain a `TableResult` reference, and [toTableResult]
/// reconstructs the equivalent foundational table on demand. The
/// projection flattens the wide format to a long row-per-cell
/// representation — one row per `(primary, secondary)` pair — which
/// is what an equivalent two-`groupBy` single-measure query would
/// have produced if it had been routed to `TableResult` directly.
class MultiSeriesResult extends AnalyticsResult {
  MultiSeriesResult({
    required List<XAxisPosition> xAxis,
    required List<NamedSeries> series,
    required this.groupKind,
    required this.primaryColumnLabel,
    required this.primaryColumnFieldType,
    required this.secondaryColumnLabel,
    required this.secondaryColumnFieldType,
    required this.measureLabel,
    required this.measureFieldType,
  }) : xAxis = List.unmodifiable(xAxis),
       series = List.unmodifiable(series);

  /// Primary-groupBy positions, in display order. Length matches every
  /// `NamedSeries.values` length.
  final List<XAxisPosition> xAxis;

  /// One entry per secondary-groupBy value.
  final List<NamedSeries> series;

  /// Whether the primary axis is categorical or temporal — same role
  /// as [SeriesResult.groupKind], drives renderer decisions.
  final SeriesGroupKind groupKind;

  /// Stable identifier for the primary group-by dimension. Typically
  /// the `FieldRef.fieldId` of the query's first `groupBys` entry.
  /// Used as the primary group-key column label in [toTableResult].
  final String primaryColumnLabel;

  /// The `FieldType` of the primary group-by field. Carried explicitly
  /// for the same reason as [SeriesResult.groupColumnFieldType] — to
  /// disambiguate ambiguous bucket-key shapes (e.g., `IntBucketKey` is
  /// used for both integer and duration fields).
  final FieldType primaryColumnFieldType;

  /// Stable identifier for the secondary group-by dimension. Typically
  /// the `FieldRef.fieldId` of the query's second `groupBys` entry.
  /// Used as the secondary group-key column label in [toTableResult].
  final String secondaryColumnLabel;

  /// The `FieldType` of the secondary group-by field.
  final FieldType secondaryColumnFieldType;

  /// Stable identifier for the measure. Used as the measure column
  /// label in [toTableResult].
  final String measureLabel;

  /// The `FieldType` of the measure's output. Determined by
  /// [Measure.outputFieldType] (which in turn delegates to
  /// [FieldAggregation.outputFieldType] for `FieldMeasure`).
  final FieldType measureFieldType;

  bool get isEmpty => series.isEmpty || xAxis.isEmpty;

  /// Projects this multi-series result to the foundational
  /// `TableResult` shape.
  ///
  /// Flattens the wide format (`xAxis × series`) to a long format
  /// with one row per `(primary, secondary)` cell. The result has
  /// three columns — primary group-key, secondary group-key, measure
  /// — and `xAxis.length × series.length` rows.
  ///
  /// Row order: for each primary position in `xAxis`, all secondary
  /// keys are emitted in `series` order. This is the same row order
  /// a two-`groupBy` query produces when sorted lexicographically by
  /// `(primary, secondary)`.
  TableResult toTableResult() {
    final primaryValues = <TypedValue>[];
    final secondaryValues = <TypedValue>[];
    final measureValues = <TypedValue?>[];
    final rowKeys = <RowKey>[];
    final syntheticRowIndices = <int>{};

    var rowIdx = 0;
    for (var i = 0; i < xAxis.length; i++) {
      final pKey = xAxis[i].key;
      for (var j = 0; j < series.length; j++) {
        final sKey = series[j].key;
        primaryValues.add(bucketKeyToTypedValue(pKey, primaryColumnFieldType));
        secondaryValues.add(
          bucketKeyToTypedValue(sKey, secondaryColumnFieldType),
        );
        measureValues.add(series[j].values[i]);
        rowKeys.add(RowKey([pKey, sKey]));
        // A projected row is synthetic iff the source (xAxis[i],
        // series[j]) cell was synthetic — recorded as index `i` in
        // series[j]'s syntheticValueIndices.
        if (series[j].syntheticValueIndices.contains(i)) {
          syntheticRowIndices.add(rowIdx);
        }
        rowIdx++;
      }
    }

    return TableResult(
      columns: [
        TableColumn(
          label: primaryColumnLabel,
          fieldType: primaryColumnFieldType,
          kind: TableColumnKind.groupKey,
          values: primaryValues,
        ),
        TableColumn(
          label: secondaryColumnLabel,
          fieldType: secondaryColumnFieldType,
          kind: TableColumnKind.groupKey,
          values: secondaryValues,
        ),
        TableColumn(
          label: measureLabel,
          fieldType: measureFieldType,
          kind: TableColumnKind.measure,
          values: measureValues,
        ),
      ],
      rowKeys: rowKeys,
      syntheticRowIndices: syntheticRowIndices,
    );
  }
}

// ── MeasureSeries ──────────────────────────────────────────────────────────

/// One measure-series inside a [MultiMeasureSeriesResult].
///
/// `values` is index-aligned to the parent result's `xAxis` —
/// `values[i]` is this measure's aggregated value at the
/// `xAxis[i]` position. Missing combinations follow the standard
/// `SeriesBucket.value` rule: additive aggregations get a typed zero,
/// non-additive aggregations get `null`.
///
/// `MeasureSeries` is a sibling to [NamedSeries], used by
/// [MultiSeriesResult]. Both carry an index-aligned `values` list,
/// but they identify the series differently:
///
/// - [NamedSeries.key] is a [BucketKey] — the secondary-groupBy data
///   value this series represents.
/// - [MeasureSeries.label] is a string — the measure's effective label
///   (explicit `Measure.label` or the stable auto-generated
///   `'measure_<index>'`). [MeasureSeries.fieldType] is the measure's
///   output [FieldType].
///
/// The split is intentional: in `MultiSeriesResult` the series
/// identity is a data dimension (so it shares the `BucketKey`
/// vocabulary used elsewhere for grouping values); in
/// `MultiMeasureSeriesResult` the series identity is a query-language
/// label and carries its own output type. Pattern-matching on the
/// result type already distinguishes these cases for consumers, so
/// the per-series type difference reinforces what's there rather than
/// adding cognitive load.
class MeasureSeries {
  MeasureSeries({
    required this.label,
    required this.fieldType,
    required List<TypedValue?> values,
    this.semanticTag,
  }) : values = List.unmodifiable(values);

  /// The measure's effective label — explicit `Measure.label`, or the
  /// stable auto-generated `'measure_<index>'` if `Measure.label` was
  /// null. Round-trips through [WidgetPayloadCodec].
  final String label;

  /// The measure's output [FieldType], per [Measure.outputFieldType].
  /// Different measures in the same query may have different output
  /// types (e.g., a count alongside a duration sum), so each series
  /// carries its own.
  final FieldType fieldType;

  /// Aggregated values, index-aligned to the parent's `xAxis`.
  final List<TypedValue?> values;

  /// Optional opaque semantic identifier for this series — same rules
  /// as [SeriesResult.semanticTag]. Consumer-supplied; the executor
  /// leaves this `null`.
  final String? semanticTag;
}

// ── MultiMeasureSeriesResult ────────────────────────────────────────────────

/// A single-axis chart with multiple measures plotted against it.
///
/// Produced by the executor when an `AnalyticsQuerySpec` has exactly
/// one group-by and two or more measures. The shape — one x-axis,
/// one series per measure — is the natural form for grouped bar,
/// stacked area, and small-multiple line charts where each measure
/// produces its own visual band.
///
/// Like the other chart-shape views, `MultiMeasureSeriesResult` does
/// not retain a `TableResult` reference internally — [toTableResult]
/// reconstructs the equivalent foundational table on demand. The
/// projection produces a wide table: one row per x-axis position,
/// one group-key column plus N measure columns (one per measure).
/// Row count equals `xAxis.length`. This matches the shape an
/// equivalent 1-`groupBy` × N-measure query would have produced if
/// it had been routed directly to `TableResult`.
///
/// Each entry in [series] is a [MeasureSeries] — a per-measure object
/// carrying the measure's effective label, output [FieldType], and
/// the index-aligned value list. Compare with [MultiSeriesResult]
/// which uses [NamedSeries] (keyed by `BucketKey` since the series
/// identity there is a secondary-groupBy data value).
class MultiMeasureSeriesResult extends AnalyticsResult {
  MultiMeasureSeriesResult({
    required List<XAxisPosition> xAxis,
    required List<MeasureSeries> series,
    required this.groupKind,
    required this.groupColumnLabel,
    required this.groupColumnFieldType,
    Set<int> syntheticXAxisIndices = const <int>{},
  }) : xAxis = List.unmodifiable(xAxis),
       series = List.unmodifiable(series),
       syntheticXAxisIndices = Set.unmodifiable(syntheticXAxisIndices);

  /// Group-by positions, in display order. Length matches every
  /// `MeasureSeries.values` length.
  final List<XAxisPosition> xAxis;

  /// One entry per measure, in `AnalyticsQuerySpec.measures` order.
  /// Each entry carries the measure's label, output `FieldType`, and
  /// per-position values.
  final List<MeasureSeries> series;

  /// Whether the x-axis is categorical or temporal — same role as
  /// [SeriesResult.groupKind], drives renderer decisions.
  final SeriesGroupKind groupKind;

  /// Stable identifier for the group-by dimension — typically the
  /// `FieldRef.fieldId` of the query's single `groupBys` entry. Used
  /// as the group-key column label in [toTableResult].
  final String groupColumnLabel;

  /// The `FieldType` of the group-by field.
  final FieldType groupColumnFieldType;

  /// Indices into [xAxis] whose values across every [series] were
  /// produced by densification rather than by aggregating observed
  /// records.
  ///
  /// Synthetic-ness is uniform across measures for a given x-axis
  /// position: a missing combination in the cross-product means
  /// every measure's aggregator was called on the empty record set,
  /// so every measure's value at that position is filler. That's why
  /// this set is on the result rather than per-[MeasureSeries].
  ///
  /// Always empty when `Executor.execute` is called with
  /// `densify: false`.
  final Set<int> syntheticXAxisIndices;

  bool get isEmpty => series.isEmpty || xAxis.isEmpty;

  /// Projects this multi-measure series to the foundational
  /// `TableResult` shape.
  ///
  /// The projection produces a table with one group-key column
  /// (labeled by [groupColumnLabel]) and N measure columns (one per
  /// measure, labeled by the corresponding [MeasureSeries.label]).
  /// Each x-axis position becomes one row; the row's cells are the
  /// measure values for that position. Synthetic x-axis positions
  /// project to synthetic table rows: `syntheticXAxisIndices` is
  /// passed through directly as `TableResult.syntheticRowIndices`.
  ///
  /// Row order matches [xAxis] order — no unflattening, since the
  /// measures-as-columns layout is wide and stays wide in the
  /// projected table.
  TableResult toTableResult() {
    return TableResult(
      columns: [
        TableColumn(
          label: groupColumnLabel,
          fieldType: groupColumnFieldType,
          kind: TableColumnKind.groupKey,
          values: [
            for (final p in xAxis)
              bucketKeyToTypedValue(p.key, groupColumnFieldType),
          ],
        ),
        for (final m in series)
          TableColumn(
            label: m.label,
            fieldType: m.fieldType,
            kind: TableColumnKind.measure,
            values: m.values,
          ),
      ],
      rowKeys: [
        for (final p in xAxis) RowKey([p.key]),
      ],
      syntheticRowIndices: syntheticXAxisIndices,
    );
  }
}
