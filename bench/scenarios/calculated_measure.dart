// Scenario 7: in-query calculated measures over a 10-valued enum field.
//
// Exercises the expression-measure path the executor takes when a
// measure is a `CalculatedMeasure` tree rather than a leaf aggregation.
// Each operand compiles to its own aggregator closure, so the executor
// walks every group's records once per leaf operand and folds the
// operand values per bucket. Two entry points isolate how that cost
// scales with operand count:
//
//   * runDifference — `revenue - cost`: two leaf operands (two sums),
//                     one fold per bucket. The headline calculated
//                     measure; output stays integer.
//   * runNested     — `(revenue - cost) / revenue`: three leaf operands
//                     across a two-level tree, two folds per bucket.
//                     Output is a unitless double.
//
// Both group by the same 10-valued enum as `multi_measure_aggregation`,
// so the two scenarios are directly comparable: that one runs N
// independent measures as separate columns, while this one folds
// several operands into a single measure column.

import 'dart:math';

import 'package:analytics_toolkit/analytics_toolkit.dart';

import '../bench_runner.dart';

const _seed = 0xCA1C42; // deterministic across runs

const _categoryCount = 10;

/// Source: `region` enum (10 values, groupable) plus two aggregatable
/// integer fields, `revenue` and `cost`, that the calculated measures
/// fold together.
SourceDef _buildSource() => SourceDef(
  sourceId: 'records',
  displayName: 'Records',
  fields: const [
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
    FieldDef(
      sourceId: 'records',
      fieldId: 'revenue',
      displayName: 'Revenue',
      fieldType: FieldType.integer,
      filterable: true,
      groupable: false,
      aggregatable: true,
      sortable: true,
    ),
    FieldDef(
      sourceId: 'records',
      fieldId: 'cost',
      displayName: 'Cost',
      fieldType: FieldType.integer,
      filterable: true,
      groupable: false,
      aggregatable: true,
      sortable: true,
    ),
  ],
);

List<SourceRecord> _generateRecords(int count) {
  final rng = Random(_seed);
  // Pre-build the EnumValue instances so generation isn't dominated by
  // allocation of identical-string EnumValues.
  final regions = [
    for (var i = 0; i < _categoryCount; i++) EnumValue('region_$i'),
  ];
  final records = <SourceRecord>[];
  for (var i = 0; i < count; i++) {
    records.add(
      SourceRecord(
        fields: {
          'region': regions[rng.nextInt(_categoryCount)],
          'revenue': IntValue(rng.nextInt(1000)),
          'cost': IntValue(rng.nextInt(800)),
        },
      ),
    );
  }
  return records;
}

FieldMeasure _sum(String field) => FieldMeasure(
  fieldRef: FieldRef(sourceId: 'records', fieldId: field),
  aggregation: const SumAgg(),
);

AnalyticsQuerySpec _buildQuery(Measure measure) => AnalyticsQuerySpec(
  source: 'records',
  measures: [measure],
  groupBys: const [
    FieldGroupBy(
      fieldRef: FieldRef(sourceId: 'records', fieldId: 'region'),
    ),
  ],
);

Future<BenchResult> _runWith({
  required int recordCount,
  required Measure measure,
}) async {
  final source = _buildSource();
  final records = _generateRecords(recordCount);
  final query = _buildQuery(measure);
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

/// `revenue - cost`: two leaf sums folded once per bucket.
Future<BenchResult> runDifference({required int recordCount}) => _runWith(
  recordCount: recordCount,
  measure: CalculatedMeasure(
    operandA: _sum('revenue'),
    operandB: _sum('cost'),
    combination: const DifferenceCombination(),
  ),
);

/// `(revenue - cost) / revenue`: three leaf sums across a two-level
/// tree, two folds per bucket.
Future<BenchResult> runNested({required int recordCount}) => _runWith(
  recordCount: recordCount,
  measure: CalculatedMeasure(
    operandA: CalculatedMeasure(
      operandA: _sum('revenue'),
      operandB: _sum('cost'),
      combination: const DifferenceCombination(),
    ),
    operandB: _sum('revenue'),
    combination: const RatioCombination(),
  ),
);
