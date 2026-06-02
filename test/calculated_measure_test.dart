import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:test/test.dart';

import '_fixtures.dart';

/// Behavioral tests for expression measures evaluated inside a query:
/// `CalculatedMeasure` folds two operands per bucket, `TransformedMeasure`
/// applies a per-value op, and both compose with each other and with a
/// `derivedOperation`. Because both operands of a calculation are
/// aggregated over the same bucket's records, they are inherently
/// aligned — these tests confirm the fold, the output types, the
/// synthetic-bucket behavior, and the supported result shapes.
void main() {
  /// Two numeric fields (`revenue`, `cost`) and two durations
  /// (`spanA`, `spanB`) over a categorical `region` and a temporal
  /// `month`, so a single query can combine two measures over a shared
  /// grouping.
  SourceDef financeSource() => SourceDef(
    sourceId: 'finance',
    displayName: 'Finance',
    fields: const [
      FieldDef(
        sourceId: 'finance',
        fieldId: 'month',
        displayName: 'Month',
        fieldType: FieldType.dateTime,
        filterable: true,
        groupable: true,
        aggregatable: false,
        sortable: true,
      ),
      FieldDef(
        sourceId: 'finance',
        fieldId: 'region',
        displayName: 'Region',
        fieldType: FieldType.enumeration,
        filterable: true,
        groupable: true,
        aggregatable: false,
        sortable: true,
      ),
      FieldDef(
        sourceId: 'finance',
        fieldId: 'revenue',
        displayName: 'Revenue',
        fieldType: FieldType.integer,
        filterable: true,
        groupable: false,
        aggregatable: true,
        sortable: true,
      ),
      FieldDef(
        sourceId: 'finance',
        fieldId: 'cost',
        displayName: 'Cost',
        fieldType: FieldType.integer,
        filterable: true,
        groupable: false,
        aggregatable: true,
        sortable: true,
      ),
      FieldDef(
        sourceId: 'finance',
        fieldId: 'spanA',
        displayName: 'Span A',
        fieldType: FieldType.duration,
        filterable: true,
        groupable: false,
        aggregatable: true,
        sortable: true,
      ),
      FieldDef(
        sourceId: 'finance',
        fieldId: 'spanB',
        displayName: 'Span B',
        fieldType: FieldType.duration,
        filterable: true,
        groupable: false,
        aggregatable: true,
        sortable: true,
      ),
    ],
    primaryDateFieldId: 'month',
  );

  final finance = financeSource();

  SourceRecord row({
    required String region,
    required int revenue,
    required int cost,
    Duration spanA = Duration.zero,
    Duration spanB = Duration.zero,
    DateTime? month,
  }) => SourceRecord(
    fields: {
      'region': EnumValue(region),
      'revenue': IntValue(revenue),
      'cost': IntValue(cost),
      'spanA': DurationValue(spanA),
      'spanB': DurationValue(spanB),
      if (month != null) 'month': DateTimeValue(month),
    },
  );

  /// North sums to revenue 120 / cost 70 / spanA 15m / spanB 5m; south
  /// to revenue 50 / cost 70 / spanA 3m / spanB 9m.
  List<SourceRecord> regionRecords() => [
    row(
      region: 'north',
      revenue: 100,
      cost: 60,
      spanA: const Duration(minutes: 10),
      spanB: const Duration(minutes: 4),
    ),
    row(
      region: 'north',
      revenue: 20,
      cost: 10,
      spanA: const Duration(minutes: 5),
      spanB: const Duration(minutes: 1),
    ),
    row(
      region: 'south',
      revenue: 50,
      cost: 70,
      spanA: const Duration(minutes: 3),
      spanB: const Duration(minutes: 9),
    ),
  ];

  FieldMeasure sum(String field, {String? label}) => FieldMeasure(
    fieldRef: ref('finance', field),
    aggregation: const SumAgg(),
    label: label,
  );

  AnalyticsResult run(
    List<Measure> measures, {
    List<GroupBy> groupBys = const [],
    DerivedOperation derived = const NoDerivedOp(),
    List<SourceRecord>? records,
    (DateTime, DateTime)? dateRange,
  }) {
    final r = AnalyticsExecutor.execute(
      query: AnalyticsQuerySpec(
        source: 'finance',
        measures: measures,
        groupBys: groupBys,
        derivedOperation: derived,
      ),
      records: records ?? regionRecords(),
      sources: [finance],
      dateRange: dateRange,
    );
    expect(r.isOk, isTrue, reason: r.errOrNull?.humanMessage);
    return r.okOrNull!;
  }

  SeriesResult runByRegion(
    Measure m, {
    DerivedOperation derived = const NoDerivedOp(),
  }) =>
      run(
            [m],
            groupBys: [FieldGroupBy(fieldRef: ref('finance', 'region'))],
            derived: derived,
          )
          as SeriesResult;

  /// Series values keyed by region label.
  Map<String, TypedValue?> byRegion(SeriesResult s) => {
    for (final b in s.buckets) (b.key as EnumBucketKey).value: b.value,
  };

  int? asInt(TypedValue? v) => (v as IntValue?)?.value;
  double? asDouble(TypedValue? v) => (v as DoubleValue?)?.value;
  Duration? asDuration(TypedValue? v) => (v as DurationValue?)?.value;

  group('calculated measure folds per bucket', () {
    test('difference of two integer sums stays integer', () {
      final s = runByRegion(
        CalculatedMeasure(
          operandA: sum('revenue'),
          operandB: sum('cost'),
          combination: const DifferenceCombination(),
        ),
      );
      expect(s.measureFieldType, FieldType.integer);
      final v = byRegion(s);
      expect(asInt(v['north']), 50);
      expect(asInt(v['south']), -20);
    });

    test('sum of two integer sums stays integer', () {
      final s = runByRegion(
        CalculatedMeasure(
          operandA: sum('revenue'),
          operandB: sum('cost'),
          combination: const SumCombination(),
        ),
      );
      expect(s.measureFieldType, FieldType.integer);
      final v = byRegion(s);
      expect(asInt(v['north']), 190);
      expect(asInt(v['south']), 120);
    });

    test('product yields a unitless double', () {
      final s = runByRegion(
        CalculatedMeasure(
          operandA: sum('revenue'),
          operandB: sum('cost'),
          combination: const ProductCombination(),
        ),
      );
      expect(s.measureFieldType, FieldType.double);
      final v = byRegion(s);
      expect(asDouble(v['north']), 8400.0);
      expect(asDouble(v['south']), 3500.0);
    });

    test('ratio yields a unitless double', () {
      final s = runByRegion(
        CalculatedMeasure(
          operandA: sum('revenue'),
          operandB: sum('cost'),
          combination: const RatioCombination(),
        ),
      );
      expect(s.measureFieldType, FieldType.double);
      final v = byRegion(s);
      expect(asDouble(v['north']), closeTo(120 / 70, 1e-9));
      expect(asDouble(v['south']), closeTo(50 / 70, 1e-9));
    });

    test('ratio with a zero denominator yields null at that bucket', () {
      // West's cost sums to zero, so revenue / cost is undefined there.
      final s =
          run(
                [
                  CalculatedMeasure(
                    operandA: sum('revenue'),
                    operandB: sum('cost'),
                    combination: const RatioCombination(),
                  ),
                ],
                groupBys: [FieldGroupBy(fieldRef: ref('finance', 'region'))],
                records: [
                  row(region: 'north', revenue: 120, cost: 70),
                  row(region: 'west', revenue: 5, cost: 0),
                ],
              )
              as SeriesResult;
      final v = byRegion(s);
      expect(asDouble(v['north']), closeTo(120 / 70, 1e-9));
      expect(v['west'], isNull);
    });

    test('duration difference stays a duration', () {
      final s = runByRegion(
        CalculatedMeasure(
          operandA: sum('spanA'),
          operandB: sum('spanB'),
          combination: const DifferenceCombination(),
        ),
      );
      expect(s.measureFieldType, FieldType.duration);
      final v = byRegion(s);
      expect(asDuration(v['north']), const Duration(minutes: 10));
      expect(asDuration(v['south']), const Duration(minutes: -6));
    });
  });

  group('expression composition', () {
    test('nested (revenue − cost) / revenue', () {
      final s = runByRegion(
        CalculatedMeasure(
          operandA: CalculatedMeasure(
            operandA: sum('revenue'),
            operandB: sum('cost'),
            combination: const DifferenceCombination(),
          ),
          operandB: sum('revenue'),
          combination: const RatioCombination(),
        ),
      );
      expect(s.measureFieldType, FieldType.double);
      final v = byRegion(s);
      expect(asDouble(v['north']), closeTo(50 / 120, 1e-9));
      expect(asDouble(v['south']), closeTo(-20 / 50, 1e-9));
    });

    test('a transformed measure as an operand', () {
      // (−cost) + revenue equals revenue − cost.
      final s = runByRegion(
        CalculatedMeasure(
          operandA: TransformedMeasure(
            operand: sum('cost'),
            op: const NegateOp(),
          ),
          operandB: sum('revenue'),
          combination: const SumCombination(),
        ),
      );
      expect(s.measureFieldType, FieldType.integer);
      final v = byRegion(s);
      expect(asInt(v['north']), 50);
      expect(asInt(v['south']), -20);
    });

    test('fill-null operands feed a cumulative-sum chain', () {
      // Sums are never null, so fill-null is a no-op here; the chain
      // must still validate and produce the running net by month.
      final s =
          run(
                [
                  CalculatedMeasure(
                    operandA: TransformedMeasure(
                      operand: sum('revenue'),
                      op: const FillNullOp(0),
                    ),
                    operandB: TransformedMeasure(
                      operand: sum('cost'),
                      op: const FillNullOp(0),
                    ),
                    combination: const DifferenceCombination(),
                  ),
                ],
                groupBys: [
                  TimeGroupBy(
                    dateFieldRef: ref('finance', 'month'),
                    grain: TimeGrain.day,
                  ),
                ],
                derived: const CumulativeSumOp(),
                records: [
                  row(
                    region: 'north',
                    revenue: 100,
                    cost: 60,
                    month: DateTime(2026, 5, 1),
                  ),
                  row(
                    region: 'north',
                    revenue: 50,
                    cost: 70,
                    month: DateTime(2026, 5, 2),
                  ),
                ],
                dateRange: (DateTime(2026, 5, 1), DateTime(2026, 5, 3)),
              )
              as SeriesResult;
      expect(s.buckets.map((b) => asInt(b.value)).toList(), [40, 20]);
    });
  });

  group('result shapes', () {
    test('single calculated measure over a month axis is a series', () {
      final s =
          run(
                [
                  CalculatedMeasure(
                    operandA: sum('revenue'),
                    operandB: sum('cost'),
                    combination: const DifferenceCombination(),
                  ),
                ],
                groupBys: [
                  TimeGroupBy(
                    dateFieldRef: ref('finance', 'month'),
                    grain: TimeGrain.day,
                  ),
                ],
                records: [
                  row(
                    region: 'north',
                    revenue: 100,
                    cost: 60,
                    month: DateTime(2026, 5, 1),
                  ),
                  row(
                    region: 'north',
                    revenue: 50,
                    cost: 70,
                    month: DateTime(2026, 5, 2),
                  ),
                ],
                dateRange: (DateTime(2026, 5, 1), DateTime(2026, 5, 3)),
              )
              as SeriesResult;
      expect(s.buckets.map((b) => asInt(b.value)).toList(), [40, -20]);
    });

    test('three measures including a calculation give a multi-measure '
        'series', () {
      final result =
          run(
                [
                  sum('revenue', label: 'revenue'),
                  sum('cost', label: 'cost'),
                  CalculatedMeasure(
                    operandA: sum('revenue'),
                    operandB: sum('cost'),
                    combination: const DifferenceCombination(),
                    label: 'profit',
                  ),
                ],
                groupBys: [FieldGroupBy(fieldRef: ref('finance', 'region'))],
              )
              as MultiMeasureSeriesResult;
      expect(result.series.map((s) => s.label).toList(), [
        'revenue',
        'cost',
        'profit',
      ]);
      final profit = result.series.firstWhere((s) => s.label == 'profit');
      expect(profit.fieldType, FieldType.integer);
      final northIndex = result.xAxis.indexWhere(
        (p) => (p.key as EnumBucketKey).value == 'north',
      );
      expect(asInt(profit.values[northIndex]), 50);
    });

    test('a calculated measure with no group-by is a scalar', () {
      final scalar =
          run([
                CalculatedMeasure(
                  operandA: sum('revenue'),
                  operandB: sum('cost'),
                  combination: const DifferenceCombination(),
                ),
              ])
              as ScalarResult;
      // Total revenue 170 − total cost 140.
      expect(asInt(scalar.value), 30);
    });
  });

  test('a synthetic bucket folds operand identities and stays synthetic', () {
    final s =
        run(
              [
                CalculatedMeasure(
                  operandA: sum('revenue'),
                  operandB: sum('cost'),
                  combination: const DifferenceCombination(),
                ),
              ],
              groupBys: [
                TimeGroupBy(
                  dateFieldRef: ref('finance', 'month'),
                  grain: TimeGrain.day,
                ),
              ],
              records: [
                row(
                  region: 'north',
                  revenue: 100,
                  cost: 60,
                  month: DateTime(2026, 5, 1),
                ),
                row(
                  region: 'north',
                  revenue: 50,
                  cost: 70,
                  month: DateTime(2026, 5, 3),
                ),
              ],
              dateRange: (DateTime(2026, 5, 1), DateTime(2026, 5, 4)),
            )
            as SeriesResult;
    expect(s.buckets.map((b) => asInt(b.value)).toList(), [40, 0, -20]);
    expect(s.buckets.map((b) => b.isSynthetic).toList(), [false, true, false]);
  });
}
