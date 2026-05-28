// Scenario 4: streak computation over per-entity daily check-in
// records. Exercises the dedicated streak executor pipeline, which is
// a separate branch from the grouping/aggregation pipeline.
//
// Record shape per the streak contract: one row per (entityId,
// scheduledDate). The status field is "done" for a completed day,
// "missed" for an unfilled scheduled day.
//
// Each entity carries one full calendar year (365 days) of daily
// check-ins; entity count is the variable dimension and scales with
// `recordCount`. At ~100,000 records this corresponds to roughly 250
// entities; smaller and larger record counts span proportionally
// fewer or more entities, with each entity still carrying one full
// year.

import 'dart:math';

import 'package:analytics_toolkit/analytics_toolkit.dart';

import '../bench_runner.dart';

const _seed = 0xD4F3C7; // deterministic across runs

const _daysPerEntity = 365;
const _completionProbability = 0.7;

// Reference start date for scheduled-day generation. UTC, day-truncated
// — matches the StreakCalculator input contract that all dates be
// day-truncated to local midnight.
final _scheduleStart = DateTime.utc(2025, 1, 1);

/// Source: `entityId` (string, the streak's identity dimension),
/// `scheduledFor` (dateTime), `status` (enumeration).
SourceDef _buildSource() => SourceDef(
  sourceId: 'habit_logs',
  displayName: 'Habit Logs',
  fields: const [
    FieldDef(
      sourceId: 'habit_logs',
      fieldId: 'entityId',
      displayName: 'Entity ID',
      fieldType: FieldType.string,
      filterable: true,
      groupable: true,
      aggregatable: false,
      sortable: true,
    ),
    FieldDef(
      sourceId: 'habit_logs',
      fieldId: 'scheduledFor',
      displayName: 'Scheduled For',
      fieldType: FieldType.dateTime,
      filterable: true,
      groupable: true,
      aggregatable: false,
      sortable: true,
    ),
    FieldDef(
      sourceId: 'habit_logs',
      fieldId: 'status',
      displayName: 'Status',
      fieldType: FieldType.enumeration,
      filterable: true,
      groupable: true,
      aggregatable: false,
      sortable: true,
    ),
  ],
);

List<SourceRecord> _generateRecords(int totalCount) {
  // Scale entity count to approximately hit totalCount. Rounding to
  // the nearest whole entity may leave the actual record count a few
  // percent shy of (or over) the requested count — fine for
  // benchmarking, where the order of magnitude is what matters and
  // the table's "records" column is a label, not a measurement.
  final entityCount = (totalCount / _daysPerEntity).round();

  final rng = Random(_seed);
  const done = EnumValue('done');
  const missed = EnumValue('missed');

  final records = <SourceRecord>[];
  for (var e = 0; e < entityCount; e++) {
    final entityIdValue = StringValue('entity_$e');
    for (var d = 0; d < _daysPerEntity; d++) {
      final scheduledFor = _scheduleStart.add(Duration(days: d));
      final status = rng.nextDouble() < _completionProbability ? done : missed;
      records.add(
        SourceRecord(
          fields: {
            'entityId': entityIdValue,
            'scheduledFor': DateTimeValue(scheduledFor),
            'status': status,
          },
        ),
      );
    }
  }
  return records;
}

AnalyticsQuerySpec _buildQuery() => AnalyticsQuerySpec(
  source: 'habit_logs',
  measures: const [
    StreakMeasure(
      entityIdField: FieldRef(sourceId: 'habit_logs', fieldId: 'entityId'),
      scheduledDateField: FieldRef(
        sourceId: 'habit_logs',
        fieldId: 'scheduledFor',
      ),
      statusField: FieldRef(sourceId: 'habit_logs', fieldId: 'status'),
      completedStatusValue: 'done',
    ),
  ],
);

Future<BenchResult> run({required int recordCount}) async {
  final source = _buildSource();
  final records = _generateRecords(recordCount);
  final query = _buildQuery();
  // `asOf` is required by StreakMeasure. Pin it deterministically just
  // past the longest possible scheduled date so every scheduled day is
  // "in the past" relative to the streak walk.
  final asOf = _scheduleStart.add(const Duration(days: 100000));
  return timeRuns(() {
    requireOk(
      AnalyticsExecutor.execute(
        query: query,
        records: records,
        sources: [source],
        asOf: asOf,
      ),
    );
  });
}
