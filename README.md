# analytics_toolkit

A pure-Dart in-memory query engine for dashboard-style analytics over normalized record collections.

[![pub package](https://img.shields.io/pub/v/analytics_toolkit.svg)](https://pub.dev/packages/analytics_toolkit)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Publisher](https://img.shields.io/pub/publisher/analytics_toolkit.svg)](https://pub.dev/publishers/resengi.io)

Declare data sources, build typed queries with measures and group-bys, get typed results — no chart library, no UI toolkit, no Flutter dependency. The host streams `SourceRecord`s in; the executor returns `AnalyticsResult` out.

## Features

- **Typed schema and values** — declarative `SourceDef` / `FieldDef` with a sealed `TypedValue` family (`StringValue`, `IntValue`, `DoubleValue`, `BoolValue`, `EnumValue`, `DateTimeValue`, `DurationValue`, list variants, `NullValue`) and a single canonical ordering via `TypedValueOrdering`
- **Sealed measure family** — three leaf cases — `CountMeasure`, `FieldMeasure` (with a sealed `FieldAggregation` family: `SumAgg`, `AverageAgg`, `MinAgg`, `MaxAgg`, `DistinctCountAgg`, `PercentileAgg`), and `StreakMeasure` for habit-tracking-style consecutive-completion analysis — plus two expression cases, `TransformedMeasure` and `CalculatedMeasure`, that compose other measures into an arithmetic tree the engine treats as a single measure. A query may carry up to five measures, each with an optional `label`.
- **Sealed group-by family** — `FieldGroupBy` for categorical pivoting and `TimeGroupBy` for temporal bucketing at any grain, with up to three group-by clauses per query and an optional `label` on each for column aliasing
- **Sealed result family** — `ScalarResult`, `SeriesResult`, `MultiSeriesResult`, `MultiMeasureSeriesResult`, and `TableResult` with a unified `BucketKey` family (`StringBucketKey`, `EnumBucketKey`, `BoolBucketKey`, `IntBucketKey`, `DoubleBucketKey`, `TimeBucketKey`, `NullBucketKey`) and `BucketKeyOrdering` as the single source of truth for ordering
- **Bucket-level filtering** — a `HavingClause` filters groups after aggregation by comparing a measure's value against a threshold, complementing record-level `Filter`s
- **Derived operations** — `CumulativeSumOp`, `DeltaOp`, and `MovingAverageOp` applied after aggregation, with well-defined output-type rules (`IntValue` → `DoubleValue` for moving averages; `DurationValue` preserved)
- **Series algebra** — a sealed `ScalarOp` family (`NegateOp`, `AbsOp`, `FillNullOp`) and a sealed `SeriesCombination` family (`SumCombination`, `DifferenceCombination`, `ProductCombination`, `RatioCombination`) with a single canonical type table; usable in-query via `TransformedMeasure` / `CalculatedMeasure` or on a held result via `SeriesAlgebra` (and the `SeriesAlgebraX` extension), with `UnmatchedBucketPolicy` governing key alignment
- **Typed validation** — `QueryValidator` returns `Result<Unit, AnalyticsError>` with a closed `AnalyticsErrorKind` enum; the executor never throws for validation failures
- **Pure-function execution** — `AnalyticsExecutor.execute` takes `(query, records, sources)` and returns `Result<AnalyticsResult, AnalyticsError>`; deterministic, no wall-clock reads, no hidden state
- **First-class time-series support** — calendar-aligned date-range presets, configurable week-start and quarter-start months, half-open `[start, end)` ranges, time-bucket densification so charts have no gaps
- **Paired queries** — `PairedQuerySpec` for cohort comparison or rate displays, with alignability validation across sources
- **Persistence** — `AnalyticsWidgetSpec` plus `WidgetPayloadCodec` round-trip user-built widget specs to JSON with a schema-version guard for forward compatibility
- **Records-layer caching** — `SourceSnapshotCache` with in-flight dedup, scoped invalidation, and discard-on-completion for stale fetches
- **Typed change events** — `AnalyticsChange` / `AnalyticsChangeKind` for targeted listener invalidation rules
- **Rendering-agnostic** — none of the types depend on a chart library or UI toolkit; consumers map `AnalyticsResult` to the renderer of their choice
- **Zero external dependencies** — only `dart:core` and `dart:convert`

## Design philosophy

The package draws two contracts and refuses to interpret beyond them — one at the input boundary, one at the output boundary, both deliberately symmetric.

**Input agnosticism.** The input contract sits at the `SourceRecord` boundary. From `source_record.dart`: *"`SourceRecord` is intentionally a thin wrapper around a map. It does not enforce schema matching at construction time."* The executor knows about field ids and typed values; it knows nothing about where those came from. Whether your records originate in a SQL row, a JSON payload, a Drift database, an iCloud sync, an in-memory list of domain objects, or a stream from a sensor — that's the host's domain, not the toolkit's. The canonical consumer pattern is a small `toRecord` method on whatever domain class the host already has: `MyTask.toRecord() -> SourceRecord(fields: {...})`. The toolkit refuses to grow opinions about CSV escaping rules, JSON shape coercion, or any other input-side concern.

**Output agnosticism.** The output contract sits at the `AnalyticsResult` boundary. From `display_spec.dart`: *"the package itself is rendering-agnostic — it never inspects or interprets the displayType string."* The executor produces typed result values (`ScalarResult`, `SeriesResult`, `MultiSeriesResult`, `MultiMeasureSeriesResult`, `TableResult`); the host renders them with whatever chart library, table widget, or custom paint code fits. `DisplaySpec.displayType` is an opaque string — `'bar'`, `'line'`, `'sparkline'`, `'my-custom-treemap-v2'` are all equally valid because the package never reads them. The toolkit refuses to grow opinions about color palettes, axis hints, or rendering frameworks.

**Why symmetry matters.** The two boundaries together describe a typed-query middle that is useful in isolation. Pair it with any data layer, pair it with any renderer, and the validator, executor, and result types remain useful. Adding opinions on either end — input parsers on one side, presentation hints on the other — would make the package larger and less composable. The features in this release deepen what the middle does; they do not push outward into either neighbor's territory.

## Installation

Add the package to your `pubspec.yaml`:

```yaml
dependencies:
  analytics_toolkit: ^0.2.0
```

Then run:

```bash
dart pub get
```

## Quick Start

A complete worked example: declare a source, build a few records, run a group-by query, read the result.

```dart
import 'package:analytics_toolkit/analytics_toolkit.dart';

void main() {
  // 1. Declare a source and its fields.
  final tasks = SourceDef(
    sourceId: 'tasks',
    displayName: 'Tasks',
    fields: const [
      FieldDef(
        sourceId: 'tasks',
        fieldId: 'status',
        displayName: 'Status',
        fieldType: FieldType.enumeration,
        filterable: true,
        groupable: true,
        aggregatable: false,
        sortable: true,
      ),
      FieldDef(
        sourceId: 'tasks',
        fieldId: 'priority',
        displayName: 'Priority',
        fieldType: FieldType.integer,
        filterable: true,
        groupable: true,
        aggregatable: true,
        sortable: true,
      ),
    ],
  );

  // 2. Build a few records.
  final records = [
    SourceRecord(fields: {
      'status': EnumValue('done'),
      'priority': IntValue(3),
    }),
    SourceRecord(fields: {
      'status': EnumValue('todo'),
      'priority': IntValue(1),
    }),
    SourceRecord(fields: {
      'status': EnumValue('done'),
      'priority': IntValue(2),
    }),
  ];

  // 3. Build a query: count tasks grouped by status.
  final query = AnalyticsQuerySpec(
    source: 'tasks',
    measures: const [CountMeasure()],
    groupBys: const [
      FieldGroupBy(
        fieldRef: FieldRef(sourceId: 'tasks', fieldId: 'status'),
      ),
    ],
  );

  // 4. Validate.
  final check = QueryValidator.validateQuery(query, sources: [tasks]);
  if (check case Err(error: final e)) {
    print('Invalid query: ${e.humanMessage}');
    return;
  }

  // 5. Execute.
  final result = AnalyticsExecutor.execute(
    query: query,
    records: records,
    sources: [tasks],
  );

  // 6. Read the result.
  switch (result) {
    case Ok(value: final r) when r is SeriesResult:
      for (final bucket in r.buckets) {
        print('${bucket.key} → ${bucket.value?.raw}');
      }
    case _:
      // Other shapes: ScalarResult (no group-by), MultiSeriesResult
      // (two group-bys), MultiMeasureSeriesResult (one group-by, 2+
      // measures), TableResult (StreakMeasure, 3 group-bys, or
      // multi-measure with 0/2/3 group-bys).
      break;
  }
}
```

The `example/` directory contains a longer runnable tour covering every result shape, the time-series pipeline, derived operations, series algebra, streaks, validation, and the codec.

## Schema

The schema layer declares what fields exist on each source and what each field's type and capabilities are. The validator and executor consult these declarations to type-check every query before running it.

### SourceDef and FieldDef

A `SourceDef` represents a queryable collection of records — a table, a list, a database view, anything the host can normalize. Each field is declared up front with capability flags (`filterable`, `groupable`, `aggregatable`, `sortable`) so the validator can reject incompatible queries early.

```dart
final orders = SourceDef(
  sourceId: 'orders',
  displayName: 'Orders',
  primaryDateFieldId: 'orderedAt',     // optional, for date-range projection
  fields: const [
    FieldDef(
      sourceId: 'orders',
      fieldId: 'orderedAt',
      displayName: 'Ordered at',
      fieldType: FieldType.dateTime,
      filterable: true,
      groupable: true,
      aggregatable: false,
      sortable: true,
    ),
    FieldDef(
      sourceId: 'orders',
      fieldId: 'total',
      displayName: 'Order total',
      fieldType: FieldType.double,
      filterable: true,
      groupable: false,
      aggregatable: true,
      sortable: true,
    ),
  ],
);
```

`SourceDef` is intentionally **not** `const`-constructible — it carries a lazy field-id → `FieldDef` index so repeated field lookups during query execution are amortized O(1). Build it once at app startup, not on every query.

#### SourceDef Properties

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `sourceId` | `String` | required | Stable identifier persisted in queries |
| `displayName` | `String` | required | User-facing name |
| `fields` | `List<FieldDef>` | required | Field declarations. Duplicates and cross-source mismatches throw at construction. |
| `primaryDateFieldId` | `String?` | `null` | Name of the `dateTime` field used for page-level date-range projection and cross-source alignment in paired queries. Required to be a declared `dateTime` field when non-null. |

#### FieldDef Properties

| Parameter | Type | Description |
|-----------|------|-------------|
| `fieldId` | `String` | Stable identifier persisted in queries |
| `sourceId` | `String` | Must equal the parent `SourceDef.sourceId` |
| `displayName` | `String` | User-facing name |
| `fieldType` | `FieldType` | One of `string`, `enumeration`, `integer`, `double`, `boolean`, `dateTime`, `duration` |
| `filterable` / `groupable` / `aggregatable` / `sortable` | `bool` | Advisory capability flags; the validator enforces them |

### Typed values

Every value flowing through the package — filter operands, record fields, aggregation outputs, table cells — is a `TypedValue`. The sealed shape carries both the value and its declared `FieldType`, so the executor never has to sniff at runtime.

```dart
StringValue('online')
IntValue(42)
DoubleValue(3.14)
BoolValue(true)
EnumValue('done')
DateTimeValue(DateTime.utc(2026, 5, 14))
DurationValue(const Duration(minutes: 90))

// List-valued variants — used only by the `inList` filter operator.
StringListValue(['a', 'b'])
EnumListValue(['todo', 'in_progress'])
IntListValue([1, 2, 3])

// Null carrier — distinct from "field absent", but treated the same way
// by every downstream engine.
const NullValue(FieldType.integer)
```

All subtypes implement value equality. `TypedValueOrdering.compare(a, b)` is the single source of truth for comparing two typed values; it returns `null` for unordered pairs (anything involving `NullValue`, or mismatched raw types).

## Queries

`AnalyticsQuerySpec` is the unit consumed by the executor:

```dart
final query = AnalyticsQuerySpec(
  source: 'orders',
  measures: const [
    FieldMeasure(
      fieldRef: FieldRef(sourceId: 'orders', fieldId: 'total'),
      aggregation: SumAgg(),
      label: 'total_sum',
    ),
  ],
  filters: const [
    Filter(
      fieldRef: FieldRef(sourceId: 'orders', fieldId: 'region'),
      operator: FilterOperator.equals,
      value: EnumValue('west'),
    ),
  ],
  groupBys: const [
    FieldGroupBy(
      fieldRef: FieldRef(sourceId: 'orders', fieldId: 'region'),
    ),
  ],
  sort: const Sort(
    target: MeasureValueSort(measureLabel: 'total_sum'),
    direction: SortDirection.descending,
  ),
  limit: 10,
  derivedOperation: const NoDerivedOp(),
);
```

#### AnalyticsQuerySpec Properties

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `source` | `String` | required | The `sourceId` this query runs against |
| `measures` | `List<Measure>` | required | What to compute. At least one and at most five; each measure's effective label (explicit `label`, otherwise the auto-generated `measure_<index>`) must be unique within the query. |
| `filters` | `List<Filter>` | `[]` | AND-combined, record-level filter conditions; OR is not supported |
| `groupBys` | `List<GroupBy>` | `[]` | Up to three group-by dimensions; cardinality plus measure count determines the result shape |
| `having` | `HavingClause?` | `null` | Optional bucket-level filter applied after aggregation |
| `sort` | `Sort?` | `null` | Result sort; applied after aggregation |
| `limit` | `int?` | `null` | Optional cap on bucket count; applied after sorting; must be non-negative |
| `derivedOperation` | `DerivedOperation` | `NoDerivedOp()` | Post-aggregation transformation |

Use `query.withAdditionalFilters([...])` to produce a copy with extra filters appended; the original spec is never mutated.

### Measures

`Measure` is a sealed family with five cases — three leaf cases that aggregate records directly, and two expression cases that compose other measures. Every measure accepts an optional `label`:

```dart
// Count every record in the group.
const CountMeasure()

// Aggregate a numeric or temporal field. `aggregation` is a
// FieldAggregation: SumAgg, AverageAgg, MinAgg, MaxAgg,
// DistinctCountAgg, or PercentileAgg.
const FieldMeasure(
  fieldRef: FieldRef(sourceId: 'orders', fieldId: 'total'),
  aggregation: SumAgg(),
)

// Median (50th percentile) of a numeric field.
const FieldMeasure(
  fieldRef: FieldRef(sourceId: 'orders', fieldId: 'total'),
  aggregation: PercentileAgg(p: 0.5),
)

// Compute consecutive-completion streaks per entity.
const StreakMeasure(
  entityIdField: FieldRef(sourceId: 'habits', fieldId: 'habitId'),
  scheduledDateField: FieldRef(sourceId: 'habits', fieldId: 'scheduledFor'),
  statusField: FieldRef(sourceId: 'habits', fieldId: 'status'),
  completedStatusValue: 'done',
  entityLabelField: FieldRef(sourceId: 'habits', fieldId: 'habitName'),
  topN: 10,
)

// Expression cases — compose other measures into one. Apply a per-value
// op to a single child:
const TransformedMeasure(
  operand: FieldMeasure(
    fieldRef: FieldRef(sourceId: 'orders', fieldId: 'total'),
    aggregation: SumAgg(),
  ),
  op: NegateOp(),
)

// Or fold two children into one, e.g. profit = revenue − cost:
const CalculatedMeasure(
  operandA: FieldMeasure(
    fieldRef: FieldRef(sourceId: 'orders', fieldId: 'revenue'),
    aggregation: SumAgg(),
  ),
  operandB: FieldMeasure(
    fieldRef: FieldRef(sourceId: 'orders', fieldId: 'cost'),
    aggregation: SumAgg(),
  ),
  combination: DifferenceCombination(),
)
```

A query may carry up to five measures. With one group-by and two or more measures the executor produces a `MultiMeasureSeriesResult`; see [Results](#results). When more than one measure is present each must carry an explicit `label` wherever a `Sort` or `HavingClause` needs to address it, since the auto-generated `measure_<index>` labels are positional.

Each measure declares a `supportsDateRange` capability — `CountMeasure` and `FieldMeasure` support page-level date ranges; `StreakMeasure` does not (streaks are computed over an entity's full lifetime); the expression cases inherit the capability from their operands. The validator enforces that the widget's `DateRangeMode` agrees with this flag.

An expression node is itself a `Measure`, so the whole tree counts as exactly one measure everywhere — result-shape inference, the five-measure cap, sorting, and the derived operation all treat it as one. See [Series algebra](#series-algebra) for the full `ScalarOp` / `SeriesCombination` contract and the result-level counterpart. See [Streaks](#streaks) below for the full `StreakMeasure` contract.

### Group-bys

`GroupBy` is a sealed family with two cases. Both accept an optional `label`:

```dart
// Categorical grouping by any groupable field.
FieldGroupBy(
  fieldRef: FieldRef(sourceId: 'orders', fieldId: 'region'),
)

// Temporal grouping by a dateTime field at a specified grain.
TimeGroupBy(
  dateFieldRef: FieldRef(sourceId: 'orders', fieldId: 'orderedAt'),
  grain: TimeGrain.day,
)

// With an explicit column label, e.g. to disambiguate from a measure
// whose effective label would otherwise collide.
FieldGroupBy(
  fieldRef: FieldRef(sourceId: 'orders', fieldId: 'status'),
  label: 'status_group',
)
```

A query allows up to three group-by clauses, stored in the `groupBys` list. The list's cardinality, combined with the number of measures, determines the result shape (see [Result shape inference](#result-shape-inference)). At most one `TimeGroupBy` is permitted per query; a second temporal group-by is rejected with `AnalyticsErrorKind.multipleTemporalGroupBys`, and a fourth group-by of any kind with `AnalyticsErrorKind.tooManyGroupBys`.

`GroupBy.label` overrides the label the group-by projects as a column. When the union of effective group-by labels and effective measure labels would contain a duplicate, the validator returns `AnalyticsErrorKind.duplicateColumnLabel`; set an explicit `label` on the colliding group-by or measure to resolve it. `label` is excluded from `GroupBy` equality, so two queries that differ only by display label still compare as structurally equivalent (which keeps paired-query alignability correct under aliasing).

`TimeGroupBy` works on any `dateTime` field declared on the source, regardless of whether that field is the source's `primaryDateFieldId` — the primary is only the default for page-level date-range projection.

### Filters

```dart
Filter(
  fieldRef: FieldRef(sourceId: 'orders', fieldId: 'status'),
  operator: FilterOperator.equals,
  value: EnumValue('shipped'),
)

// `inList` takes a list-valued TypedValue.
Filter(
  fieldRef: FieldRef(sourceId: 'orders', fieldId: 'status'),
  operator: FilterOperator.inList,
  value: EnumListValue(['shipped', 'delivered']),
)

// `equals` and `notEquals` against NullValue act as "is null" / "is not null".
Filter(
  fieldRef: FieldRef(sourceId: 'orders', fieldId: 'shippedAt'),
  operator: FilterOperator.equals,
  value: const NullValue(FieldType.dateTime),
)
```

`FilterOperator` values: `equals`, `notEquals`, `lessThan`, `lessThanOrEqual`, `greaterThan`, `greaterThanOrEqual`, `inList`. The validator enforces operator-vs-field-type compatibility and rejects ordered comparisons against `NullValue`. Filters act on records before grouping; for filtering on aggregated values after grouping, see [HAVING](#having).

### HAVING

A `HavingClause` filters at the bucket level — after grouping and aggregation — by comparing a measure's aggregated value against a threshold. This is the post-aggregation counterpart to record-level `Filter`s:

```dart
const HavingClause(
  operator: HavingOperator.greaterThanOrEqual,
  threshold: IntValue(2),
  measureLabel: 'count',          // null targets the sole measure
)
```

`HavingOperator` values: `equals`, `notEquals`, `lessThan`, `lessThanOrEqual`, `greaterThan`, `greaterThanOrEqual` (a strict subset of `FilterOperator` — `inList` has no bucket-value analogue). `measureLabel` resolves against measure labels the same way `MeasureValueSort` does; it may be left null for a single-measure query. A `HavingClause` on a query with no group-bys is rejected with `AnalyticsErrorKind.havingRequiresGrouping`.

### Sorting

`Sort.target` is a sealed family — sort either by the group-field's bucket key or by the aggregated measure value:

```dart
const Sort(
  target: GroupFieldSort(
    fieldRef: FieldRef(sourceId: 'orders', fieldId: 'region'),
  ),
  direction: SortDirection.ascending,
)

const Sort(
  target: MeasureValueSort(measureLabel: 'total_sum'),
  direction: SortDirection.descending,
)
```

By default, null values (both `null` aggregation values and `NullBucketKey`s) follow the sort direction, matching the SQL convention where null is treated as larger than any non-null value: an ascending sort places nulls **last**, a descending sort places nulls **first**. Set `forceNullsLast: true` to pin nulls at the end regardless of direction — useful for ranked dashboards where missing data should never appear at the top:

```dart
const Sort(
  target: MeasureValueSort(measureLabel: 'total_sum'),
  direction: SortDirection.descending,
  forceNullsLast: true,
)
```

### Derived operations

`DerivedOperation` is a sealed family of post-aggregation transformations applied after grouping, aggregation, and sorting, and before wrapping in the result type:

```dart
const NoDerivedOp()              // default, identity

const CumulativeSumOp()          // running total
const DeltaOp()                  // first-difference (bucket[i] - bucket[i-1])
const MovingAverageOp(window: 7) // window-of-N rolling mean
```

Derived operations preserve the input value type for `CumulativeSumOp` and `DeltaOp`. `MovingAverageOp` preserves `DurationValue` but promotes `IntValue` to `DoubleValue` (the average of integers is generally fractional). Applying a derived op to a measure with non-numeric output (e.g. `min` over a `dateTime` field) is rejected with `derivedOpRequiresNumericMeasure`. Derived operations apply only to `SeriesResult`-shaped queries (a single group-by and a single numeric measure).

`MovingAverageOp(window: N)` over a series of length M emits all M buckets — the first `N-1` use a partial window rather than being padded with null. Null bucket values (from `average`/`min`/`max` over empty groups, including synthetic empty buckets from densification) contribute `0` to the window sum at each position they appear in.

### Series algebra

Series algebra is per-value arithmetic over series: negate or absolute-value a series, fill its null buckets, or combine two series with `+`, `−`, `×`, `÷`. It comes in two flavors that share one set of arithmetic and type rules, so they never disagree:

- **In-query**, as part of a `Measure` tree — `TransformedMeasure` (one operand) and `CalculatedMeasure` (two operands). Both children aggregate over the same bucket's records, so their values are inherently aligned and no key matching is needed.
- **Result-level**, on a `SeriesResult` already in hand — `SeriesAlgebra` and the `SeriesAlgebraX` extension. This path requires no query, no re-fetch, and no re-aggregation; it aligns two held series by bucket key, so it carries an explicit `UnmatchedBucketPolicy`.

Two small sealed families describe the operations themselves.

`ScalarOp` is a per-value transform — one numeric value to one numeric value of the same type:

```dart
const NegateOp()      // v → -v;  propagates null
const AbsOp()         // v → |v|; propagates null
const FillNullOp(0)   // null → the given fill, boxed into the series type;
                      // a non-null value passes through unchanged
```

`NegateOp` and `AbsOp` propagate null (a null value maps to null); `FillNullOp` is the only op that turns a null into a number, and only when asked. For a `duration` series the fill is interpreted in microseconds, so `FillNullOp(0)` yields `Duration.zero`.

`SeriesCombination` folds two values into one:

```dart
const SumCombination()         // a + b
const DifferenceCombination()  // a - b
const ProductCombination()     // a * b   (always a unitless double)
const RatioCombination()       // a / b   (always a unitless double; null when b is null or 0)
```

All combinations propagate null: if either operand is null, the result is null. `RatioCombination` additionally yields null when the denominator is null or zero.

**Output types.** Every `ScalarOp` preserves the input type. For combinations, `combineOutputType` is the single source of truth: `SumCombination` and `DifferenceCombination` preserve the unit family (`integer`+`integer` → `integer`; any pair involving a `double` → `double`; `duration`+`duration` → `duration`; mixing a `duration` with a non-`duration` is **invalid**), while `ProductCombination` and `RatioCombination` always yield a unitless `double` (a `duration` operand contributes its microsecond magnitude). An invalid combination — a non-numeric operand, or a mixed-unit sum or difference — is rejected with `incompatibleSeriesCombination`.

#### In-query: TransformedMeasure and CalculatedMeasure

Both are `Measure` cases, so an expression tree is treated as exactly one measure by the rest of the engine (result-shape inference, the five-measure cap, sorting, the derived operation). Operands are held inline — not referenced by label — so an expression is self-contained, composes freely, and has no possibility of a reference cycle:

```dart
// Profit margin: (revenue − cost) / revenue, as a single measure.
final margin = AnalyticsQuerySpec(
  source: 'finance',
  measures: const [
    CalculatedMeasure(
      operandA: CalculatedMeasure(
        operandA: FieldMeasure(
          fieldRef: FieldRef(sourceId: 'finance', fieldId: 'revenue'),
          aggregation: SumAgg(),
        ),
        operandB: FieldMeasure(
          fieldRef: FieldRef(sourceId: 'finance', fieldId: 'cost'),
          aggregation: SumAgg(),
        ),
        combination: DifferenceCombination(),
      ),
      operandB: FieldMeasure(
        fieldRef: FieldRef(sourceId: 'finance', fieldId: 'revenue'),
        aggregation: SumAgg(),
      ),
      combination: RatioCombination(),
      label: 'margin',
    ),
  ],
  groupBys: [
    FieldGroupBy(fieldRef: FieldRef(sourceId: 'finance', fieldId: 'region')),
  ],
);
```

`TransformedMeasure`'s output type equals its operand's; `CalculatedMeasure`'s is `combineOutputType` of the two operands. The validator rejects a non-numeric operand or a mixed-unit combination with `incompatibleSeriesCombination`, and a `StreakMeasure` used as an operand with `streakNotCombinable`. Expression nesting depth is bounded by `maxExpressionDepth` (default 8); a deeper tree is rejected with `preconditionViolation`.

`TransformedMeasure` and `CalculatedMeasure` round-trip through `WidgetPayloadCodec` like any other measure — the operands and ops encode inline under the existing schema version, so persisting an expression measure is not a schema migration.

#### Result-level: SeriesAlgebra

`SeriesAlgebra` operates on a `SeriesResult` you already have, returning a new immutable `SeriesResult` (the input is never modified). Three statics cover the three operation families, and each validates its own operands and returns a `Result` rather than throwing:

```dart
// Whole-series derived op (cumulative sum, delta, moving average).
SeriesAlgebra.apply(series, const CumulativeSumOp());

// Per-value op (negate, absolute value, fill-null).
SeriesAlgebra.transform(series, const NegateOp());

// Binary combination of two held series, aligned by bucket key.
SeriesAlgebra.combine(
  revenueSeries,
  costSeries,
  op: const DifferenceCombination(),
  policy: UnmatchedBucketPolicy.drop,
);
```

The `SeriesAlgebraX` extension is ergonomic sugar over these, and because every method returns a `Result`, operations of different families chain through `andThen` — an ordering a single query spec cannot express:

```dart
// Running total, then negate the result.
final net = series.cumulativeSum().andThen((s) => s.negated());

// revenue − cost as two held series.
final diff = revenueSeries.combineWith(costSeries, const DifferenceCombination());
```

The extension methods are `cumulativeSum()`, `delta()`, `movingAverage(n)`, `negated()`, `absolute()`, `fillNull(n)`, and `combineWith(other, op, {policy})`.

**Combining two series.** `SeriesAlgebra.combine` aligns `x` and `y` by bucket key. It rejects (`incompatibleSeriesCombination`) when either series is non-numeric, when the two have incompatible group dimensions (different group kind or group field type), or when the measure types cannot be combined under the op. An empty or fully unmatched input still yields a valid (possibly empty) series, not an error. The result inherits `x`'s group metadata and takes the op's output type; `measureLabel`, `groupColumnLabel`, and `semanticTag` override the inherited values when supplied. A bucket is marked synthetic only when both contributing buckets were synthetic.

**Absent keys vs. null values are independent.** `UnmatchedBucketPolicy` governs only an *absent key* — a key one series has and the other lacks. A *null value* (a present key whose value is null) always propagates regardless of policy; control absent keys with the policy and null values with `FillNullOp`.

| Policy | Keys kept | Absent side treated as |
|--------|-----------|------------------------|
| `drop` (default) | intersection, in `x`'s order | — (key omitted) |
| `fillIdentity` | union, sorted nulls-last | the combination's identity: `0` for sum/difference, `1` for product |

A ratio has no identity, so under either policy a key absent on either side is omitted from a `RatioCombination`.

### Query payloads

`AnalyticsWidgetSpec.queryJson` always stores a `QueryPayload`, never a raw `AnalyticsQuerySpec`. `QueryPayload` is sealed with two cases:

```dart
SingleQuerySpec(query: myQuery)

// For scatter or rate displays.
PairedQuerySpec(xQuery: numeratorQuery, yQuery: denominatorQuery)
```

Both halves of a paired query must be alignable: they share the same source, or both sides use `TimeGroupBy` with the same `TimeGrain` and both sources have a non-null `primaryDateFieldId`. The validator rejects non-alignable pairs with `incompatiblePairedQueryShapes`.

## Results

`AnalyticsResult` is a sealed family with five cases. Whether a series is categorical or temporal is encoded in `SeriesResult.groupKind` (or `MultiSeriesResult.groupKind` / `MultiMeasureSeriesResult.groupKind`), not as a separate result type.

### ScalarResult

A single aggregated value, produced when the query has no group-bys and a single measure:

```dart
final result = AnalyticsExecutor.execute(
  query: AnalyticsQuerySpec(
    source: 'orders',
    measures: const [
      FieldMeasure(
        fieldRef: FieldRef(sourceId: 'orders', fieldId: 'total'),
        aggregation: SumAgg(),
      ),
    ],
  ),
  records: orderRecords,
  sources: [orders],
);

switch (result) {
  case Ok(value: ScalarResult(value: final v)):
    print('Total: ${v?.raw}');   // v is a TypedValue?; null on empty input for non-additive
  case Err(error: final e):
    print('Failed: ${e.humanMessage}');
}
```

`value` is `null` when the measure returns undefined over empty input (e.g. `average` over zero records). Additive aggregations like `count` and `sum` return the additive identity (`IntValue(0)`, `DoubleValue(0.0)`) instead.

### SeriesResult

One bucket per group key, produced when the query has exactly one group-by and a single measure:

```dart
case Ok(value: SeriesResult(:final buckets, :final groupKind)):
  for (final bucket in buckets) {
    print('${bucket.key} → ${bucket.value?.raw}');
  }
```

`SeriesGroupKind` is either `categorical` or `temporal` — drives downstream rendering decisions without requiring the consumer to inspect the original query.

Each `SeriesBucket` carries a typed `BucketKey`, an aggregated `TypedValue?`, an `isSynthetic` flag (set on buckets produced by densification), and an optional consumer-supplied `displayLabel` (the executor leaves it `null`; attach labels in a post-processing pass).

### MultiSeriesResult

Produced when the query has two group-bys and a single measure — one primary x-axis with N named series:

```dart
case Ok(value: MultiSeriesResult(:final xAxis, :final series)):
  for (final s in series) {
    print('Series ${s.key}:');
    for (int i = 0; i < xAxis.length; i++) {
      print('  ${xAxis[i].key} → ${s.values[i]?.raw}');
    }
  }
```

`xAxis` is a `List<XAxisPosition>` of primary-groupBy positions in display order. Each `NamedSeries.values` is index-aligned to `xAxis`. Missing (primary, secondary) combinations follow the same rule as `SeriesBucket.value`: additive aggregations get a typed zero, non-additive aggregations get `null`.

### MultiMeasureSeriesResult

Produced when the query has exactly one group-by and two or more measures — one x-axis with one series per measure:

```dart
case Ok(value: MultiMeasureSeriesResult(:final xAxis, :final series)):
  for (final measureSeries in series) {
    print('Measure ${measureSeries.label}:');
    for (int i = 0; i < xAxis.length; i++) {
      print('  ${xAxis[i].key} → ${measureSeries.values[i]?.raw}');
    }
  }
```

Each `MeasureSeries` carries the measure's effective `label`, its output `fieldType`, and a `values` list index-aligned to `xAxis`, in `AnalyticsQuerySpec.measures` order.

### TableResult

A column-oriented table, produced by `StreakMeasure`, by any query with three group-bys, and by multi-measure queries with zero, two, or three group-bys:

```dart
case Ok(value: TableResult(:final columns, :final rowKeys, :final truncatedCount)):
  // Print a header row, then one line per row index.
  print(columns.map((c) => c.label).join(' | '));
  for (var r = 0; r < rowKeys.length; r++) {
    print(columns.map((c) => c.values[r]?.raw).join(' | '));
  }
  if (truncatedCount > 0) {
    print('+$truncatedCount more rows omitted (see StreakMeasure.topN)');
  }
```

`TableResult` is column-oriented: `columns` is a `List<TableColumn>` (each carrying a `label`, a `fieldType`, a `kind` of `groupKey` or `measure`, and a `values` list), and `rowKeys` holds one `RowKey` per row. Every column's `values` length equals `rowKeys.length`. Use `columnByLabel(label)` to look a column up by name.

`TableResult.truncatedCount` is the count of rows that existed in the underlying computation but were dropped before being returned (e.g. by `StreakMeasure.topN`). A renderer can surface this as "+N more"; the package never injects a synthetic "and X more" row.

### BucketKey

`BucketKey` is a sealed family. Equality is value-based, so paired-query alignment can happen without sniffing types — two buckets with equal keys belong together.

| Subtype | Used when |
|---------|-----------|
| `StringBucketKey` | `FieldGroupBy` targets a `string` field |
| `EnumBucketKey` | `FieldGroupBy` targets an `enumeration` field |
| `BoolBucketKey` | `FieldGroupBy` targets a `boolean` field |
| `IntBucketKey` | `FieldGroupBy` targets an `integer` field — sorts numerically, not lexically |
| `DoubleBucketKey` | `FieldGroupBy` targets a `double` field — sorts numerically |
| `TimeBucketKey` | `TimeGroupBy` — `(instant, grain)` pair where `instant` is the start of the bucket window |
| `NullBucketKey` | A record's group field is null — distinct from "bucket absent" |

`BucketKeyOrdering.compare(a, b)` is the single source of truth for ordering. `BucketKeyOrdering.compareNullsLast(a, b)` is the same comparison with explicit nulls-last semantics; both are used by the executor's sort and densification paths.

### Result shape inference

A builder UI can predict the result shape before running the query, so display-type pickers can be populated up front:

```dart
final shape = InferResultShape.ofPayload(payload);
// ResultShape.scalar | series | multiSeries | multiMeasureSeries
//            | table | pairedSeries
```

Inference rules, by `(groupBys.length, measures.length)`:

| Group-bys | Measures | Shape |
|-----------|----------|-------|
| any | contains `StreakMeasure` | `table` |
| 0 | 1 | `scalar` |
| 1 | 1 | `series` |
| 2 | 1 | `multiSeries` |
| 1 | ≥ 2 | `multiMeasureSeries` |
| 3 | any | `table` |
| 0 or 2 | ≥ 2 | `table` |

A `PairedQuerySpec` infers to `pairedSeries`.

## Validation

`QueryValidator` is the static entry point for both query-level and widget-level validation. Both paths return `Result<Unit, AnalyticsError>` — neither throws for validation failures.

```dart
// Single-query validation — used by the executor at the top of every pipeline.
final r = QueryValidator.validateQuery(query, sources: [orders]);

// Widget-level validation — checks the inner query plus the cross-rule that
// the widget's DateRangeMode must agree with the measure's supportsDateRange.
final w = QueryValidator.validateWidgetPayload(
  payload: SingleQuerySpec(query: query),
  sources: [orders],
  dateRangeMode: const UsePageRange(),
);
```

`AnalyticsError` carries a closed `AnalyticsErrorKind` enum, an optional `affectedField` (`FieldRef?`), and a default English `humanMessage`. Consumers needing localization should switch on `kind` and produce their own copy.

Both `validateQuery` and `validateWidgetPayload` accept an optional `maxExpressionDepth` (default `QueryValidator.defaultMaxExpressionDepth`, currently 8) that bounds the nesting depth of an expression measure; the same parameter is threaded through `AnalyticsExecutor.execute`. A tree deeper than the ceiling is rejected with `preconditionViolation`.

### Error kinds

The closed list of `AnalyticsErrorKind` values:

`unknownSource`, `unknownField`, `unknownMeasureLabel`, `fieldNotGroupable`, `fieldNotFilterable`, `fieldNotAggregatable`, `incompatibleAggregation`, `incompatibleSeriesCombination`, `incompatibleOperator`, `timeGrainOnNonDateField`, `streakWithExplicitGrouping`, `measuresEmpty`, `tooManyMeasures`, `duplicateMeasureLabel`, `duplicateColumnLabel`, `streakNotCombinable`, `dateRangeNotSupportedForMeasure`, `dateRangeRequiredForMeasure`, `invalidDerivedOperationParameter`, `invalidAggregationParameter`, `incompatiblePairedQueryShapes`, `incompatibleSortTarget`, `tooManyGroupBys`, `multipleTemporalGroupBys`, `havingRequiresGrouping`, `derivedOpRequiresNumericMeasure`, `primaryDateFieldRequiredForOperation`, `preconditionViolation`, `sourceRecordTypeMismatch`, `unexpected`.

Adding a new kind is a breaking change for any consumer that pattern-matches the full set.

### Result, Ok, Err, Unit

`Result<T, E>` is a sealed Ok/Err type so callers get a compile-time signal that both branches must be handled — no silent null returns, no thrown exceptions for normal validation failures.

```dart
// Idiomatic pattern match.
switch (result) {
  case Ok(value: final v): /* use v */
  case Err(error: final e): /* handle e */
}

// One-branch early return.
final v = result.okOrNull;
if (v == null) return;

// Chain validation steps.
result.andThen((v) => nextValidation(v));
```

`Unit` is a zero-information success value. `Result<Unit, E>` is preferred over `Result<bool, E>` for void-like operations because the `true` in `Result<bool, E>` carries no meaning.

## Execution

`AnalyticsExecutor.execute` is a pure function: it takes a query, a record stream, and a source catalog, and returns a typed `Result<AnalyticsResult, AnalyticsError>`. It never throws for validation failures — those come back as `Err`. It may throw `StateError` only for invariants the validator was expected to enforce upstream (those are bugs, not data conditions).

```dart
final result = AnalyticsExecutor.execute(
  query: query,
  records: records,
  sources: [orders],
  asOf: DateTime.now(),                     // required by StreakMeasure; unused otherwise
  dateRange: (start, endExclusive),         // optional; enables time-bucket densification
);
```

#### Execute Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `query` | `AnalyticsQuerySpec` | The query to run |
| `records` | `Iterable<SourceRecord>` | Records to query against |
| `sources` | `List<SourceDef>` | Source catalog used for validation and field lookup |
| `asOf` | `DateTime?` | Reference "now" for `StreakMeasure`. Required for streak queries; unused otherwise. |
| `dateRange` | `(DateTime, DateTime)?` | The resolved page-level date range used to fetch records. When non-null and the query uses `TimeGroupBy`, the executor densifies the result so every bucket in the range is represented. |
| `densify` | `bool` | Whether to densify temporal series; defaults to `true`. Set `false` to emit only observed buckets. |
| `maxExpressionDepth` | `int` | Ceiling on the nesting depth of an expression measure (`TransformedMeasure` / `CalculatedMeasure`); a deeper tree is rejected with `preconditionViolation`. Defaults to `QueryValidator.defaultMaxExpressionDepth` (8). |

### Source records

Source providers feed the executor with `SourceRecord`s — thin wrappers around `Map<String, TypedValue>`. The provider is responsible for emitting records whose field keys match the source's `FieldDef.fieldId`s and whose values are `TypedValue`s of the declared subtype:

```dart
SourceRecord(fields: {
  'orderedAt': DateTimeValue(DateTime.utc(2026, 5, 14, 10)),
  'region': EnumValue('west'),
  'total': DoubleValue(42.50),
})
```

The executor verifies this contract at the top of every pipeline. Records whose `TypedValue` subtype disagrees with the source's declared `FieldType` produce `Err(sourceRecordTypeMismatch)` — the executor never coerces or silently skips them.

Absent fields and explicit `NullValue` are treated equivalently by every downstream engine: both signal "no value for this record" and are skipped from aggregations, groupings, and filter matches.

## Time-Series

The time-series layer is first-class but skippable. Apps doing only categorical / tabular analytics can ignore everything in this section.

### Date ranges

`WidgetDateRange` is a sealed family with two cases:

```dart
// A preset to be resolved by DatePresetResolver.
const PresetRange(preset: DateRangePreset.last30Days)

// Explicit user-facing inclusive endpoints. The constructor converts to
// the package's internal half-open form: records on the user's end day
// are included; records at midnight the next day are excluded.
CustomRange(
  start: DateTime(2026, 1, 1),
  end: DateTime(2026, 5, 14),
)
```

All ranges follow `[startInclusive, endExclusive)` internally. `DateRangePreset` is a closed set: `last7Days`, `last14Days`, `last30Days`, `last90Days`, `thisWeek`, `thisMonth`, `lastMonth`, `quarterToDate`, `allTime`.

`DateRangeMode` says how a widget interprets the date range. Sealed with three cases:

```dart
const UsePageRange()                                  // follow the page-level range
FixedOverride(range: PresetRange(preset: …))          // widget carries its own
const NoDateRange()                                   // measure does not take a range
```

The validator enforces the cross-rule: a measure with `supportsDateRange == false` (i.e. `StreakMeasure`) requires `NoDateRange`; everything else requires `UsePageRange` or `FixedOverride`.

### DatePresetResolver

The centralized resolver. Both page-level and widget `FixedOverride` ranges go through it:

```dart
final (start, endExclusive) = DatePresetResolver.resolve(
  const PresetRange(preset: DateRangePreset.thisMonth),
  today: DateTime.now(),                          // injected for testability
  earliestDataDate: oldestRecord,                 // optional; used by allTime
  weekStartDay: DateTime.sunday,                  // default; DateTime.monday for ISO
  quarterStartMonth: 1,                           // 1=Jan-Mar; 4 for Apr-start fiscal
);

// Convenience overload that takes a DateRangeMode and a page-level fallback.
final resolved = DatePresetResolver.resolveMode(
  mode,
  today: DateTime.now(),
  pageRange: (pageStart, pageEnd),                // required for UsePageRange
);
```

The package never reads wall-clock time — callers must supply `today` so resolution is deterministic and testable.

### DateRangeProjector

Once you have a resolved range, `DateRangeProjector.project` builds two date filters against the source's `primaryDateFieldId` and appends them to the query. The persisted query is never mutated:

```dart
final projected = DateRangeProjector.project(
  query: query,
  mode: const UsePageRange(),
  sources: [orders],
  pageRange: (pageStart, pageEnd),
  today: DateTime.now(),
);

if (projected case Ok(value: final q)) {
  AnalyticsExecutor.execute(query: q, records: records, sources: [orders]);
}
```

Projection against a source with no `primaryDateFieldId` produces `Err(primaryDateFieldRequiredForOperation)` — non-temporal sources cannot have page-level date ranges projected against them.

### TimeGrain and TimeUnit

`TimeGrain` is "N units of cadence, anchored at a reference moment, optionally aligned to a specific weekday for week-grain." Together with `TimeUnit`, this gives a single uniform vocabulary for every periodic grain from microseconds to multi-year:

```dart
TimeGrain.day                       // every day
TimeGrain.week                      // every Sunday-aligned week
TimeGrain.month
TimeGrain.year

// Every 15 minutes.
TimeGrain(count: 15, unit: TimeUnit.minute, anchor: DateTime.utc(2000, 1, 1))

// Every 2 weeks, anchored to Sundays.
TimeGrain(
  count: 2,
  unit: TimeUnit.week,
  anchor: DateTime.utc(2000, 1, 2),
)

// Apr-start fiscal quarter.
TimeGrain(count: 3, unit: TimeUnit.month, anchor: DateTime.utc(2024, 4, 1))

// Decade.
TimeGrain(count: 10, unit: TimeUnit.year, anchor: DateTime.utc(2000, 1, 1))
```

`TimeUnit` values: `microsecond`, `millisecond`, `second`, `minute`, `hour`, `day`, `week`, `month`, `year`.

The bucketing math is exposed by the `TimeGrainArithmetic` extension on `TimeGrain`:

```dart
final bucketStart = TimeGrain.day.startOfBucket(instant);
final next = TimeGrain.day.nextBucketStart(bucketStart);
```

Together these are enough to walk a date range bucket-by-bucket (densify time series), assign records to buckets (group), and align two queries to the same time grain (paired queries). All math uses Dart's `DateTime` arithmetic; if precise DST behavior matters, normalize records and anchors to UTC.

#### Week-start alignment

`TimeGrain.weekStartDay` is meaningful only when `unit` is `TimeUnit.week`. When non-null, it expresses an alignment intent without forcing the caller to pre-shift the anchor:

```dart
// ISO 8601 week-start (Monday).
TimeGrain(
  count: 1,
  unit: TimeUnit.week,
  anchor: DateTime.utc(2000, 1, 1),
  weekStartDay: DateTime.monday,
)
```

`weekStartDay` follows Dart's convention: `1 = Monday`, `7 = Sunday`. Supplying it for a non-week unit, or with a value outside `[1, 7]`, throws `ArgumentError` at construction.

### Densification

When `AnalyticsExecutor.execute` receives a `TimeGroupBy` query and a non-null `dateRange` (with the default `densify: true`), it densifies the result so every bucket in the range is represented — even buckets with no matching records. Additive aggregations (`count`, `sum`) get a typed zero in synthetic buckets; non-additive aggregations (`average`, `min`, `max`) get `null`. Synthetic buckets carry `isSynthetic: true`. This lets line charts and bar charts render gap-free without consumer-side bucket-filling.

For example, consider a `TimeGroupBy(day)` query over the date range `[2025-04-01, 2025-04-08)` — 7 days — where the source has matching records on only April 1, April 3, and April 7:

```dart
final query = AnalyticsQuerySpec(
  source: 'events',
  measures: const [CountMeasure()],
  groupBys: [
    TimeGroupBy(
      dateFieldRef: const FieldRef(sourceId: 'events', fieldId: 'occurredAt'),
      grain: TimeGrain.day,
    ),
  ],
);

final result = AnalyticsExecutor.execute(
  query: query,
  records: records,
  sources: [events],
  dateRange: (DateTime.utc(2025, 4, 1), DateTime.utc(2025, 4, 8)),
);
```

The resulting `SeriesResult` has 7 buckets, one per day in the half-open range:

| bucket key (day) | value          |
| ---------------- | -------------- |
| 2025-04-01       | `IntValue(N₁)` |
| 2025-04-02       | `IntValue(0)`  |
| 2025-04-03       | `IntValue(N₃)` |
| 2025-04-04       | `IntValue(0)`  |
| 2025-04-05       | `IntValue(0)`  |
| 2025-04-06       | `IntValue(0)`  |
| 2025-04-07       | `IntValue(N₇)` |

The four synthetic buckets carry `IntValue(0)` because `count` is additive — the typed zero correctly represents "no events that day." A line chart rendered over this series shows a flat line through the gap days rather than a discontinuity, and no consumer code is needed to pad the result. Had the measure been `FieldMeasure(aggregation: AverageAgg())` instead, the synthetic buckets would carry `NullValue` since the average of zero records is undefined.

### Streaks

`StreakMeasure` counts consecutive completion runs per entity. The result is a `TableResult` with one row per entity and four columns: `entityId` (string, group-key), `entityLabel` (string), `currentStreak` (int), `longestStreak` (int).

```dart
final query = AnalyticsQuerySpec(
  source: 'habit_logs',
  measures: const [
    StreakMeasure(
      entityIdField: FieldRef(sourceId: 'habit_logs', fieldId: 'habitId'),
      scheduledDateField: FieldRef(sourceId: 'habit_logs', fieldId: 'scheduledFor'),
      statusField: FieldRef(sourceId: 'habit_logs', fieldId: 'status'),
      completedStatusValue: 'done',
      entityLabelField: FieldRef(sourceId: 'habit_logs', fieldId: 'habitName'),
      topN: 10,
    ),
  ],
);

final result = AnalyticsExecutor.execute(
  query: query,
  records: records,
  sources: [habitLogs],
  asOf: DateTime.now(),       // required for current-streak computation
);
```

#### StreakMeasure Properties

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `entityIdField` | `FieldRef` | required | Identity field; each unique value produces one row |
| `scheduledDateField` | `FieldRef` | required | The `dateTime` field whose consecutive values define the streak axis |
| `statusField` | `FieldRef` | required | The `string`/`enumeration` field compared against `completedStatusValue` |
| `completedStatusValue` | `String` | required | The value of `statusField` that means "completed" |
| `entityLabelField` | `FieldRef?` | `null` | Optional human-readable label field. Falls back to the `entityIdField` value when null. |
| `topN` | `int?` | `null` | Optional row cap. The dropped row count is preserved as `TableResult.truncatedCount` so a renderer can show "+N more". |
| `label` | `String?` | `null` | Optional measure label |

`StreakMeasure` runs its own pipeline and ignores group-bys, sort, limit, and derived operation. The validator rejects queries that try to combine it with explicit grouping (`streakWithExplicitGrouping`) or with other measures (`streakNotCombinable`), so misuse fails fast rather than silently.

## Persistence

`AnalyticsWidgetSpec` is the persisted dashboard-widget unit. It carries identity, ordering, timestamps, and three opaque JSON payloads:

| Field | Decoded by |
|-------|------------|
| `queryJson` | `WidgetPayloadCodec.decodeQueryPayload` → `QueryPayload` |
| `displayJson` | `WidgetPayloadCodec.decodeDisplaySpec` → `DisplaySpec` |
| `dateRangeModeJson` | `WidgetPayloadCodec.decodeDateRangeMode` → `DateRangeMode` |

Storing them as opaque strings — rather than typed columns — keeps the database schema stable as the contract evolves: adding a new `Measure` case or `DerivedOperation` case is a codec change, not a schema migration.

```dart
final spec = AnalyticsWidgetSpec(
  id: 'widget-1',
  title: 'Orders by region',
  queryJson: WidgetPayloadCodec.encodeQueryPayload(SingleQuerySpec(query: query)),
  displayJson: WidgetPayloadCodec.encodeDisplaySpec(
    const DisplaySpec(displayType: 'bar'),
  ),
  dateRangeModeJson: WidgetPayloadCodec.encodeDateRangeMode(const UsePageRange()),
  sortOrder: 0,
  createdAt: DateTime.now(),
  updatedAt: DateTime.now(),
);
```

### Equality is id-based

`AnalyticsWidgetSpec`'s `==` and `hashCode` compare on `id` alone, not structurally. The spec models a persisted entity — its identity is the `id`, not the snapshot of its fields. Use `copyWith` (or re-decoding) when you need to detect content changes; comparing the JSON strings is the simplest deep-equality check.

### Schema versioning

`AnalyticsWidgetSpec.schemaVersion` allows future shape changes to be detected. Callers should invoke `WidgetPayloadCodec.ensureCanDecode(spec)` immediately after loading a spec from storage and before decoding any of its inner JSON blobs:

```dart
try {
  WidgetPayloadCodec.ensureCanDecode(spec);
} on FormatException {
  // Spec was saved by a newer app version than this codec supports.
}

final payload = WidgetPayloadCodec.decodeQueryPayload(spec.queryJson);
final display = WidgetPayloadCodec.decodeDisplaySpec(spec.displayJson);
final mode = WidgetPayloadCodec.decodeDateRangeMode(spec.dateRangeModeJson);
```

`WidgetPayloadCodec.currentSchemaVersion` (currently `1`) is the maximum version this codec can decode. Specs with `schemaVersion > currentSchemaVersion` are rejected with `FormatException`. Every codec failure is a `FormatException`, and the contract holds with value equality on every type the codec round-trips: `decode(encode(x)) == x`.

### DisplaySpec

The package is rendering-agnostic, so `DisplaySpec.displayType` is a free-form string — `'bar'`, `'line'`, `'table'`, `'pie'`, custom tokens, semantic types — all are valid. The package never inspects or interprets it. The on-disk JSON shape is intentionally minimal so future fields (axis hints, formatting, color hints) can be added without breaking existing payloads: unrecognized keys are ignored on decode.

## Caching

`SourceSnapshotCache` is a short-lived cache for normalized source records, keyed by `(sourceId, dateBound)`. Without it, every analytics widget on a dashboard runs the full "fetch records → execute" pipeline in isolation, so M widgets reading from N sources do up to `M × N` record materializations for every reload. The cache collapses this to at most `N` per cache lifetime.

```dart
final cache = SourceSnapshotCache(fetcher: myProvider.fetchRecords);

final records = await cache.getOrFetch(
  'orders',
  dateBound: (pageStart, pageEnd),
);

// When the underlying data changes:
cache.invalidate(sourceIds: {'orders'});

// Scope-less invalidation drops everything:
cache.invalidate();

// Drop all state, including in-flight fetch tracking:
cache.clear();
```

#### Key features

- **In-flight dedup** — concurrent callers for the same key share one underlying fetch. Paired queries against a single source cost one fetch, not two.
- **Frozen snapshots** — cached record lists are returned as unmodifiable views, so a caller cannot accidentally mutate the shared snapshot and poison the cache.
- **Day-aligned keys** — the date bound is normalized to the start of each bound's day, so sub-day timestamp drift and inclusive/exclusive boundary mismatches at call sites can't cause spurious misses.
- **Discard-on-completion** — in-flight fetches whose key is covered by a later `invalidate` are marked for discard; their results return to the original caller but are not committed to the cache, so the next call triggers a fresh fetch.
- **No failure caching** — if `fetcher` completes with an error, every in-flight caller sees the error and the cache stays empty for that key; subsequent calls retry.

The cache is per-page rather than global — keeps memory bounded and avoids cross-page invalidation concerns.

## Change Events

`AnalyticsChange` is a typed change event so dashboard controllers can signal listeners with enough specificity to apply targeted invalidation rules. Without a typed event, every notification looks the same and every listener has to refetch everything.

```dart
final notifier = ValueNotifier<AnalyticsChange?>(null);

// Page-level date range changed.
notifier.value = AnalyticsChange(kind: AnalyticsChangeKind.dateRange);

// A specific widget's spec was created/updated/deleted.
notifier.value = AnalyticsChange(
  kind: AnalyticsChangeKind.widgetSet,
  widgetId: 'widget-1',
);

// Underlying records mutated; scoped to specific sources.
notifier.value = AnalyticsChange(
  kind: AnalyticsChangeKind.sourceData,
  sourceIds: {'orders'},
);

// Underlying records mutated; scope unknown (treat as all sources).
notifier.value = AnalyticsChange(
  kind: AnalyticsChangeKind.sourceData,
);
```

#### AnalyticsChangeKind locked semantics

| Kind | Meaning | Required metadata |
|------|---------|-------------------|
| `dateRange` | Page-level resolved date range changed | none |
| `widgetSet` | Exactly one widget's spec changed (create/update/delete) | `widgetId` populated |
| `widgetOrder` | Pure layout reorder; no widget needs to refetch data | none |
| `sourceData` | Underlying records mutated | `sourceIds` (null = all) |
| `restore` | Single-widget restore (undo) | `widgetId` populated |

Bulk operations do not piggyback on `widgetSet` — multi-widget restore is out of scope; if it becomes a use case, add a `widgetIds: Set<String>` field rather than overloading `widgetId`.

## How It Works

1. **Validate first** — every `AnalyticsExecutor.execute` call runs `QueryValidator.validateQuery` at the top of the pipeline. The validator is pure and never throws; on failure the executor short-circuits with the typed `Err`. Downstream engines can therefore assume their inputs are well-typed.

2. **Type-check records once** — after validation, the executor walks the records once and rejects any whose `TypedValue` subtype disagrees with the declared `FieldType` on the source, returning `Err(sourceRecordTypeMismatch)`. After this pass, every downstream engine can dispatch on the declared field type without runtime sniffing.

3. **Branch by measure and grouping** — `StreakMeasure` queries take their own pipeline (no group-bys, no derived op, no sort, no limit). Other queries dispatch on `(groupBys.length, measures.length)`: no group-by with one measure → scalar; one group-by with one measure → single series; two group-bys with one measure → multi-series; one group-by with multiple measures → multi-measure series; everything else → table.

4. **Densify temporal series** — when the query uses `TimeGroupBy` and the caller supplies a `dateRange` (and `densify` is `true`), the executor walks the range bucket-by-bucket via `TimeGrainArithmetic.startOfBucket`/`nextBucketStart` and inserts synthetic empty buckets for any gap. Additive aggregations get a typed zero; non-additive get `null`. Densification is data-only and happens after aggregation, before user sort.

5. **Filter, sort, limit, then derive** — a `HavingClause` drops buckets that fail the post-aggregation threshold, then the user-requested `Sort` is applied, then `limit`. The `DerivedOperation` (cumulative sum, delta, moving average) runs last so it operates on the final ordered, capped series.

6. **Pure functions all the way down** — no engine reads wall-clock time; `asOf` and `today` are injected by the caller. The executor never throws for validation failures (those become `Err`); `StateError` is reserved for invariants the validator was expected to enforce upstream.

7. **Codec round-trip contract** — `WidgetPayloadCodec` is the only place in the package that knows the JSON shape of persisted payloads. The encoder/decoder pair is an exact inverse: `decode(encode(x)) == x` for every supported shape. Adding a new sealed case (e.g. a new `Measure` family member) means updating this codec and any consumer round-trip tests, and nothing else downstream.

## Performance

`analytics_toolkit` is an in-memory engine: aggregation, grouping, densification, and derived operations all run on whatever record list the host passes to `AnalyticsExecutor.execute`. The package ships a benchmark suite under `bench/` for measuring throughput against synthetic data; consumers running custom benchmarks against their own data can replicate the harness pattern in `bench/bench_runner.dart`. Each scenario warms up once, then runs 10 timed iterations; median, p95, and p99 wall times are reported for three record counts (10,000 / 100,000 / 1,000,000). The numbers below are an order-of-magnitude reference, not a guarantee — the provenance comments at the top capture the host environment.

<!-- BENCH:BEGIN — Paste the captured Markdown tables from `dart run bench/bench_runner.dart > bench_results.md` between the BEGIN and END markers. -->

<!-- Generated by `dart run bench/bench_runner.dart`. -->
<!-- CPU: Apple M3 Max -->
<!-- Dart: 3.12.0 (stable) -->
<!-- OS: macos Version 26.5 -->
<!-- Processors: 16 -->

## series_aggregation

| records   | median    | p95       | p99       |
| --------- | --------- | --------- | --------- |
| 10,000    | 1.7 ms    | 6.6 ms    | 7.9 ms    |
| 100,000   | 13.9 ms   | 17.8 ms   | 17.9 ms   |
| 1,000,000 | 163 ms    | 171 ms    | 173 ms    |

## multi_series_aggregation

| records   | median    | p95       | p99       |
| --------- | --------- | --------- | --------- |
| 10,000    | 1.8 ms    | 3.8 ms    | 4.0 ms    |
| 100,000   | 18.0 ms   | 19.9 ms   | 20.1 ms   |
| 1,000,000 | 198 ms    | 207 ms    | 209 ms    |

## multi_measure_aggregation

| records   | median    | p95       | p99       |
| --------- | --------- | --------- | --------- |
| 10,000    | 2.9 ms    | 7.0 ms    | 8.8 ms    |
| 100,000   | 28.9 ms   | 35.2 ms   | 36.5 ms   |
| 1,000,000 | 510 ms    | 536 ms    | 539 ms    |

## calculated_difference

| records   | median    | p95       | p99       |
| --------- | --------- | --------- | --------- |
| 10,000    | 1.9 ms    | 2.6 ms    | 2.7 ms    |
| 100,000   | 28.7 ms   | 35.4 ms   | 35.8 ms   |
| 1,000,000 | 389 ms    | 407 ms    | 409 ms    |

## calculated_nested

| records   | median    | p95       | p99       |
| --------- | --------- | --------- | --------- |
| 10,000    | 2.0 ms    | 3.5 ms    | 4.1 ms    |
| 100,000   | 30.7 ms   | 36.6 ms   | 38.3 ms   |
| 1,000,000 | 483 ms    | 504 ms    | 506 ms    |

## time_grouped_densified

| records   | median    | p95       | p99       |
| --------- | --------- | --------- | --------- |
| 10,000    | 6.9 ms    | 18.4 ms   | 18.7 ms   |
| 100,000   | 68.9 ms   | 72.2 ms   | 72.3 ms   |
| 1,000,000 | 682 ms    | 694 ms    | 696 ms    |

## time_grouped_sparse

| records   | median    | p95       | p99       |
| --------- | --------- | --------- | --------- |
| 10,000    | 6.6 ms    | 7.7 ms    | 8.3 ms    |
| 100,000   | 68.1 ms   | 72.1 ms   | 74.5 ms   |
| 1,000,000 | 682 ms    | 695 ms    | 697 ms    |

## streak

| records   | median    | p95       | p99       |
| --------- | --------- | --------- | --------- |
| 10,000    | 7.3 ms    | 11.1 ms   | 11.7 ms   |
| 100,000   | 73.6 ms   | 74.6 ms   | 74.6 ms   |
| 1,000,000 | 740 ms    | 758 ms    | 759 ms    |

## derived_cumulative_sum

| records   | median    | p95       | p99       |
| --------- | --------- | --------- | --------- |
| 10,000    | 6.7 ms    | 9.5 ms    | 10.9 ms   |
| 100,000   | 68.2 ms   | 70.8 ms   | 72.2 ms   |
| 1,000,000 | 684 ms    | 697 ms    | 699 ms    |

## derived_delta

| records   | median    | p95       | p99       |
| --------- | --------- | --------- | --------- |
| 10,000    | 6.6 ms    | 8.4 ms    | 9.2 ms    |
| 100,000   | 68.0 ms   | 68.3 ms   | 68.4 ms   |
| 1,000,000 | 688 ms    | 699 ms    | 702 ms    |

## derived_moving_average_window_7

| records   | median    | p95       | p99       |
| --------- | --------- | --------- | --------- |
| 10,000    | 6.6 ms    | 7.6 ms    | 8.0 ms    |
| 100,000   | 68.4 ms   | 73.9 ms   | 75.9 ms   |
| 1,000,000 | 685 ms    | 707 ms    | 708 ms    |


<!-- BENCH:END -->

Reading the tables above: under 10,000 records every scenario completes in single-digit milliseconds — comfortably inside a 60 Hz frame budget on the UI isolate. At 100,000 records every scenario lands in the tens of milliseconds — still UI-isolate-friendly for one-off computation, background-isolate territory when running repeatedly during scroll or animation. At 1,000,000 records simple grouping stays around 100–150 ms while time-grouped, streak, and derived-op queries land in the 600–800 ms range — background isolate. Derived operations add only a few percent of overhead on top of their underlying pipeline (cumulative sum, delta, and moving-average-7 all sit within ~2% of the bare time-grouped scenario), as expected — they run on the post-aggregation bucket list, not the full record set. The numbers above are from a high-end Apple M3 Max; older or lower-end hardware will scale up but the order-of-magnitude shape holds. If your dataset pushes meaningfully beyond these numbers, the right architectural move is to push aggregation upstream into a database layer rather than push records through the in-memory engine.

## Best Practices

**Build `SourceDef`s once at startup, not per query.** `SourceDef` is non-const because it carries a lazy field-id → `FieldDef` index for amortized O(1) lookup during execution. Constructing it per query throws away the cache.

**Always run queries through the validator before executing.** The executor does so internally, but consumers persisting user-built widgets should also call `QueryValidator.validateWidgetPayload` before save — it catches the date-range cross-rule and paired-query alignability checks that `validateQuery` alone doesn't see.

**Supply `dateRange` whenever the query uses `TimeGroupBy`.** Without it, the executor cannot densify — gaps in your data become gaps in your chart. The intended flow is `DatePresetResolver.resolveMode` → `DateRangeProjector.project` → `AnalyticsExecutor.execute` with the same resolved range passed as both the projection filter and the densification bound.

**Label measures whenever a query has more than one.** `Sort` and `HavingClause` address measures by label; with multiple measures the auto-generated `measure_<index>` labels are positional and brittle. An explicit `label` on each measure makes those references stable and readable.

**Inject `today` and `asOf` rather than reading wall-clock time.** The package never reads `DateTime.now()` itself; callers supply the reference instant so resolution and streak computation are deterministic and testable.

**Pattern-match `Result`, don't unwrap.** `Result<T, E>` exists so both branches must be handled at compile time. The `okOrNull` / `errOrNull` accessors are conveniences for one-branch early-return idioms; full pattern matching is the idiomatic Dart 3 default.

**Prefer `Result<Unit, E>` over `Result<bool, E>`.** The `true` in `Result<bool, E>` carries no meaning; with `Unit`, the success case is honest: "it worked, here is the sentinel."

**Keep records normalized at the boundary.** The executor only knows about field IDs and `TypedValue`s — it has no knowledge of the domain. Source providers should normalize once at the data layer, not per query. `SourceSnapshotCache` collapses repeated reads to at most one fetch per `(sourceId, dateBound)`.

**Use `withAdditionalFilters` instead of mutating queries.** Date-range projection, user-applied filter chips, ad-hoc drill-downs — all work by appending to an existing query without touching the persisted spec.

**Normalize records and grain anchors to UTC for DST-sensitive analytics.** All time-grain math uses Dart's `DateTime` arithmetic. DST behavior follows `DateTime` itself — if precise DST handling matters, do the conversion at the source provider boundary.

**Treat `AnalyticsErrorKind` as a closed enum at consumer boundaries.** Adding a new kind is a breaking change for any consumer that pattern-matches the full set. Defensive `default:` arms in switch statements defeat the exhaustiveness check; rely on the compiler instead.

## Modeling signed quantities

When you want a running net over time — a bank balance from deposits and withdrawals, an inventory level from items added and removed, anything where positive and negative contributions accumulate — one instinct is to negate a withdrawals series and add it to a deposits series. Series algebra now makes that expressible (`NegateOp`, or `SeriesAlgebra.combine` with `DifferenceCombination`), but for a *running net from a single source* the toolkit-idiomatic answer is simpler: put the sign in the data.

Model the source with a single `signedAmount` numeric field. Deposit-shaped events emit positive values; withdrawal-shaped events emit negative values. A single query — `sum(signedAmount)` grouped by `TimeGroupBy(month)` with `CumulativeSumOp` — produces a running balance naturally:

```dart
final transactions = SourceDef(
  sourceId: 'transactions',
  displayName: 'Transactions',
  fields: const [
    FieldDef(
      sourceId: 'transactions',
      fieldId: 'occurredAt',
      displayName: 'Date',
      fieldType: FieldType.dateTime,
      filterable: true, groupable: true,
      aggregatable: false, sortable: true,
    ),
    FieldDef(
      sourceId: 'transactions',
      fieldId: 'signedAmount',
      displayName: 'Amount',
      fieldType: FieldType.double,
      filterable: true, groupable: false,
      aggregatable: true, sortable: false,
    ),
  ],
  primaryDateFieldId: 'occurredAt',
);

// A deposit: positive amount.
final deposit = SourceRecord(fields: {
  'occurredAt': DateTimeValue(DateTime.utc(2025, 3, 12)),
  'signedAmount': const DoubleValue(150.00),
});

// A withdrawal: negative amount on the same field.
final withdrawal = SourceRecord(fields: {
  'occurredAt': DateTimeValue(DateTime.utc(2025, 3, 18)),
  'signedAmount': const DoubleValue(-42.50),
});

final runningBalance = AnalyticsQuerySpec(
  source: 'transactions',
  measures: const [
    FieldMeasure(
      fieldRef: FieldRef(sourceId: 'transactions', fieldId: 'signedAmount'),
      aggregation: SumAgg(),
    ),
  ],
  groupBys: [
    TimeGroupBy(
      dateFieldRef: const FieldRef(sourceId: 'transactions', fieldId: 'occurredAt'),
      grain: TimeGrain.month,
    ),
  ],
  derivedOperation: const CumulativeSumOp(),
);
```

The resulting `SeriesResult` has one bucket per month, each carrying the running total of all transactions up to and including that month. For example, if January nets +500.00, February nets −175.00, and March nets +107.50, the series reads `Jan: +500.00`, `Feb: +325.00`, `Mar: +432.50`. Withdrawals lower the running total because their `signedAmount` is negative; deposits raise it. If you also want to chart deposits and withdrawals as separate series, filter on `signedAmount > 0` for one query and `signedAmount < 0` for the other — same source, same field, two queries.

The alternative shape — two record types, one for each direction — pushes the combine work out of the typed-query layer and into consumer code. If you do start from two separate series, `SeriesAlgebra.combine` can align and fold them by bucket key after the fact (see [Series algebra](#series-algebra)); but folding the sign into the record is cheaper still, keeping every running-net derivation expressible as one query against one source, and the same pattern handles non-monetary "running net" use cases unchanged.

The pattern generalizes: any "running net" use case becomes "single record type with a signed numeric field." The work happens at the source-provider boundary, where the host normalizes input data anyway, and the package's symmetric agnosticism stays intact.

## What's Not Included

This package is rendering-agnostic. Its types do not depend on any chart library or UI toolkit.

Explicit limitations, set early so evaluators know the scope:

- **No `OR` filter combinator.** Record-level filters are AND-combined. (Post-aggregation bucket filtering is available via `HavingClause`.)
- **No JOINs across sources.** Each query runs against exactly one source.
- **No group-by beyond three levels.** A query carries up to three group-by clauses, with at most one of them temporal.
- **No more than five measures per query.** Beyond that, or for paired numerator/denominator displays, use `PairedQuerySpec`.
- **No built-in source adapters.** By design — see the Design philosophy section. The host normalizes its data into `SourceRecord` form at whichever boundary suits its domain.

## License

MIT License — see [LICENSE](LICENSE) for details.

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.