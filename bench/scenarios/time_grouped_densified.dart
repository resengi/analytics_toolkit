// Scenario 3: count records grouped by month over a one-year window.
// Two entry points exercise the time-bucket pipeline in its two
// densification modes:
//
//   * `run`       — `densify: true` (default), `dateRange` supplied.
//                   The full densification pass runs: cross-product
//                   over observed keys plus time-axis extension to
//                   every grain-aligned bucket in the range.
//   * `runSparse` — `densify: false`, `dateRange` omitted. Only
//                   observed buckets are emitted; no cross-product,
//                   no time-axis extension, no synthetic-tracking
//                   bookkeeping. The path non-chart consumers (CSV
//                   export, raw aggregation pipelines) take when they
//                   want sparse data.
//
// At the bench's record counts the input is dense enough that every
// month gets at least one record, so both paths produce 12 cells.
// The median delta therefore attributes cleanly to the densification
// engine's work rather than to a difference in output size.

import 'dart:math';

import 'package:analytics_toolkit/analytics_toolkit.dart';

import '../bench_runner.dart';

const _seed = 0xC3D7E4; // deterministic across runs

// Fixed reference year so the bench is reproducible across machines
// and dates. UTC throughout; the engine takes whatever the records
// supply.
final _yearStart = DateTime.utc(2025, 1, 1);
final _yearEnd = DateTime.utc(2026, 1, 1);

/// Source: a single `occurredAt` dateTime field. Declared as the
/// `primaryDateFieldId` because the README's intended pattern is that
/// time-grouped queries run against the source's primary date field.
SourceDef _buildSource() => SourceDef(
  sourceId: 'events',
  displayName: 'Events',
  fields: const [
    FieldDef(
      sourceId: 'events',
      fieldId: 'occurredAt',
      displayName: 'Occurred At',
      fieldType: FieldType.dateTime,
      filterable: true,
      groupable: true,
      aggregatable: false,
      sortable: true,
    ),
  ],
  primaryDateFieldId: 'occurredAt',
);

List<SourceRecord> _generateRecords(int count) {
  final rng = Random(_seed);
  final spanMicros = _yearEnd.difference(_yearStart).inMicroseconds;
  final records = <SourceRecord>[];
  for (var i = 0; i < count; i++) {
    // `nextInt` is capped at 2^32, well above a year in microseconds
    // (~3.15e13) only when we'd care about microsecond precision; for
    // benchmark-scale uniformity, multiplying a uniform double is fine.
    final offsetMicros = (rng.nextDouble() * spanMicros).floor();
    final occurredAt = _yearStart.add(Duration(microseconds: offsetMicros));
    records.add(
      SourceRecord(fields: {'occurredAt': DateTimeValue(occurredAt)}),
    );
  }
  return records;
}

AnalyticsQuerySpec _buildQuery() => AnalyticsQuerySpec(
  source: 'events',
  measures: const [CountMeasure()],
  groupBys: [
    TimeGroupBy(
      dateFieldRef: const FieldRef(sourceId: 'events', fieldId: 'occurredAt'),
      grain: TimeGrain.month,
    ),
  ],
);

Future<BenchResult> _runWith({
  required int recordCount,
  required bool densify,
}) async {
  final source = _buildSource();
  final records = _generateRecords(recordCount);
  final query = _buildQuery();
  return timeRuns(() {
    requireOk(
      AnalyticsExecutor.execute(
        query: query,
        records: records,
        sources: [source],
        // `dateRange` is meaningful only when densifying — the
        // executor ignores it on the sparse path. We pass it on the
        // dense path so the full one-year time axis is materialized;
        // we omit it on the sparse path so the bench's call shape
        // matches what a real sparse-path consumer would write.
        dateRange: densify ? (_yearStart, _yearEnd) : null,
        densify: densify,
      ),
    );
  });
}

Future<BenchResult> run({required int recordCount}) =>
    _runWith(recordCount: recordCount, densify: true);

Future<BenchResult> runSparse({required int recordCount}) =>
    _runWith(recordCount: recordCount, densify: false);
