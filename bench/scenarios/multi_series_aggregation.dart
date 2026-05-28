// Scenario 2: scenario 1 plus a second `GroupBy` on a second enum
// field with 5 distinct values. Exercises the two-level grouping path
// that produces a `MultiSeriesResult`.

import 'dart:math';

import 'package:analytics_toolkit/analytics_toolkit.dart';

import '../bench_runner.dart';

const _seed = 0xB2EC2A; // deterministic across runs

const _categoryCount = 10;
const _regionCount = 5;

/// Source: a `category` enum (10 values) and a `region` enum (5 values).
/// Both groupable so both group-by clauses validate.
SourceDef _buildSource() => SourceDef(
  sourceId: 'records',
  displayName: 'Records',
  fields: const [
    FieldDef(
      sourceId: 'records',
      fieldId: 'category',
      displayName: 'Category',
      fieldType: FieldType.enumeration,
      filterable: true,
      groupable: true,
      aggregatable: false,
      sortable: true,
    ),
    FieldDef(
      sourceId: 'records',
      fieldId: 'region',
      displayName: 'Region',
      fieldType: FieldType.enumeration,
      filterable: true,
      groupable: true,
      aggregatable: false,
      sortable: true,
    ),
  ],
);

List<SourceRecord> _generateRecords(int count) {
  final rng = Random(_seed);
  final categories = [
    for (var i = 0; i < _categoryCount; i++) EnumValue('cat_$i'),
  ];
  final regions = [for (var i = 0; i < _regionCount; i++) EnumValue('r_$i')];
  final records = <SourceRecord>[];
  for (var i = 0; i < count; i++) {
    records.add(
      SourceRecord(
        fields: {
          'category': categories[rng.nextInt(_categoryCount)],
          'region': regions[rng.nextInt(_regionCount)],
        },
      ),
    );
  }
  return records;
}

AnalyticsQuerySpec _buildQuery() => AnalyticsQuerySpec(
  source: 'records',
  measures: const [CountMeasure()],
  groupBys: const [
    FieldGroupBy(
      fieldRef: FieldRef(sourceId: 'records', fieldId: 'category'),
    ),
    FieldGroupBy(
      fieldRef: FieldRef(sourceId: 'records', fieldId: 'region'),
    ),
  ],
);

Future<BenchResult> run({required int recordCount}) async {
  final source = _buildSource();
  final records = _generateRecords(recordCount);
  final query = _buildQuery();
  return timeRuns(() {
    requireOk(
      AnalyticsExecutor.execute(
        query: query,
        records: records,
        sources: [source],
      ),
    );
  });
}
