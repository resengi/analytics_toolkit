import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:test/test.dart';

import '_fixtures.dart';

/// Pins `HavingClause` execution: each [HavingOperator] filters
/// correctly, null measure values are dropped, the clause runs after
/// densification and before limit, and per-measure label resolution
/// works in multi-measure queries.
///
/// Validator-side rejections (missing label in multi-measure, unknown
/// label, type-mismatched threshold, HAVING on a 0-groupBy query)
/// live in `query_validation_test.dart`.
void main() {
  final tasks = tasksSource();
  final events = eventsSource();

  // ────────────────────────────────────────────────────────────────────
  // Each HavingOperator filters correctly
  // ────────────────────────────────────────────────────────────────────

  group('every HavingOperator filters the documented set', () {
    // Build a categorical groupBy that produces 5 buckets with
    // counts 1..5. Each bucket's count is the number of records
    // carrying its enum value.
    //
    // Threshold = 3. The expected surviving counts per operator:
    //   equals       → {3}
    //   notEquals    → {1, 2, 4, 5}
    //   lessThan     → {1, 2}
    //   lessThanOrEq → {1, 2, 3}
    //   greaterThan  → {4, 5}
    //   greaterThanOrEq → {3, 4, 5}
    List<SourceRecord> records() => [
      for (var i = 0; i < 1; i++)
        SourceRecord(fields: {'status': const EnumValue('a')}),
      for (var i = 0; i < 2; i++)
        SourceRecord(fields: {'status': const EnumValue('b')}),
      for (var i = 0; i < 3; i++)
        SourceRecord(fields: {'status': const EnumValue('c')}),
      for (var i = 0; i < 4; i++)
        SourceRecord(fields: {'status': const EnumValue('d')}),
      for (var i = 0; i < 5; i++)
        SourceRecord(fields: {'status': const EnumValue('e')}),
    ];

    /// Runs the count-grouped-by-status query with a HAVING clause
    /// and returns the surviving count values in sorted order.
    List<int> survivingCounts(HavingOperator op) {
      final result = AnalyticsExecutor.execute(
        query: AnalyticsQuerySpec(
          source: 'tasks',
          measures: const [CountMeasure()],
          groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
          having: HavingClause(operator: op, threshold: const IntValue(3)),
        ),
        records: records(),
        sources: [tasks],
      );
      final series = result.okOrNull as SeriesResult;
      final counts =
          series.buckets.map((b) => (b.value as IntValue).value).toList()
            ..sort();
      return counts;
    }

    test('equals threshold keeps only the matching value', () {
      expect(survivingCounts(HavingOperator.equals), [3]);
    });
    test('notEquals threshold drops only the matching value', () {
      expect(survivingCounts(HavingOperator.notEquals), [1, 2, 4, 5]);
    });
    test('lessThan threshold keeps strictly-less', () {
      expect(survivingCounts(HavingOperator.lessThan), [1, 2]);
    });
    test('lessThanOrEqual threshold keeps less-or-equal', () {
      expect(survivingCounts(HavingOperator.lessThanOrEqual), [1, 2, 3]);
    });
    test('greaterThan threshold keeps strictly-greater', () {
      expect(survivingCounts(HavingOperator.greaterThan), [4, 5]);
    });
    test('greaterThanOrEqual threshold keeps greater-or-equal', () {
      expect(survivingCounts(HavingOperator.greaterThanOrEqual), [3, 4, 5]);
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // Null measure values are dropped regardless of operator/threshold
  // ────────────────────────────────────────────────────────────────────

  group('null measure values are dropped', () {
    // Use AverageAgg with a temporal groupBy + dateRange so densified
    // synthetic buckets aggregate to `null` (non-additive on empty).
    // HAVING must drop those cells regardless of how its operator
    // would compare to `null`.

    test(
      'average over a densified empty day produces a null cell that HAVING drops',
      () {
        final records = [
          SourceRecord(
            fields: {
              'occurredAt': DateTimeValue(DateTime(2026, 5, 1)),
              'amount': const IntValue(5),
            },
          ),
          SourceRecord(
            fields: {
              'occurredAt': DateTimeValue(DateTime(2026, 5, 3)),
              'amount': const IntValue(10),
            },
          ),
        ];
        final result = AnalyticsExecutor.execute(
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
            // Without HAVING, the densified May 2 bucket would carry
            // `null` for average. HAVING drops null cells unconditionally.
            having: const HavingClause(
              operator: HavingOperator.greaterThan,
              threshold: DoubleValue(0.0),
            ),
          ),
          records: records,
          sources: [events],
          dateRange: (DateTime(2026, 5, 1), DateTime(2026, 5, 4)),
        );
        final series = result.okOrNull as SeriesResult;
        // Only May 1 and May 3 should remain — May 2 was densified and
        // averaged to null, which HAVING drops.
        expect(series.buckets, hasLength(2));
        for (final b in series.buckets) {
          expect(b.value, isNotNull);
        }
      },
    );
  });

  // ────────────────────────────────────────────────────────────────────
  // Pipeline ordering: HAVING runs after densification, before limit
  // ────────────────────────────────────────────────────────────────────

  group('pipeline ordering — densification, limit', () {
    test(
      'HAVING runs after densification and can filter synthetic empties',
      () {
        // Two records on May 1 and May 5; dateRange spans May 1..5
        // (inclusive of May 5, exclusive of May 6). Days 2-4 are
        // synthetic empty buckets — sum-aggregated they carry IntValue(0).
        final records = [
          SourceRecord(
            fields: {
              'occurredAt': DateTimeValue(DateTime(2026, 5, 1)),
              'amount': const IntValue(10),
            },
          ),
          SourceRecord(
            fields: {
              'occurredAt': DateTimeValue(DateTime(2026, 5, 5)),
              'amount': const IntValue(7),
            },
          ),
        ];

        // Without HAVING: 5 buckets (May 1..5) — 3 synthetic with value 0.
        final unfiltered = AnalyticsExecutor.execute(
          query: AnalyticsQuerySpec(
            source: 'events',
            measures: [
              FieldMeasure(
                fieldRef: ref('events', 'amount'),
                aggregation: const SumAgg(),
              ),
            ],
            groupBys: [
              TimeGroupBy(
                dateFieldRef: ref('events', 'occurredAt'),
                grain: TimeGrain.day,
              ),
            ],
          ),
          records: records,
          sources: [events],
          dateRange: (DateTime(2026, 5, 1), DateTime(2026, 5, 6)),
        );
        expect((unfiltered.okOrNull as SeriesResult).buckets, hasLength(5));

        // With HAVING > 0: the 3 synthetic 0-buckets are dropped → 2 left.
        final filtered = AnalyticsExecutor.execute(
          query: AnalyticsQuerySpec(
            source: 'events',
            measures: [
              FieldMeasure(
                fieldRef: ref('events', 'amount'),
                aggregation: const SumAgg(),
              ),
            ],
            groupBys: [
              TimeGroupBy(
                dateFieldRef: ref('events', 'occurredAt'),
                grain: TimeGrain.day,
              ),
            ],
            having: const HavingClause(
              operator: HavingOperator.greaterThan,
              threshold: IntValue(0),
            ),
          ),
          records: records,
          sources: [events],
          dateRange: (DateTime(2026, 5, 1), DateTime(2026, 5, 6)),
        );
        expect((filtered.okOrNull as SeriesResult).buckets, hasLength(2));
      },
    );

    test('limit caps the post-HAVING set, not the pre-HAVING set', () {
      // Five buckets via dateRange: May 1 (10), May 2..4 (synthetic
      // zeros), May 5 (7). HAVING > 0 leaves 2 cells; even with
      // limit: 3, the result has 2 cells. If limit ran before HAVING,
      // we'd see up to 3 cells (some of them still zero, depending on
      // sort). The 2-cell result is the proof that HAVING ran first.
      final records = [
        SourceRecord(
          fields: {
            'occurredAt': DateTimeValue(DateTime(2026, 5, 1)),
            'amount': const IntValue(10),
          },
        ),
        SourceRecord(
          fields: {
            'occurredAt': DateTimeValue(DateTime(2026, 5, 5)),
            'amount': const IntValue(7),
          },
        ),
      ];
      final result = AnalyticsExecutor.execute(
        query: AnalyticsQuerySpec(
          source: 'events',
          measures: [
            FieldMeasure(
              fieldRef: ref('events', 'amount'),
              aggregation: const SumAgg(),
            ),
          ],
          groupBys: [
            TimeGroupBy(
              dateFieldRef: ref('events', 'occurredAt'),
              grain: TimeGrain.day,
            ),
          ],
          having: const HavingClause(
            operator: HavingOperator.greaterThan,
            threshold: IntValue(0),
          ),
          sort: const Sort(
            target: MeasureValueSort(),
            direction: SortDirection.descending,
          ),
          limit: 3,
        ),
        records: records,
        sources: [events],
        dateRange: (DateTime(2026, 5, 1), DateTime(2026, 5, 6)),
      );
      final series = result.okOrNull as SeriesResult;
      expect(series.buckets, hasLength(2));
      expect(series.buckets.map((b) => (b.value as IntValue).value).toList(), [
        10,
        7,
      ]);
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // Multi-measure label resolution
  // ────────────────────────────────────────────────────────────────────

  group('multi-measure HAVING — label resolution', () {
    /// Two records with distinct status values so each bucket has
    /// one record. Lets us test which measure HAVING filters on.
    List<SourceRecord> records() => [
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
    ];

    test('explicit measure label routes HAVING to the chosen measure', () {
      // Two measures: count (always 1) and sum-of-priority (1 or 10).
      // HAVING > 5 on the priority sum keeps only beta; on the count
      // keeps neither (counts are all 1 ≤ 5).
      final byPriority = AnalyticsExecutor.execute(
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
          having: const HavingClause(
            operator: HavingOperator.greaterThan,
            threshold: IntValue(5),
            measureLabel: 'prio',
          ),
        ),
        records: records(),
        sources: [tasks],
      );
      final mm = byPriority.okOrNull as MultiMeasureSeriesResult;
      expect(mm.xAxis, hasLength(1));
      expect(mm.xAxis.single.key, const EnumBucketKey('beta'));
    });

    test('auto-label routes HAVING via measure_<index>', () {
      // No explicit labels; the second measure is `measure_1`.
      final result = AnalyticsExecutor.execute(
        query: AnalyticsQuerySpec(
          source: 'tasks',
          measures: [
            const CountMeasure(),
            FieldMeasure(
              fieldRef: ref('tasks', 'priority'),
              aggregation: const SumAgg(),
            ),
          ],
          groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
          having: const HavingClause(
            operator: HavingOperator.greaterThan,
            threshold: IntValue(5),
            measureLabel: 'measure_1',
          ),
        ),
        records: records(),
        sources: [tasks],
      );
      final mm = result.okOrNull as MultiMeasureSeriesResult;
      expect(mm.xAxis, hasLength(1));
      expect(mm.xAxis.single.key, const EnumBucketKey('beta'));
    });

    test(
      'single-measure HAVING with null label resolves to the only measure',
      () {
        final result = AnalyticsExecutor.execute(
          query: AnalyticsQuerySpec(
            source: 'tasks',
            measures: [
              FieldMeasure(
                fieldRef: ref('tasks', 'priority'),
                aggregation: const SumAgg(),
              ),
            ],
            groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
            having: const HavingClause(
              operator: HavingOperator.greaterThan,
              threshold: IntValue(5),
            ),
          ),
          records: records(),
          sources: [tasks],
        );
        final series = result.okOrNull as SeriesResult;
        expect(series.buckets, hasLength(1));
        expect(series.buckets.single.key, const EnumBucketKey('beta'));
      },
    );
  });
}
