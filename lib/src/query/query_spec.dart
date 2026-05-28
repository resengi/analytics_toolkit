import '../equality.dart';
import 'measure.dart';
import 'query_components.dart';

/// The single-query unit consumed by the executor.
///
/// The executor accepts one of these per call:
///
///     execute(query: AnalyticsQuerySpec, records: Iterable<SourceRecord>)
///       -> Result<AnalyticsResult, AnalyticsError>
///
/// Notes:
/// - [filters] is AND-combined; OR is not supported.
/// - [measures] is the ordered list of aggregations. Length 1 with 0
///   group-bys → `ScalarResult`; length 1 with 1 group-by →
///   `SeriesResult`; length N>1 with 1 group-by →
///   `MultiMeasureSeriesResult`; everything else → `TableResult` (or
///   `MultiSeriesResult` for the 2-groupBy/1-measure case). The
///   validator caps the list at 5 entries and enforces that effective
///   labels (explicit or auto-generated) are unique.
/// - [groupBys] is the ordered list of grouping dimensions. Length
///   determines the executor's result shape. The validator caps the
///   list at 3.
/// - [derivedOperation] is always present; default is `NoDerivedOp()`.
///   Only valid for `SeriesResult`-shaped queries (single group-by,
///   single numeric-output measure).
/// - [limit] is optional and applies after sorting. Must be
///   non-negative; the validator rejects negative values.
class AnalyticsQuerySpec {
  AnalyticsQuerySpec({
    required this.source,
    required List<Measure> measures,
    List<Filter> filters = const [],
    List<GroupBy> groupBys = const [],
    this.having,
    this.sort,
    this.limit,
    this.derivedOperation = const NoDerivedOp(),
  }) : measures = List.unmodifiable(measures),
       filters = List.unmodifiable(filters),
       groupBys = List.unmodifiable(groupBys);

  /// The source id this query runs against.
  final String source;

  /// Ordered measures, each evaluated independently per bucket. A
  /// query must have at least one and at most five measures; the
  /// validator enforces both bounds. Each measure's effective label
  /// (`measure.label` if non-null, otherwise the auto-generated
  /// `'measure_<index>'`) must be unique within the query.
  ///
  /// A query containing a `StreakMeasure` must contain exactly one
  /// measure (the streak), and no group-bys. The validator enforces
  /// this with the `streakNotCombinable` error kind.
  final List<Measure> measures;

  final List<Filter> filters;

  /// Ordered grouping dimensions. Length determines the executor's
  /// result shape (see class doc). The validator enforces a maximum
  /// length of 3 and that no two entries are equivalent (e.g., two
  /// `FieldGroupBy` clauses on the same field).
  final List<GroupBy> groupBys;

  /// Optional post-aggregation filter on bucket measure values. See
  /// [HavingClause] for the contract. Rejected by the validator on
  /// scalar queries (those whose [groupBys] is empty).
  final HavingClause? having;

  final Sort? sort;

  /// Optional cap on the number of rows returned, applied after
  /// sorting. `null` means no cap. Must be non-negative when set; the
  /// validator rejects negative values as `preconditionViolation`.
  ///
  /// Follows SQL `LIMIT` semantics: the top N rows from the sorted,
  /// grouped result are kept, where each row is one cell in the
  /// group-by cross-product. Applies uniformly to all result shapes.
  ///
  /// For wide-format results (`MultiSeriesResult`, produced by
  /// two-`groupBy` single-measure queries), the pivoted rendering
  /// may show null entries at positions whose underlying cells were
  /// truncated. That is a consequence of pivoting a partial
  /// cross-product into a wide layout, not missing source data.
  ///
  /// "Top N per group" semantics (e.g. "top 5 regions per date") are
  /// not expressible through [limit]. The supported workarounds:
  /// run a smaller query to identify the keys of interest and
  /// re-query the source with an `inList` filter, or post-process the
  /// full result.
  final int? limit;
  final DerivedOperation derivedOperation;

  /// Returns a copy with extra filters appended. The original spec is
  /// not mutated; always returns a new instance even when [extra] is
  /// empty.
  AnalyticsQuerySpec withAdditionalFilters(List<Filter> extra) {
    return AnalyticsQuerySpec(
      source: source,
      measures: measures,
      filters: [...filters, ...extra],
      groupBys: groupBys,
      having: having,
      sort: sort,
      limit: limit,
      derivedOperation: derivedOperation,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AnalyticsQuerySpec &&
      other.source == source &&
      listEqualsByValue(other.measures, measures) &&
      listEqualsByValue(other.filters, filters) &&
      listEqualsByValue(other.groupBys, groupBys) &&
      other.having == having &&
      other.sort == sort &&
      other.limit == limit &&
      other.derivedOperation == derivedOperation;

  @override
  int get hashCode => Object.hash(
    source,
    listHashByValue(measures),
    listHashByValue(filters),
    listHashByValue(groupBys),
    having,
    sort,
    limit,
    derivedOperation,
  );
}

/// The persisted widget query payload.
///
/// Sealed shape with two cases — uses an explicit `kind` discriminator
/// in JSON to avoid shape-sniffing on load.
///
/// `AnalyticsWidgetSpec.query` always stores a `QueryPayload`, never a
/// raw `AnalyticsQuerySpec`.
sealed class QueryPayload {
  const QueryPayload();
}

class SingleQuerySpec extends QueryPayload {
  const SingleQuerySpec({required this.query});
  final AnalyticsQuerySpec query;

  @override
  bool operator ==(Object other) =>
      other is SingleQuerySpec && other.query == query;

  @override
  int get hashCode => query.hashCode;
}

/// A pair of queries whose results are aligned by the consumer (for
/// scatter or rate displays).
///
/// Alignability constraint: both halves must be alignable. Two queries
/// are alignable if either they share the same source, or both sides
/// use a `TimeGroupBy` with the same `TimeGrain` and both sources have
/// a non-null [SourceDef.primaryDateFieldId].
class PairedQuerySpec extends QueryPayload {
  const PairedQuerySpec({required this.xQuery, required this.yQuery});

  /// The "X" query — for rate displays this is the numerator.
  final AnalyticsQuerySpec xQuery;

  /// The "Y" query — for rate displays this is the denominator.
  final AnalyticsQuerySpec yQuery;

  @override
  bool operator ==(Object other) =>
      other is PairedQuerySpec &&
      other.xQuery == xQuery &&
      other.yQuery == yQuery;

  @override
  int get hashCode => Object.hash(xQuery, yQuery);
}
