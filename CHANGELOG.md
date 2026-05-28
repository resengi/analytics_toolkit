# Change Log



## 2026-05-28

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`analytics_toolkit` - `v0.1.1`](#analytics_toolkit---v011)

---

#### `analytics_toolkit` - `v0.1.1`

 - **FEAT**: Publishing initial version of analytics package ([#1](https://github.com/resengi/analytics_toolkit/issues/1)). ([c3f53193](https://github.com/resengi/analytics_toolkit/commit/c3f53193367a657e9eb42e2f7bad92f9d15cb790))

## 0.1.1

 - **FEAT**: Publishing initial version of analytics package ([#1](https://github.com/resengi/analytics_toolkit/issues/1)). ([c3f53193](https://github.com/resengi/analytics_toolkit/commit/c3f53193367a657e9eb42e2f7bad92f9d15cb790))

# Changelog

## 0.1.0

Initial release.

`analytics_toolkit` is a pure-Dart in-memory query engine for dashboard-style analytics over normalized record collections. Hosts declare data sources, build typed queries with measures and group-bys, and read back typed results — no chart library, no UI toolkit, no Flutter dependency. The host streams `SourceRecord`s in; the executor returns `AnalyticsResult` out.

This release establishes the foundational API surface:

- **Schema and values** — `SourceDef` and `FieldDef` for declaring sources, with a sealed `TypedValue` family (`StringValue`, `IntValue`, `DoubleValue`, `BoolValue`, `EnumValue`, `DateTimeValue`, `DurationValue`, list variants, `NullValue`) and a single canonical ordering via `TypedValueOrdering`.
- **Queries** — up to five measures per query from a sealed measure family (`CountMeasure`, `FieldMeasure` with a sealed `FieldAggregation` family — `SumAgg`, `AverageAgg`, `MinAgg`, `MaxAgg`, `DistinctCountAgg`, `PercentileAgg` — and `StreakMeasure`); up to three group-bys from a sealed group-by family (`FieldGroupBy`, `TimeGroupBy`); AND-combined record-level filters; bucket-level filtering via `HavingClause`; sorts with SQL-style null ordering; and derived operations (`CumulativeSumOp`, `DeltaOp`, `MovingAverageOp`) applied after aggregation.
- **Results** — sealed result family (`ScalarResult`, `SeriesResult`, `MultiSeriesResult`, `MultiMeasureSeriesResult`, `TableResult`) with a unified `BucketKey` family and `BucketKeyOrdering` as the single source of truth for ordering.
- **Validation** — `QueryValidator` returns `Result<Unit, AnalyticsError>` with a closed `AnalyticsErrorKind` enum. The executor never throws for validation failures.
- **Execution** — `AnalyticsExecutor.execute` is a pure function: `(query, records, sources) -> Result<AnalyticsResult, AnalyticsError>`. Deterministic, no wall-clock reads, no hidden state.
- **Time series** — calendar-aligned date-range presets via `DatePresetResolver`, configurable week-start and quarter-start, half-open `[start, end)` ranges, date-range projection via `DateRangeProjector`, and time-bucket densification so charts render without gaps.
- **Paired queries** — `PairedQuerySpec` for cohort comparison and rate displays, with alignability validation across sources.
- **Persistence** — `AnalyticsWidgetSpec` plus `WidgetPayloadCodec` round-trip user-built widget specs to JSON with a schema-version guard for forward compatibility.
- **Caching and change events** — `SourceSnapshotCache` for records-layer caching (in-flight dedup, scoped invalidation, discard-on-completion for stale fetches) and `AnalyticsChange` / `AnalyticsChangeKind` for typed listener invalidation.
- **Zero external dependencies** — only `dart:core` and `dart:convert`.nd `AnalyticsChange` / `AnalyticsChangeKind` for typed listener invalidation.
- **Zero external dependencies** — only `dart:core` and `dart:convert`.