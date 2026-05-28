part of '../results.dart';

// ── AnalyticsResult (sealed family base) ────────────────────────────────────

/// The result of a successful query execution.
///
/// Sealed family with five cases — [ScalarResult], [SeriesResult],
/// [MultiSeriesResult], [MultiMeasureSeriesResult], and [TableResult].
/// Time-vs-categorical for a series is encoded in
/// [SeriesResult.groupKind] (or [MultiSeriesResult.groupKind]), not as
/// a separate result type.
///
/// ## Typed aggregation values
///
/// Aggregated values throughout the result family are `TypedValue?`,
/// not `double`:
///
/// * The aggregation engine produces a specific `TypedValue` subtype
///   per (measure × field-type) combination — see
///   [Measure.outputFieldType] and [FieldAggregation.outputFieldType]
///   for the full table.
/// * `null` represents an undefined aggregation over an empty group
///   (e.g. `average`, `min`, `max` of zero records). Additive
///   aggregations like `count` and `sum` return the additive identity
///   (`IntValue(0)` etc.) instead.
/// * Synthetic empty buckets produced by time-bucket densification
///   follow the same rule: additive aggregations get a typed zero;
///   non-additive aggregations get `null`.
///
/// ## Display labels
///
/// Every result type carries optional `String?` labels (e.g.
/// [ScalarResult.measureLabel], [SeriesBucket.displayLabel],
/// [XAxisPosition.label]). The executor leaves these `null` — they're
/// consumer-supplied, set by the host application or a presentation
/// layer that knows what locale and format the user expects. To
/// attach labels, post-process the result and rebuild the bucket /
/// position with the label filled in.
sealed class AnalyticsResult {
  const AnalyticsResult();
}

// ── TableResult (foundational column-oriented shape) ────────────────────────

/// The kind of a [TableColumn] — distinguishes columns that carry
/// grouping dimensions from columns that carry aggregated measure
/// values.
///
/// Consumers reading a [TableResult] can use this to filter "just the
/// group-key columns" or "just the measure columns" without inspecting
/// the original query. Both kinds otherwise share the same shape
/// (label, FieldType, ordered value list).
enum TableColumnKind {
  /// A grouping dimension. There is one such column per `GroupBy`
  /// clause in the query, in `groupBys` order. The values are the
  /// bucket keys flattened into the column.
  groupKey,

  /// An aggregated measure value. There is one such column per
  /// `Measure` in the query, in `measures` order. The values are the
  /// per-bucket aggregation results.
  measure,
}

/// One column of a [TableResult].
///
/// Each column carries a label, a `FieldType`, a column-kind
/// discriminator, and an ordered list of values aligned to the parent
/// table's row keys. Both group-key and measure columns share this
/// shape — the discriminator [kind] is what distinguishes them.
class TableColumn {
  TableColumn({
    required this.label,
    required this.fieldType,
    required this.kind,
    required List<TypedValue?> values,
  }) : values = List.unmodifiable(values);

  /// Stable, addressable label for this column. For group-key columns,
  /// this is `GroupBy.label` when set on the source group-by, otherwise
  /// the `FieldRef.fieldId` of the underlying group-by field. For
  /// measure columns, this is the `Measure.label` (or the stable
  /// auto-generated label when no explicit label is set).
  ///
  /// Labels are guaranteed unique within a single `TableResult`. The
  /// validator rejects queries whose effective column labels (group-by
  /// labels-or-field-ids plus measure labels) collide; resolve a
  /// collision by setting an explicit `label` on the conflicting
  /// `GroupBy` or `Measure`.
  final String label;

  /// The `FieldType` of the values in this column. Carried explicitly
  /// (rather than inferred from the values) so consumers can determine
  /// column type even for empty or all-null columns.
  final FieldType fieldType;

  /// Whether this is a grouping-dimension column or a measure-value
  /// column.
  final TableColumnKind kind;

  /// Ordered values, aligned to the parent table's `rowKeys`. Length
  /// matches the parent's row count. `null` entries represent
  /// undefined values — typically from non-additive aggregations over
  /// empty / all-null groups, including synthetic densified buckets.
  final List<TypedValue?> values;
}

