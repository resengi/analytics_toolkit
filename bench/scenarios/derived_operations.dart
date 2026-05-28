// Scenario 5: derived operations applied to scenario 3's pipeline.
//
// Same time-grouped, densified `CountMeasure` setup as
// `time_grouped_densified.dart`, but with a `derivedOperation` set on
// the query. Three sub-benchmarks, one per derived op:
//
//   * runCumulativeSum   — CumulativeSumOp
//   * runDelta           — DeltaOp
//   * runMovingAverage   — MovingAverageOp(window: 7)
//
// The point is to confirm the derived ops add negligible overhead to
// the underlying pipeline (they run on the post-aggregation bucket
// list — 12 buckets here, regardless of `recordCount`).

import 'dart:math';

import 'package:analytics_toolkit/analytics_toolkit.dart';

import '../bench_runner.dart';

const _seed = 0xE5BC91; // deterministic across runs

final _yearStart = DateTime.utc(2025, 1, 1);
final _yearEnd = DateTime.utc(2026, 1, 1);

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
    final offsetMicros = (rng.nextDouble() * spanMicros).floor();
    final occurredAt = _yearStart.add(Duration(microseconds: offsetMicros));
    records.add(
      SourceRecord(fields: {'occurredAt': DateTimeValue(occurredAt)}),
    );
  }
  return records;
}

AnalyticsQuerySpec _buildQuery({required DerivedOperation derivedOp}) {
  return AnalyticsQuerySpec(
    source: 'events',
    measures: const [CountMeasure()],
    groupBys: [
      TimeGroupBy(
        dateFieldRef: const FieldRef(sourceId: 'events', fieldId: 'occurredAt'),
        grain: TimeGrain.month,
      ),
    ],
    derivedOperation: derivedOp,
  );
}

Future<BenchResult> _runWith({
  required int recordCount,
  required DerivedOperation derivedOp,
}) async {
  final source = _buildSource();
  final records = _generateRecords(recordCount);
  final query = _buildQuery(derivedOp: derivedOp);
  final dateRange = (_yearStart, _yearEnd);
  return timeRuns(() {
    requireOk(
      AnalyticsExecutor.execute(
        query: query,
        records: records,
        sources: [source],
        dateRange: dateRange,
      ),
    );
  });
}

Future<BenchResult> runCumulativeSum({required int recordCount}) =>
    _runWith(recordCount: recordCount, derivedOp: const CumulativeSumOp());

Future<BenchResult> runDelta({required int recordCount}) =>
    _runWith(recordCount: recordCount, derivedOp: const DeltaOp());

Future<BenchResult> runMovingAverage({required int recordCount}) => _runWith(
  recordCount: recordCount,
  derivedOp: const MovingAverageOp(window: 7),
);
