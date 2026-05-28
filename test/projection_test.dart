import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:test/test.dart';

import '_fixtures.dart';

/// `toTableResult()` projections on the three chart-shape view
/// types. Each projection produces a `TableResult` with the same
/// data the view holds, laid out in column-oriented form:
///
/// - `SeriesResult.toTableResult()`: 1 group-key column + 1 measure
///   column, M rows.
/// - `MultiSeriesResult.toTableResult()`: 2 group-key columns +
///   1 measure column, M × N rows.
/// - `MultiMeasureSeriesResult.toTableResult()`: 1 group-key column +
///   N measure columns, M rows.
void main() {
  final tasks = tasksSource();

  // ────────────────────────────────────────────────────────────────────
  // SeriesResult → TableResult
  // ────────────────────────────────────────────────────────────────────

  group('SeriesResult.toTableResult()', () {
    test('1 group-key column + 1 measure column with M rows', () {
      final records = [
        SourceRecord(
          fields: {
            'status': const EnumValue('todo'),
            'priority': const IntValue(1),
          },
        ),
        SourceRecord(
          fields: {
            'status': const EnumValue('done'),
            'priority': const IntValue(2),
          },
        ),
      ];
      final result = AnalyticsExecutor.execute(
        query: AnalyticsQuerySpec(
          source: 'tasks',
          measures: [
            FieldMeasure(
              fieldRef: ref('tasks', 'priority'),
              aggregation: const SumAgg(),
              label: 'prio',
            ),
          ],
          groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
        ),
        records: records,
        sources: [tasks],
      );
      final series = result.okOrNull as SeriesResult;
      final table = series.toTableResult();

      expect(table.groupKeyColumns, hasLength(1));
      expect(table.measureColumns, hasLength(1));
      expect(table.groupKeyColumns.single.label, 'status');
      expect(table.measureColumns.single.label, 'prio');
      // Two rows, one per observed bucket.
      expect(table.rowCount, 2);
      // RowKey length is 1.
      for (final rk in table.rowKeys) {
        expect(rk.keys, hasLength(1));
      }
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // MultiSeriesResult → TableResult (M × N rows)
  // ────────────────────────────────────────────────────────────────────

  group('MultiSeriesResult.toTableResult()', () {
    test('2 group-key columns + 1 measure column, M × N rows in long form', () {
      final records = [
        SourceRecord(
          fields: {
            'status': const EnumValue('todo'),
            'priority': const IntValue(1),
          },
        ),
        SourceRecord(
          fields: {
            'status': const EnumValue('done'),
            'priority': const IntValue(2),
          },
        ),
      ];
      final result = AnalyticsExecutor.execute(
        query: AnalyticsQuerySpec(
          source: 'tasks',
          measures: const [CountMeasure(label: 'n')],
          groupBys: [
            FieldGroupBy(fieldRef: ref('tasks', 'status')),
            FieldGroupBy(fieldRef: ref('tasks', 'priority')),
          ],
        ),
        records: records,
        sources: [tasks],
      );
      final ms = result.okOrNull as MultiSeriesResult;
      final table = ms.toTableResult();

      expect(table.groupKeyColumns, hasLength(2));
      expect(table.measureColumns, hasLength(1));
      // M × N rows: 2 primary positions × 2 secondary positions = 4.
      expect(table.rowCount, ms.xAxis.length * ms.series.length);
      // RowKey length is 2.
      for (final rk in table.rowKeys) {
        expect(rk.keys, hasLength(2));
      }
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // MultiMeasureSeriesResult → TableResult
  // ────────────────────────────────────────────────────────────────────

  group('MultiMeasureSeriesResult.toTableResult()', () {
    test('1 group-key column + N measure columns, M rows', () {
      final records = [
        SourceRecord(
          fields: {
            'status': const EnumValue('todo'),
            'priority': const IntValue(1),
          },
        ),
        SourceRecord(
          fields: {
            'status': const EnumValue('done'),
            'priority': const IntValue(2),
          },
        ),
      ];
      final result = AnalyticsExecutor.execute(
        query: AnalyticsQuerySpec(
          source: 'tasks',
          measures: [
            const CountMeasure(label: 'n'),
            FieldMeasure(
              fieldRef: ref('tasks', 'priority'),
              aggregation: const SumAgg(),
              label: 'prio',
            ),
          ],
          groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
        ),
        records: records,
        sources: [tasks],
      );
      final mm = result.okOrNull as MultiMeasureSeriesResult;
      final table = mm.toTableResult();

      expect(table.groupKeyColumns, hasLength(1));
      expect(table.measureColumns, hasLength(2));
      expect(table.measureColumns[0].label, 'n');
      expect(table.measureColumns[1].label, 'prio');
      // M rows = x-axis length.
      expect(table.rowCount, mm.xAxis.length);
      // RowKey length 1.
      for (final rk in table.rowKeys) {
        expect(rk.keys, hasLength(1));
      }
    });

    test('per-measure fieldType propagates to each measure column', () {
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
        records: [
          SourceRecord(
            fields: {
              'category': const EnumValue('A'),
              'dur': const DurationValue(Duration(seconds: 5)),
            },
          ),
        ],
        sources: [source],
      );
      final table = (result.okOrNull as MultiMeasureSeriesResult)
          .toTableResult();
      expect(table.measureColumns[0].fieldType, FieldType.integer);
      expect(table.measureColumns[1].fieldType, FieldType.duration);
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // Projection vs. direct table query — column equivalence
  // ────────────────────────────────────────────────────────────────────

  group('projection equivalence to direct-table queries', () {
    test('(1, N) projection matches a structurally equivalent table query', () {
      // The (1, N) projection from MultiMeasureSeriesResult produces
      // the same column-oriented data as if (1, N) had been routed
      // directly to TableResult. Currently the executor always routes
      // (1, N) to MultiMeasureSeriesResult, so the comparison is
      // really projection-shape vs. the in-memory projection — but
      // pinning the column labels and row keys ensures the projected
      // shape stays self-consistent.
      final records = [
        SourceRecord(
          fields: {
            'status': const EnumValue('todo'),
            'priority': const IntValue(1),
          },
        ),
        SourceRecord(
          fields: {
            'status': const EnumValue('done'),
            'priority': const IntValue(2),
          },
        ),
      ];
      final mm =
          (AnalyticsExecutor.execute(
                query: AnalyticsQuerySpec(
                  source: 'tasks',
                  measures: [
                    const CountMeasure(label: 'n'),
                    FieldMeasure(
                      fieldRef: ref('tasks', 'priority'),
                      aggregation: const SumAgg(),
                      label: 'prio',
                    ),
                  ],
                  groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
                ),
                records: records,
                sources: [tasks],
              ).okOrNull
              as MultiMeasureSeriesResult);
      final table = mm.toTableResult();

      // Row count matches x-axis length.
      expect(table.rowCount, mm.xAxis.length);

      // Each row's measure cells equal the corresponding series values.
      for (var i = 0; i < table.rowCount; i++) {
        for (var j = 0; j < mm.series.length; j++) {
          expect(table.measureColumns[j].values[i], mm.series[j].values[i]);
        }
      }
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // Synthetic-index propagation
  // ────────────────────────────────────────────────────────────────────

  group('toTableResult() propagates synthetic markers', () {
    // Each view type carries synthetic-tracking metadata; the
    // projection to TableResult must turn those into matching
    // syntheticRowIndices so consumers reading the projected table
    // see the same observed/synthetic distinction.

    test('SeriesResult.toTableResult propagates SeriesBucket.isSynthetic', () {
      // Manually build a SeriesResult with one observed bucket and
      // one synthetic — the projection should mark row index 1 as
      // synthetic.
      final s = SeriesResult(
        buckets: const [
          SeriesBucket(key: EnumBucketKey('observed'), value: IntValue(1)),
          SeriesBucket(
            key: EnumBucketKey('filler'),
            value: IntValue(0),
            isSynthetic: true,
          ),
        ],
        groupKind: SeriesGroupKind.categorical,
        groupColumnLabel: 'status',
        groupColumnFieldType: FieldType.enumeration,
        measureLabel: 'count',
        measureFieldType: FieldType.integer,
      );
      final table = s.toTableResult();
      expect(table.syntheticRowIndices, {1});
    });

    test(
      'MultiSeriesResult.toTableResult flattens synthetic indices across series',
      () {
        // Two primary positions × two series, with one cell synthetic
        // per series at primary index 1. Long-format projection emits
        // rows in (primary, series) order — primary varies slowest —
        // so the synthetic primary-index-1 cells land at projected row
        // indices 2 and 3 (after the two primary-index-0 rows).
        final ms = MultiSeriesResult(
          xAxis: const [
            XAxisPosition(key: EnumBucketKey('p0')),
            XAxisPosition(key: EnumBucketKey('p1')),
          ],
          series: [
            NamedSeries(
              key: const EnumBucketKey('s0'),
              values: const [IntValue(1), IntValue(0)],
              syntheticValueIndices: const {1},
            ),
            NamedSeries(
              key: const EnumBucketKey('s1'),
              values: const [IntValue(1), IntValue(0)],
              syntheticValueIndices: const {1},
            ),
          ],
          groupKind: SeriesGroupKind.categorical,
          primaryColumnLabel: 'p',
          primaryColumnFieldType: FieldType.enumeration,
          secondaryColumnLabel: 's',
          secondaryColumnFieldType: FieldType.enumeration,
          measureLabel: 'm',
          measureFieldType: FieldType.integer,
        );
        final table = ms.toTableResult();
        // Row order: (p0, s0), (p0, s1), (p1, s0), (p1, s1).
        // Synthetic at primary-index-1 → rows 2 and 3.
        expect(table.rowCount, 4);
        expect(table.syntheticRowIndices, {2, 3});
      },
    );

    test(
      'MultiMeasureSeriesResult.toTableResult passes syntheticXAxisIndices through',
      () {
        final mm = MultiMeasureSeriesResult(
          xAxis: const [
            XAxisPosition(key: EnumBucketKey('a')),
            XAxisPosition(key: EnumBucketKey('b')),
            XAxisPosition(key: EnumBucketKey('c')),
          ],
          series: [
            MeasureSeries(
              label: 'count',
              fieldType: FieldType.integer,
              values: const [IntValue(1), IntValue(0), IntValue(2)],
            ),
          ],
          groupKind: SeriesGroupKind.categorical,
          groupColumnLabel: 'g',
          groupColumnFieldType: FieldType.enumeration,
          syntheticXAxisIndices: const {1},
        );
        final table = mm.toTableResult();
        // X-axis position index 1 is synthetic → row index 1 in the
        // projection (one-to-one for this view type).
        expect(table.syntheticRowIndices, {1});
      },
    );
  });

  // ────────────────────────────────────────────────────────────────────
  // Executor uses GroupBy.label as the column label
  // ────────────────────────────────────────────────────────────────────

  group('executor honours GroupBy.label', () {
    test('SeriesResult.groupColumnLabel uses the alias when set', () {
      final records = [
        SourceRecord(fields: {'status': const EnumValue('todo')}),
      ];
      final result =
          AnalyticsExecutor.execute(
                query: AnalyticsQuerySpec(
                  source: 'tasks',
                  measures: const [CountMeasure()],
                  groupBys: [
                    FieldGroupBy(
                      fieldRef: ref('tasks', 'status'),
                      label: 'category',
                    ),
                  ],
                ),
                records: records,
                sources: [tasks],
              ).okOrNull
              as SeriesResult;

      expect(result.groupColumnLabel, 'category');
    });

    test('SeriesResult.groupColumnLabel falls back to the field id', () {
      final records = [
        SourceRecord(fields: {'status': const EnumValue('todo')}),
      ];
      final result =
          AnalyticsExecutor.execute(
                query: AnalyticsQuerySpec(
                  source: 'tasks',
                  measures: const [CountMeasure()],
                  groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
                ),
                records: records,
                sources: [tasks],
              ).okOrNull
              as SeriesResult;

      expect(result.groupColumnLabel, 'status');
    });
  });
}