/// A row identifier in a [TableResult], holding the tuple of
/// `BucketKey`s that defines the row's coordinates across the table's
/// grouping dimensions.
///
/// Always a tuple — length 1 for single-`groupBy` queries, length N
/// for N-level queries. Always-tuples (rather than a sealed
/// flat-vs-tuple family) keeps consumers from having to pattern-match
/// on cardinality for the common length-1 case.
///
/// Row keys carry value-based equality and hashing so they are usable
/// as `Map` keys during partitioning and lookup. The element-wise
/// comparison delegates to each `BucketKey`'s `==` / `hashCode`.
class RowKey {
  RowKey(List<BucketKey> keys) : keys = List.unmodifiable(keys);

  /// The tuple of bucket keys, in `groupBys` order.
  final List<BucketKey> keys;

  /// Convenience accessor for length-1 row keys. Throws `StateError`
  /// if called on a multi-level row key; use `keys[i]` for those.
  BucketKey get singleKey {
    if (keys.length != 1) {
      throw StateError(
        'RowKey.singleKey: row key has ${keys.length} elements; use '
        'keys[i] for multi-level row keys.',
      );
    }
    return keys.first;
  }

  @override
  bool operator ==(Object other) =>
      other is RowKey && listEqualsByValue(other.keys, keys);

  @override
  int get hashCode => listHashByValue(keys);
}

/// A column-oriented tabular result — the foundational result shape
/// for queries that don't fit the chart-shape view types.
///
/// `TableResult` is produced for:
/// - Three-`groupBy` queries (any measure count).
/// - Multi-measure queries with zero, two, or three `groupBys`.
/// - `StreakMeasure` queries (one row per entity, with one group-key
///   column for the entity ID and three measure columns: entity label,
///   current streak, longest streak).
///
/// Chart-shape queries (one `groupBy` with one measure, two
/// `groupBys` with one measure, one `groupBy` with multiple measures)
/// produce a view type ([SeriesResult], [MultiSeriesResult],
/// `MultiMeasureSeriesResult`) instead, each of which can project
/// back to a structurally equivalent `TableResult` via a
/// `toTableResult()` method. The projection only goes view → table;
/// a `TableResult` cannot be projected to a specific view without
/// external policy.
///
/// ## Reading a `TableResult`
///
/// Consumers read the table by column or by row, as suits them:
///
/// - **By column**: pick a column from [columns] and walk
///   `column.values`. Column-kind filtering ([groupKeyColumns] /
///   [measureColumns] / [columnByLabel]) is available.
/// - **By row**: for an index `i`, the row's coordinates are
///   `rowKeys[i].keys` and the cell values are `columns[c].values[i]`
///   for each column `c`.
///
/// Group-key columns hold the bucket keys' flattened representation
/// (one row per `(groupBys-tuple)` combination), so a `RowKey` and
/// the corresponding group-key column entries carry redundant
/// information — the redundancy is intentional and makes row-wise
/// reading ergonomic. The same denormalization Pandas applies when
/// calling `.reset_index()` on a grouped DataFrame.
class TableResult extends AnalyticsResult {
  TableResult({
    required List<TableColumn> columns,
    required List<RowKey> rowKeys,
    this.truncatedCount = 0,
    Set<int> syntheticRowIndices = const <int>{},
  }) : columns = List.unmodifiable(columns),
       rowKeys = List.unmodifiable(rowKeys),
       syntheticRowIndices = Set.unmodifiable(syntheticRowIndices) {
    final rowCount = this.rowKeys.length;
    for (final column in this.columns) {
      if (column.values.length != rowCount) {
        throw ArgumentError.value(
          column.values.length,
          'columns',
          'Each column must have exactly rowKeys.length values; '
              'column "${column.label}" has ${column.values.length} '
              '(expected $rowCount).',
        );
      }
    }
    for (final index in this.syntheticRowIndices) {
      if (index < 0 || index >= rowCount) {
        throw ArgumentError.value(
          index,
          'syntheticRowIndices',
          'Each entry must reference a valid row index in '
              '[0, $rowCount).',
        );
      }
    }
  }

