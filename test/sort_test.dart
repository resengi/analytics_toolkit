import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:test/test.dart';

import '_fixtures.dart';

/// End-to-end executor sort policy.
///
/// `GroupFieldSort` orders by the bucket key of a chosen group-by;
/// `MeasureValueSort` orders by a measure's aggregated value (the
/// measure is named by `measureLabel` in multi-measure queries).
///
/// Null position follows the SQL convention: ascending sorts place
/// nulls last; descending sorts place nulls first. Set
/// `Sort.forceNullsLast: true` to pin nulls to the end regardless of
/// direction.
void main() {
  final tasks = tasksSource();
  final events = eventsSource();

  // Two recorded statuses + one record with status missing →
  // produces a NullBucketKey on the categorical axis.
  List<SourceRecord> tasksRecords() => [
    SourceRecord(
      fields: {
        'status': const EnumValue('done'),
        'priority': const IntValue(3),
      },
    ),
    SourceRecord(
      fields: {
        'status': const EnumValue('todo'),
        'priority': const IntValue(1),
      },
    ),
    SourceRecord(
      // status field absent → NullBucketKey
      fields: {'priority': const IntValue(2)},
    ),
  ];

  Result<AnalyticsResult, AnalyticsError> runTasks(AnalyticsQuerySpec query) =>
      AnalyticsExecutor.execute(
        query: query,
        records: tasksRecords(),
        sources: [tasks],
      );

  // ────────────────────────────────────────────────────────────────────
  // GroupFieldSort — null bucket-key position
  // ────────────────────────────────────────────────────────────────────

  group('GroupFieldSort — null bucket-key position follows direction', () {
    SeriesResult sorted({
      required SortDirection direction,
      bool forceNullsLast = false,
    }) =>
        runTasks(
              AnalyticsQuerySpec(
                source: 'tasks',
                measures: const [CountMeasure()],
                groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
                sort: Sort(
                  target: GroupFieldSort(fieldRef: ref('tasks', 'status')),
                  direction: direction,
                  forceNullsLast: forceNullsLast,
                ),
              ),
            ).okOrNull
            as SeriesResult;

    test('ascending: NullBucketKey is the last bucket', () {
      expect(
        sorted(direction: SortDirection.ascending).buckets.last.key,
        isA<NullBucketKey>(),
      );
    });

    test('descending: NullBucketKey is the first bucket', () {
      expect(
        sorted(direction: SortDirection.descending).buckets.first.key,
        isA<NullBucketKey>(),
      );
    });

    test('descending: non-null keys reverse-sort correctly', () {
      // After the null bucket at the front, the non-null keys are
      // alphabetical-descending.
      final nonNull = sorted(direction: SortDirection.descending).buckets
          .where((b) => b.key is! NullBucketKey)
          .map((b) => (b.key as EnumBucketKey).value)
          .toList();
      expect(nonNull, ['todo', 'done']);
    });

    test('ascending: non-null keys sort alphabetically', () {
      final nonNull = sorted(direction: SortDirection.ascending).buckets
          .where((b) => b.key is! NullBucketKey)
          .map((b) => (b.key as EnumBucketKey).value)
          .toList();
      expect(nonNull, ['done', 'todo']);
    });

    test(
      'forceNullsLast pins the null bucket to the end under either direction',
      () {
        // Ascending with forceNullsLast — null is already at the end by
        // default, so this case looks identical to the plain ascending
        // sort but the knob is explicit.
        expect(
          sorted(
            direction: SortDirection.ascending,
            forceNullsLast: true,
          ).buckets.last.key,
          isA<NullBucketKey>(),
        );
        // Descending with forceNullsLast — overrides the default
        // (which would put null first).
        expect(
          sorted(
            direction: SortDirection.descending,
            forceNullsLast: true,
          ).buckets.last.key,
          isA<NullBucketKey>(),
        );
      },
    );
  });

  // ────────────────────────────────────────────────────────────────────
  // MeasureValueSort (single-measure) — ascending/descending basics
  // ────────────────────────────────────────────────────────────────────

  group('MeasureValueSort — single-measure ascending and descending', () {
    test('ascending sorts buckets by their measure value ascending', () {
      final result = runTasks(
        AnalyticsQuerySpec(
          source: 'tasks',
          measures: [
            FieldMeasure(
              fieldRef: ref('tasks', 'priority'),
              aggregation: const MinAgg(),
            ),
          ],
          groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
          sort: const Sort(
            target: MeasureValueSort(),
            direction: SortDirection.ascending,
          ),
        ),
      );
      final series = result.okOrNull as SeriesResult;
      final nonNull = series.buckets
          .where((b) => b.value != null)
          .map((b) => (b.value as IntValue).value)
          .toList();
      expect(nonNull, [1, 2, 3]);
    });

    test('descending sorts buckets by their measure value descending', () {
      final result = runTasks(
        AnalyticsQuerySpec(
          source: 'tasks',
          measures: [
            FieldMeasure(
              fieldRef: ref('tasks', 'priority'),
              aggregation: const MinAgg(),
            ),
          ],
          groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
          sort: const Sort(
            target: MeasureValueSort(),
            direction: SortDirection.descending,
          ),
        ),
      );
      final series = result.okOrNull as SeriesResult;
      final nonNull = series.buckets
          .where((b) => b.value != null)
          .map((b) => (b.value as IntValue).value)
          .toList();
      expect(nonNull, [3, 2, 1]);
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // MeasureValueSort with explicit measureLabel in multi-measure
  // ────────────────────────────────────────────────────────────────────

  group('MeasureValueSort with measureLabel — multi-measure', () {
    test('sorts by the labeled measure, not by the first measure', () {
      // Two records produce two buckets: A (priority 1, count 1) and
      // B (priority 10, count 1). Sorting by `prio` desc puts B first;
      // sorting by `n` would tie.
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
          sort: const Sort(
            target: MeasureValueSort(measureLabel: 'prio'),
            direction: SortDirection.descending,
          ),
        ),
        records: [
          SourceRecord(
            fields: {
              'status': const EnumValue('alpha'),
              'priority': const IntValue(1),
            },
          ),
          SourceRecord(
            fields: {
              'status': const EnumValue('beta'),
              'priority': const IntValue(10),
            },
          ),
        ],
        sources: [tasks],
      );
      final mm = result.okOrNull as MultiMeasureSeriesResult;
      // 'prio' descending → beta (10) before alpha (1).
      expect(mm.xAxis.map((p) => p.key).toList(), [
        const EnumBucketKey('beta'),
        const EnumBucketKey('alpha'),
      ]);
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // MeasureValueSort — null measure-value position
  // ────────────────────────────────────────────────────────────────────

  group('MeasureValueSort — null measure-value position follows direction', () {
    // Build a temporal series where one bucket is synthetic-empty
    // (densified) and aggregates to null via AverageAgg. Sort by
    // measure value and verify the null bucket lands at the position
    // implied by the direction (or by forceNullsLast).

    SeriesResult run({
      required SortDirection direction,
      bool forceNullsLast = false,
    }) =>
        AnalyticsExecutor.execute(
              query: AnalyticsQuerySpec(
                source: 'events',
                measures: [
                  FieldMeasure(
                    fieldRef: ref('events', 'amount'),
                    aggregation: const AverageAgg(),
                  ),
                ],
                groupBys: [
                  TimeGroupBy(
                    dateFieldRef: ref('events', 'occurredAt'),
                    grain: TimeGrain.day,
                  ),
                ],
                sort: Sort(
                  target: const MeasureValueSort(),
                  direction: direction,
                  forceNullsLast: forceNullsLast,
                ),
              ),
              records: [
                SourceRecord(
                  fields: {
                    'occurredAt': DateTimeValue(DateTime(2026, 5, 1)),
                    'amount': const IntValue(10),
                  },
                ),
                SourceRecord(
                  fields: {
                    'occurredAt': DateTimeValue(DateTime(2026, 5, 3)),
                    'amount': const IntValue(5),
                  },
                ),
              ],
              sources: [events],
              dateRange: (DateTime(2026, 5, 1), DateTime(2026, 5, 4)),
            ).okOrNull
            as SeriesResult;

    test('ascending: null cell is last', () {
      expect(
        run(direction: SortDirection.ascending).buckets.last.value,
        isNull,
      );
    });

    test('descending: null cell is first', () {
      expect(
        run(direction: SortDirection.descending).buckets.first.value,
        isNull,
      );
    });

    test(
      'forceNullsLast pins the null cell to the end under either direction',
      () {
        expect(
          run(
            direction: SortDirection.ascending,
            forceNullsLast: true,
          ).buckets.last.value,
          isNull,
        );
        expect(
          run(
            direction: SortDirection.descending,
            forceNullsLast: true,
          ).buckets.last.value,
          isNull,
        );
      },
    );
  });

  // ────────────────────────────────────────────────────────────────────
  // Sort applies to all cardinalities of groupBys
  // ────────────────────────────────────────────────────────────────────

  group('sort applies to multi-axis results', () {
    // For 2-groupBy queries, sort still orders the result's x-axis
    // (primary axis). The secondary axis is encounter-order-stable.
    test('2-groupBy query is sorted by GroupFieldSort on the primary axis', () {
      final result = AnalyticsExecutor.execute(
        query: AnalyticsQuerySpec(
          source: 'tasks',
          measures: const [CountMeasure()],
          groupBys: [
            FieldGroupBy(fieldRef: ref('tasks', 'status')),
            FieldGroupBy(fieldRef: ref('tasks', 'priority')),
          ],
          sort: Sort(
            target: GroupFieldSort(fieldRef: ref('tasks', 'status')),
            direction: SortDirection.descending,
          ),
        ),
        records: [
          SourceRecord(
            fields: {
              'status': const EnumValue('alpha'),
              'priority': const IntValue(1),
            },
          ),
          SourceRecord(
            fields: {
              'status': const EnumValue('beta'),
              'priority': const IntValue(1),
            },
          ),
        ],
        sources: [tasks],
      );
      final ms = result.okOrNull as MultiSeriesResult;
      // Descending alphabetical: beta first, alpha second.
      expect(ms.xAxis.map((p) => p.key).toList(), [
        const EnumBucketKey('beta'),
        const EnumBucketKey('alpha'),
      ]);
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // x-axis ordering determinism for multi-series queries
  // ────────────────────────────────────────────────────────────────────

  group('multi-series x-axis ordering is deterministic and null-last', () {
    // The primary x-axis is sorted by `BucketKeyOrdering`
    // independently of input order. `NullBucketKey` always sorts
    // last regardless of direction.

    test('two record orderings produce the same x-axis sort', () {
      AnalyticsQuerySpec twoAxisQuery() => AnalyticsQuerySpec(
        source: 'tasks',
        measures: const [CountMeasure()],
        groupBys: [
          FieldGroupBy(fieldRef: ref('tasks', 'status')),
          FieldGroupBy(fieldRef: ref('tasks', 'priority')),
        ],
      );
      List<SourceRecord> orderingA() => [
        SourceRecord(
          fields: {
            'status': const EnumValue('beta'),
            'priority': const IntValue(1),
          },
        ),
        SourceRecord(
          fields: {
            'status': const EnumValue('alpha'),
            'priority': const IntValue(2),
          },
        ),
        SourceRecord(
          fields: {
            'status': const EnumValue('gamma'),
            'priority': const IntValue(1),
          },
        ),
      ];
      List<SourceRecord> orderingB() => [
        SourceRecord(
          fields: {
            'status': const EnumValue('gamma'),
            'priority': const IntValue(1),
          },
        ),
        SourceRecord(
          fields: {
            'status': const EnumValue('alpha'),
            'priority': const IntValue(2),
          },
        ),
        SourceRecord(
          fields: {
            'status': const EnumValue('beta'),
            'priority': const IntValue(1),
          },
        ),
      ];

      final a =
          AnalyticsExecutor.execute(
                query: twoAxisQuery(),
                records: orderingA(),
                sources: [tasks],
              ).okOrNull
              as MultiSeriesResult;
      final b =
          AnalyticsExecutor.execute(
                query: twoAxisQuery(),
                records: orderingB(),
                sources: [tasks],
              ).okOrNull
              as MultiSeriesResult;

      // Both produce the same sorted x-axis: alpha, beta, gamma.
      expect(
        a.xAxis.map((p) => p.key).toList(),
        b.xAxis.map((p) => p.key).toList(),
      );
      expect(a.xAxis.map((p) => p.key).toList(), const [
        EnumBucketKey('alpha'),
        EnumBucketKey('beta'),
        EnumBucketKey('gamma'),
      ]);
    });

    test('NullBucketKey on the primary axis is the last x-axis entry', () {
      // One record missing the primary group-by field produces a
      // NullBucketKey on the primary axis.
      final records = [
        SourceRecord(
          fields: {
            'status': const EnumValue('done'),
            'priority': const IntValue(1),
          },
        ),
        SourceRecord(
          fields: {
            'status': const EnumValue('todo'),
            'priority': const IntValue(1),
          },
        ),
        SourceRecord(
          // No status → NullBucketKey on primary axis.
          fields: {'priority': const IntValue(1)},
        ),
      ];
      final ms =
          AnalyticsExecutor.execute(
                query: AnalyticsQuerySpec(
                  source: 'tasks',
                  measures: const [CountMeasure()],
                  groupBys: [
                    FieldGroupBy(fieldRef: ref('tasks', 'status')),
                    FieldGroupBy(fieldRef: ref('tasks', 'priority')),
                  ],
                ),
                records: records,
                sources: [tasks],
              ).okOrNull
              as MultiSeriesResult;
      expect(ms.xAxis.last.key, isA<NullBucketKey>());
    });
  });
}
