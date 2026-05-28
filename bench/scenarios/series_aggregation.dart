// Scenario 1: count records grouped by a 10-valued enum field.
// Baseline single-series aggregation; exercises the grouping engine
// over a categorical dimension with no time-series machinery.

import 'dart:math';

import 'package:analytics_toolkit/analytics_toolkit.dart';

import '../bench_runner.dart';

const _seed = 0xA17AB1; // deterministic across runs

const _categoryCount = 10;

/// Source: a single enum field `category` with 10 distinct values
/// `cat_0..cat_9`. Marked groupable so `FieldGroupBy` validates.
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
  ],
);

List<SourceRecord> _generateRecords(int count) {
  final rng = Random(_seed);
  // Pre-build the EnumValue instances so generation isn't dominated by
  // allocation of identical-string EnumValues.
  final categories = [
    for (var i = 0; i < _categoryCount; i++) EnumValue('cat_$i'),
  ];
  final records = <SourceRecord>[];
  for (var i = 0; i < count; i++) {
    records.add(
      SourceRecord(
        fields: {'category': categories[rng.nextInt(_categoryCount)]},
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