  /// All columns of the table, in display order. Group-key columns
  /// come first (in `groupBys` order), then measure columns (in
  /// `measures` order).
  final List<TableColumn> columns;

  /// One row identifier per row in the table, ordered to match every
  /// `column.values` list.
  final List<RowKey> rowKeys;

  /// Rows that existed in the underlying computation but were dropped
  /// before being returned (e.g. by `StreakMeasure.topN`, or by a
  /// query-level `limit`).
  ///
  /// `0` means "the rows you see are all the rows there were."
  /// Positive means the result is a slice and a renderer can surface
  /// that with a footer like "+N more". The renderer is responsible
  /// for presenting this — no synthetic "…and X more" row is injected
  /// into [rowKeys] or [columns].
  final int truncatedCount;

  /// Indices into [rowKeys] whose rows were produced by densification
  /// rather than by aggregating observed records.
  ///
  /// A row index `i` in this set means the row at position `i`
  /// (across every column) was inserted by the executor to fill a
  /// missing cross-product combination or a missing temporal bucket.
  /// Indices not in the set reflect at least one observed record.
  ///
  /// Streak results have an empty set — `StreakMeasure` doesn't use
  /// the densification pipeline. Tables produced by callers passing
  /// `densify: false` to `Executor.execute` also have an empty set.
  ///
  /// Consumers that need observed-only data can filter:
  /// ```dart
  /// final keptIndices = [
  ///   for (var i = 0; i < result.rowCount; i++)
  ///     if (!result.syntheticRowIndices.contains(i)) i,
  /// ];
  /// ```
  final Set<int> syntheticRowIndices;

  /// Number of rows in this table. Equal to `rowKeys.length` and to
  /// every `column.values.length`.
  int get rowCount => rowKeys.length;

  bool get isEmpty => rowKeys.isEmpty;

  /// All columns whose [TableColumn.kind] is [TableColumnKind.groupKey],
  /// preserving display order.
  List<TableColumn> get groupKeyColumns => [
    for (final c in columns)
      if (c.kind == TableColumnKind.groupKey) c,
  ];

  /// All columns whose [TableColumn.kind] is [TableColumnKind.measure],
  /// preserving display order.
  List<TableColumn> get measureColumns => [
    for (final c in columns)
      if (c.kind == TableColumnKind.measure) c,
  ];

  /// Looks up a column by its [TableColumn.label]. Returns `null` if
  /// no column has that label. Labels are unique within a table, so
  /// this returns at most one match.
  TableColumn? columnByLabel(String label) {
    for (final c in columns) {
      if (c.label == label) return c;
    }
    return null;
  }
}

// ── ResultShape (for inferResultShape) ──────────────────────────────────────

/// The shape a query payload would produce, computed without executing.
///
/// A builder UI can call `InferResultShape.ofPayload` and use the
/// result to populate the list of compatible display types before the
/// query is run.
enum ResultShape {
  /// A single aggregated value — no grouping, one measure.
  scalar,

  /// A flat series of (key, value) buckets — one group-by, one measure.
  /// Produced as a `SeriesResult` (chart-shape view) by the executor.
  series,

  /// A multi-series chart — two group-bys, one measure. Produced as a
  /// `MultiSeriesResult` (chart-shape view) by the executor.
  multiSeries,

  /// A multi-measure single-axis chart — one group-by, two or more
  /// measures. Produced as a `MultiMeasureSeriesResult` (chart-shape
  /// view) by the executor.
  multiMeasureSeries,

  /// A foundational column-oriented table — 3+ group-bys, OR
  /// multi-measure with 0/2/3 group-bys, OR `StreakMeasure`.
  /// Produced as a `TableResult` by the executor.
  table,

  /// A pair of independently-computed series, aligned by `BucketKey`
  /// equality client-side. Produced from a `PairedQuerySpec`.
  pairedSeries,
}
