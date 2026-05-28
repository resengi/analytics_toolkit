# analytics_toolkit — example

A runnable tour of `analytics_toolkit`. Each section builds a small
in-memory dataset, runs a query, and prints the typed result, moving
from the simplest case through the time-series pipeline, derived
operations, streaks, validation, and persistence.

## What it demonstrates

1. **Basic series** — a `CountMeasure` grouped by a categorical field
   (`SeriesResult`).
2. **Multi-measure** — `count` + `SumAgg` + `AverageAgg` against one
   group-by (`MultiMeasureSeriesResult`), with explicit measure labels.
3. **Filter, sort, and limit** — a record-level `Filter`, a
   `MeasureValueSort`, and a `limit`.
4. **HAVING** — bucket-level filtering after aggregation with a
   `HavingClause`.
5. **Two group-bys** — a primary and secondary dimension
   (`MultiSeriesResult`).
6. **Time-grouped + densified** — a `TimeGroupBy` at day grain over a
   `dateRange`, with synthetic zero-count buckets filling the gaps.
7. **Derived operation** — `CumulativeSumOp` applied to the
   time-grouped series.
8. **Streak** — `StreakMeasure` over per-entity daily logs
   (`TableResult`).
9. **Column aliasing** — `GroupBy.label`, including the
   `duplicateColumnLabel` validation error and how an alias resolves
   it.
10. **Codec round-trip** — encoding a query to JSON with
    `WidgetPayloadCodec` and decoding it back.

It also includes a small `_printResult` helper that dispatches over all
five `AnalyticsResult` shapes — the kind of presentation glue a host
application writes once.

## Running

From this directory:

```
dart pub get
dart run lib/main.dart
```

To run a single section, pass its number:

```
dart run lib/main.dart 5
```

## Expected output

The tour prints a header for each section followed by its result. The
first two sections look like this:

```
━━━ 1. Basic series — count tasks by status ━━━

  done         → 5
  in_progress  → 1
  todo         → 3

━━━ 2. Multi-measure — count + sum + average per group ━━━

               | count          | priority_sum   | avg_estimate
  done         | 5              | 11             | 2.20
  in_progress  | 1              | 3              | 6.00
  todo         | 3              | 6              | 4.83
```

Section 6 shows densification filling empty days with synthetic
zero-count buckets, and section 7 shows those synthetic markers
surviving the cumulative-sum transform:

```
━━━ 6. Time-grouped + densified — events per day ━━━

  2026-01-05   → 2
  2026-01-06   → 0 (synthetic)
  2026-01-07   → 3
  2026-01-08   → 3
  2026-01-09   → 0 (synthetic)
```