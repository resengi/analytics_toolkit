import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:test/test.dart';

import '_fixtures.dart';

/// Multi-measure execution surface — every cardinality of
/// `(groupBys.length, measures.length)` for `measures.length >= 2`.
///
/// The executor evaluates all measures in a single per-bucket pass:
/// one aggregator closure invocation per measure per bucket. This
/// invariant isn't observable through the public surface (the
/// `Measure` family is sealed; no third-party `Measure` subtype can
/// count its invocations), so it's documented here rather than
/// tested. The shape tests below pin every observable consequence.
void main() {
  final events = eventsSource();

  // Custom three-axis source for the `(3, N)` test — events has only
  // two groupable fields (occurredAt and kind), so we build a source
  // that exposes three.
  final threeAxisSource = SourceDef(
    sourceId: 'multi',
    displayName: 'Multi',
    fields: const [
      FieldDef(
        sourceId: 'multi',
        fieldId: 'category',
        displayName: 'Category',
        fieldType: FieldType.enumeration,
        filterable: true,
        groupable: true,
        aggregatable: false,
        sortable: true,
      ),
      FieldDef(
        sourceId: 'multi',
        fieldId: 'region',
        displayName: 'Region',
        fieldType: FieldType.enumeration,
        filterable: true,
        groupable: true,
        aggregatable: false,
        sortable: true,
      ),
      FieldDef(
        sourceId: 'multi',
        fieldId: 'segment',
        displayName: 'Segment',
        fieldType: FieldType.enumeration,
        filterable: true,
        groupable: true,
        aggregatable: false,
        sortable: true,
      ),
      FieldDef(
        sourceId: 'multi',
        fieldId: 'amount',
        displayName: 'Amount',
        fieldType: FieldType.integer,
        filterable: true,
        groupable: false,
        aggregatable: true,
        sortable: true,
      ),
    ],
  );

  /// A small set of events records spanning two days, two kinds,
  /// and varying amounts. Reused for the `(0, N)` and `(1, N)` cases.
  List<SourceRecord> eventsRecords() => [
    SourceRecord(
      fields: {
        'occurredAt': DateTimeValue(DateTime(2026, 5, 1)),
        'kind': const EnumValue('view'),
        'amount': const IntValue(10),
      },
    ),
    SourceRecord(
      fields: {
        'occurredAt': DateTimeValue(DateTime(2026, 5, 1)),
        'kind': const EnumValue('click'),
        'amount': const IntValue(2),
      },
    ),
    SourceRecord(
      fields: {
        'occurredAt': DateTimeValue(DateTime(2026, 5, 2)),
        'kind': const EnumValue('view'),
        'amount': const IntValue(8),
      },
    ),
  ];

  // ────────────────────────────────────────────────────────────────────
  // (0, N) — multi-measure with no group-by → 1-row TableResult
  // ────────────────────────────────────────────────────────────────────

  group('(0, N) → 1-row TableResult with N measure columns', () {
    test('two measures over no group-by produce a single-row table', () {
      final result = AnalyticsExecutor.execute(
        query: AnalyticsQuerySpec(
          source: 'events',
          measures: [
            const CountMeasure(label: 'count'),
            FieldMeasure(
              fieldRef: ref('events', 'amount'),
              aggregation: const SumAgg(),
              label: 'total',
            ),
          ],
        ),
        records: eventsRecords(),
        sources: [events],
      );
      expect(result.isOk, isTrue);
      final table = result.okOrNull as TableResult;

      // One row, no group-key columns, N=2 measure columns.
      expect(table.rowKeys, hasLength(1));
      expect(table.rowKeys.single, equals(RowKey(const [])));
      expect(table.rowKeys.single.keys, isEmpty);
      expect(table.groupKeyColumns, isEmpty);
      expect(table.measureColumns, hasLength(2));

      // Column labels match the explicit measure labels.
      expect(table.measureColumns[0].label, 'count');
      expect(table.measureColumns[1].label, 'total');

      // Cell values: count = 3, sum = 10+2+8 = 20.
      expect(table.measureColumns[0].values.single, const IntValue(3));
      expect(table.measureColumns[1].values.single, const IntValue(20));
    });

    test('auto-labels are used when measure labels are null', () {
      final result = AnalyticsExecutor.execute(
        query: AnalyticsQuerySpec(
          source: 'events',
          measures: const [CountMeasure(), CountMeasure()],
        ),
        records: eventsRecords(),
        sources: [events],
      );
      final table = result.okOrNull as TableResult;
      expect(table.measureColumns.map((c) => c.label).toList(), [
        'measure_0',
        'measure_1',
      ]);
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // (1, N) — single group-by with multiple measures → MultiMeasureSeriesResult
  // ────────────────────────────────────────────────────────────────────

  group('(1, N) → MultiMeasureSeriesResult', () {
    test('two measures over one categorical group-by', () {
      final result = AnalyticsExecutor.execute(
        query: AnalyticsQuerySpec(
          source: 'events',
          measures: [
            const CountMeasure(label: 'count'),
            FieldMeasure(
              fieldRef: ref('events', 'amount'),
              aggregation: const SumAgg(),
              label: 'total',
            ),
          ],
          groupBys: [FieldGroupBy(fieldRef: ref('events', 'kind'))],
        ),
        records: eventsRecords(),
        sources: [events],
      );
      expect(result.isOk, isTrue);
      final mm = result.okOrNull as MultiMeasureSeriesResult;

      // X-axis is the two observed kinds, sorted: click before view.
      expect(mm.xAxis.map((p) => p.key).toList(), [
        const EnumBucketKey('click'),
        const EnumBucketKey('view'),
      ]);
      expect(mm.groupKind, SeriesGroupKind.categorical);
      expect(mm.groupColumnLabel, 'kind');

      // Two series — one per measure — labeled by the explicit
      // measure labels.
      expect(mm.series, hasLength(2));
      expect(mm.series[0].label, 'count');
      expect(mm.series[1].label, 'total');

      // count: 1 click, 2 views.
      expect(mm.series[0].values, [const IntValue(1), const IntValue(2)]);
      // sum amount: 2 for click, 18 for view (10+8).
      expect(mm.series[1].values, [const IntValue(2), const IntValue(18)]);
    });

    test('temporal group-by produces temporal SeriesGroupKind', () {
      final result = AnalyticsExecutor.execute(
        query: AnalyticsQuerySpec(
          source: 'events',
          measures: const [
            CountMeasure(label: 'a'),
            CountMeasure(label: 'b'),
          ],
          groupBys: [
            TimeGroupBy(
              dateFieldRef: ref('events', 'occurredAt'),
              grain: TimeGrain.day,
            ),
          ],
        ),
        records: eventsRecords(),
        sources: [events],
      );
      final mm = result.okOrNull as MultiMeasureSeriesResult;
      expect(mm.groupKind, SeriesGroupKind.temporal);
      expect(mm.groupColumnFieldType, FieldType.dateTime);
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // (2, N) — two group-bys with multiple measures → wide TableResult
  // ────────────────────────────────────────────────────────────────────

  group(
    '(2, N) → wide TableResult with 2 group-key columns + N measure columns',
    () {
      test('two categorical group-bys × two measures', () {
        final records = [
          SourceRecord(
            fields: {
              'category': const EnumValue('A'),
              'region': const EnumValue('east'),
              'segment': const EnumValue('s1'),
              'amount': const IntValue(10),
            },
          ),
          SourceRecord(
            fields: {
              'category': const EnumValue('B'),
              'region': const EnumValue('west'),
              'segment': const EnumValue('s2'),
              'amount': const IntValue(20),
            },
          ),
        ];
        final result = AnalyticsExecutor.execute(
          query: AnalyticsQuerySpec(
            source: 'multi',
            measures: [
              const CountMeasure(label: 'count'),
              FieldMeasure(
                fieldRef: ref('multi', 'amount'),
                aggregation: const SumAgg(),
                label: 'total',
              ),
            ],
            groupBys: [
              FieldGroupBy(fieldRef: ref('multi', 'category')),
              FieldGroupBy(fieldRef: ref('multi', 'region')),
            ],
          ),
          records: records,
          sources: [threeAxisSource],
        );
        expect(result.isOk, isTrue);
        final table = result.okOrNull as TableResult;

        // 2 group-key columns + 2 measure columns = 4 total.
        expect(table.columns, hasLength(4));
        expect(table.groupKeyColumns.map((c) => c.label).toList(), [
          'category',
          'region',
        ]);
        expect(table.measureColumns.map((c) => c.label).toList(), [
          'count',
          'total',
        ]);

        // Cross-product densification: (A, east), (A, west), (B, east),
        // (B, west). 4 rows total.
        expect(table.rowCount, 4);
        // Row keys are length 2.
        for (final rk in table.rowKeys) {
          expect(rk.keys, hasLength(2));
        }
      });
    },
  );

  // ────────────────────────────────────────────────────────────────────
  // (3, N) — three group-bys with multiple measures → wide TableResult
  // ────────────────────────────────────────────────────────────────────

  group(
    '(3, N) → wide TableResult with 3 group-key columns + N measure columns',
    () {
      test('three categorical group-bys × two measures', () {
        final records = [
          SourceRecord(
            fields: {
              'category': const EnumValue('A'),
              'region': const EnumValue('east'),
              'segment': const EnumValue('s1'),
              'amount': const IntValue(10),
            },
          ),
          SourceRecord(
            fields: {
              'category': const EnumValue('B'),
              'region': const EnumValue('west'),
              'segment': const EnumValue('s2'),
              'amount': const IntValue(20),
            },
          ),
        ];
        final result = AnalyticsExecutor.execute(
          query: AnalyticsQuerySpec(
            source: 'multi',
            measures: [
              const CountMeasure(label: 'count'),
              FieldMeasure(
                fieldRef: ref('multi', 'amount'),
                aggregation: const SumAgg(),
                label: 'total',
              ),
            ],
            groupBys: [
              FieldGroupBy(fieldRef: ref('multi', 'category')),
              FieldGroupBy(fieldRef: ref('multi', 'region')),
              FieldGroupBy(fieldRef: ref('multi', 'segment')),
            ],
          ),
          records: records,
          sources: [threeAxisSource],
        );
        expect(result.isOk, isTrue);
        final table = result.okOrNull as TableResult;
        expect(table.groupKeyColumns, hasLength(3));
        expect(table.measureColumns, hasLength(2));

        // Row keys are length 3.
        for (final rk in table.rowKeys) {
          expect(rk.keys, hasLength(3));
        }
      });
    },
  );

  // ────────────────────────────────────────────────────────────────────
  // Heterogeneous output types
  // ────────────────────────────────────────────────────────────────────

  group('heterogeneous measure output types propagate per series', () {
    final source = SourceDef(
      sourceId: 'mixed',
      displayName: 'Mixed',
      fields: const [
        FieldDef(
          sourceId: 'mixed',
          fieldId: 'category',
          displayName: 'Category',
          fieldType: FieldType.enumeration,
          filterable: true,
          groupable: true,
          aggregatable: false,
          sortable: true,
        ),
        FieldDef(
          sourceId: 'mixed',
          fieldId: 'dur',
          displayName: 'Duration',
          fieldType: FieldType.duration,
          filterable: true,
          groupable: false,
          aggregatable: true,
          sortable: true,
        ),
      ],
    );

    test('count (integer) alongside sum of duration', () {
      final records = [
        SourceRecord(
          fields: {
            'category': const EnumValue('A'),
            'dur': const DurationValue(Duration(seconds: 5)),
          },
        ),
      ];
      final result = AnalyticsExecutor.execute(
        query: AnalyticsQuerySpec(
          source: 'mixed',
          measures: [
            const CountMeasure(label: 'n'),
            const FieldMeasure(
              fieldRef: FieldRef(sourceId: 'mixed', fieldId: 'dur'),
              aggregation: SumAgg(),
              label: 'total_dur',
            ),
          ],
          groupBys: [
            const FieldGroupBy(
              fieldRef: FieldRef(sourceId: 'mixed', fieldId: 'category'),
            ),
          ],
        ),
        records: records,
        sources: [source],
      );
      final mm = result.okOrNull as MultiMeasureSeriesResult;
      expect(mm.series[0].fieldType, FieldType.integer);
      expect(mm.series[1].fieldType, FieldType.duration);
      expect(mm.series[0].values.single, const IntValue(1));
      expect(
        mm.series[1].values.single,
        const DurationValue(Duration(seconds: 5)),
      );
    });
  });
}
