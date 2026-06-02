/// A typed in-memory query engine for dashboard-style analytics over
/// normalized record collections.
///
/// Define data sources, build typed queries with measures and
/// group-bys, get typed results — no chart-library coupling, no
/// host-app assumptions. The host streams `SourceRecord`s in; the
/// executor returns `AnalyticsResult` out.
///
/// `analytics_toolkit` lets a host application:
///
/// * Declare data sources via `SourceDef` and field metadata via `FieldDef`.
/// * Build queries with filters, group-bys, measures, sorts, and derived
///   operations.
/// * Run those queries against any data source the host can normalize into
///   `SourceRecord` form.
/// * Persist user-defined dashboard widgets (`AnalyticsWidgetSpec`) and
///   round-trip them through `WidgetPayloadCodec`.
/// * Cache normalized source records per page via `SourceSnapshotCache`.
/// * Emit typed change events via `AnalyticsChange`.
///
/// The package is rendering-agnostic — none of its types depend on a chart
/// library or UI toolkit. Consumers supply their own renderer over
/// `AnalyticsResult`.
///
/// ## What's exported
///
/// **General analytics** — usable independently of time-series:
///
/// * **Schema:** `FieldType`, `FieldRef`, `FieldDef`, `SourceDef`, the
///   sealed `TypedValue` family, `TypedValueOrdering`
/// * **Query:** `FilterOperator`, `HavingOperator`, `SortDirection`,
///   the sealed `FieldAggregation` family (`SumAgg`, `AverageAgg`,
///   `MinAgg`, `MaxAgg`, `DistinctCountAgg`, `PercentileAgg`), the
///   sealed `Measure` and `GroupBy` families, `Filter`, `HavingClause`,
///   `Sort`, `DerivedOperation`, `AnalyticsQuerySpec`, `QueryPayload`
///   (`SingleQuerySpec` / `PairedQuerySpec`)
/// * **Series operations:** the sealed `ScalarOp` family (`NegateOp` /
///   `AbsOp` / `FillNullOp`) and `SeriesCombination` family
///   (`SumCombination` / `DifferenceCombination` / `ProductCombination`
///   / `RatioCombination`); the `Measure` expression nodes
///   `TransformedMeasure` and `CalculatedMeasure`; `UnmatchedBucketPolicy`;
///   and `SeriesAlgebra` (with the `SeriesAlgebraX` extension) for
///   applying these to a `SeriesResult` already in hand
/// * **Results:** `AnalyticsResult` (`ScalarResult` / `SeriesResult` /
///   `MultiSeriesResult` / `MultiMeasureSeriesResult` / `TableResult`),
///   `BucketKey` family (including
///   `IntBucketKey` / `DoubleBucketKey` / `TimeBucketKey`),
///   `BucketKeyOrdering`, `RowKey`, `TableColumn`, `TableColumnKind`,
///   `bucketKeyToTypedValue`, `XAxisPosition`, `NamedSeries`,
///   `MeasureSeries`,
///   `ResultShape` (`scalar` / `series` / `multiSeries` /
///   `multiMeasureSeries` / `table` / `pairedSeries`), `InferResultShape`
/// * **Errors:** `AnalyticsError`, `AnalyticsErrorKind`, `Result<T,E>`,
///   `Unit`
/// * **Display:** `DisplaySpec` (consumer-defined display-type hint)
/// * **Validation:** `QueryValidator`
/// * **Execution:** `SourceRecord`, `AnalyticsExecutor`
/// * **Persistence:** `AnalyticsWidgetSpec`, `WidgetPayloadCodec`
/// * **Caching:** `SourceSnapshotCache`
/// * **Change events:** `AnalyticsChange`, `AnalyticsChangeKind`
///
/// **Time-series support** — first-class but optional. Apps doing only
/// categorical analytics can ignore everything in this section:
///
/// * **Date ranges:** `DateRangeMode` (`UsePageRange` / `FixedOverride` /
///   `NoDateRange`), `WidgetDateRange` (`PresetRange` / `CustomRange`),
///   `DateRangePreset`, `DatePresetResolver`
/// * **Date-range projection:** `DateRangeProjector`
/// * **Time bucketing:** `TimeGrain`, `TimeUnit`, `TimeGrainArithmetic`
///   (extension), `TimeBucketKey` (in `BucketKey` family), `TimeGroupBy`
///   (in `GroupBy` family)
/// * **Streaks:** `StreakMeasure` (in `Measure` family) — produces a
///   `TableResult` of streak rows
///
/// See the [README](https://github.com/resengi/analytics_toolkit) for
/// full documentation and examples.
library;

// General analytics — independent of time-series.
export 'src/changes.dart';
export 'src/display_spec.dart';
export 'src/errors.dart';
export 'src/execution/executor.dart';
export 'src/execution/series_algebra.dart';
export 'src/execution/source_record.dart';
export 'src/infer_result_shape.dart';
export 'src/query/measure.dart';
export 'src/query/query_components.dart';
export 'src/query/query_enums.dart';
export 'src/query/query_spec.dart';
export 'src/results.dart';
export 'src/schema/schema.dart';
export 'src/schema/typed_value.dart';
export 'src/source_snapshot_cache.dart';
// Time-series support — first-class but skippable.
export 'src/time_series/date_range.dart';
export 'src/time_series/date_range_projector.dart';
export 'src/time_series/grain_arithmetic.dart';
export 'src/time_series/time_grain.dart';
export 'src/validator.dart';
export 'src/widget_payload_codec.dart';
export 'src/widget_spec.dart';
