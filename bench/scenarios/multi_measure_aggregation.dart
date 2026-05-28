// Scenario 6: count + sum + average + max over a 10-valued enum field,
// applied to a `double amount` field. Exercises the multi-measure
// aggregation path — the executor builds one aggregator closure per
// measure and walks each bucket's records exactly once, so the cost
// scales as N closures per bucket rather than N record-walks. Produces
// a `MultiMeasureSeriesResult` per the (1 groupBy, N measures)
// dispatch.

import 'dart:math';

import 'package:analytics_toolkit/analytics_toolkit.dart';

import '../bench_runner.dart';

const _seed = 0xF8A4D2; // deterministic across runs

const _categoryCount = 10;

/// Source: `category` enum (10 values, groupable) plus `amount` double
/// (aggregatable). The amount field is the substrate for sum, average,
/// and max; count ignores it.
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
      fieldId: 'amount',
      displayName: 'Amount',
      fieldType: FieldType.double,
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
  final categories = [
    for (var i = 0; i < _categoryCount; i++) EnumValue('cat_$i'),
  ];
  final records = <SourceRecord>[];
  for (var i = 0; i < count; i++) {
    records.add(
      SourceRecord(
        fields: {
          'category': categories[rng.nextInt(_categoryCount)],
          'amount': DoubleValue(rng.nextDouble() * 1000.0),
        },
      ),
    );
  }
  return records;
}

/// Four measures over the same `amount` field plus a count. The mix is
/// deliberate:
///
/// * `CountMeasure`                 — no-field branch.
/// * `FieldMeasure` + `SumAgg`      — additive output.
/// * `FieldMeasure` + `AverageAgg`  — non-additive, empty-group-null path.
/// * `FieldMeasure` + `MaxAgg`      — ordered output.
///
/// Labels are left null on all four so the executor's auto-label rule
/// (`measure_0..measure_3` via `Measure.effectiveLabelsFor`) is what
/// gets exercised — the path most consumers hit by default.
AnalyticsQuerySpec _buildQuery() {
  const amount = FieldRef(sourceId: 'records', fieldId: 'amount');
  return AnalyticsQuerySpec(
    source: 'records',
    measures: const [
      CountMeasure(),
      FieldMeasure(fieldRef: amount, aggregation: SumAgg()),
      FieldMeasure(fieldRef: amount, aggregation: AverageAgg()),
      FieldMeasure(fieldRef: amount, aggregation: MaxAgg()),
    ],
    groupBys: const [
      FieldGroupBy(
        fieldRef: FieldRef(sourceId: 'records', fieldId: 'category'),
      ),
    ],
  );
}

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
