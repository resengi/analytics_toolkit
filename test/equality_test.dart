import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:test/test.dart';

import '_fixtures.dart';

/// Value-equality contracts. Every `==`-overriding type the package
/// exports compares structurally — equal contents → equal instances
/// and matching hash codes; different contents → unequal instances.
///
/// Each test pins one family with several positive and negative
/// cases; reasons on the assertions point to the exact mismatch when
/// a test fails. Result containers (`SeriesResult`, `TableResult`,
/// etc.) are intentionally identity-based and not covered here —
/// they exist for transient executor output, not as comparable
/// values. `AnalyticsWidgetSpec` is the one exception: it overrides
/// `==` to compare by `id` only, which the dedicated group below
/// pins.
void main() {
  // ────────────────────────────────────────────────────────────────────
  // TypedValue family
  // ────────────────────────────────────────────────────────────────────

  group('TypedValue equality', () {
    test('scalar TypedValues compare by their wrapped value', () {
      // Same value → equal and same hashCode.
      expect(const IntValue(5), const IntValue(5));
      expect(const IntValue(5).hashCode, const IntValue(5).hashCode);
      expect(const DoubleValue(1.5), const DoubleValue(1.5));
      expect(const StringValue('a'), const StringValue('a'));
      expect(const BoolValue(true), const BoolValue(true));
      expect(
        DateTimeValue(DateTime(2026, 5, 1)),
        DateTimeValue(DateTime(2026, 5, 1)),
      );
      // Different value → unequal.
      expect(const IntValue(5) == const IntValue(6), isFalse);
    });

    test('different TypedValue subtypes with the same raw are not equal', () {
      // StringValue and EnumValue both wrap a String but are distinct
      // shapes — equality must distinguish them.
      expect(const StringValue('a') == const EnumValue('a'), isFalse);
    });

    test(
      'list-valued TypedValues compare element-wise and order-sensitively',
      () {
        expect(
          StringListValue(const ['a', 'b']),
          StringListValue(const ['a', 'b']),
        );
        expect(
          StringListValue(const ['a', 'b']) ==
              StringListValue(const ['b', 'a']),
          isFalse,
        );
        expect(IntListValue(const [1, 2, 3]), IntListValue(const [1, 2, 3]));
      },
    );

    test('NullValue is equal iff declaredType matches', () {
      expect(
        const NullValue(FieldType.integer),
        const NullValue(FieldType.integer),
      );
      expect(
        const NullValue(FieldType.integer) == const NullValue(FieldType.string),
        isFalse,
      );
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // FieldAggregation, Measure
  // ────────────────────────────────────────────────────────────────────

  group('FieldAggregation equality', () {
    test('parameterless singletons compare equal across instances', () {
      expect(const SumAgg(), const SumAgg());
      expect(const AverageAgg(), const AverageAgg());
      expect(const MinAgg(), const MinAgg());
      expect(const MaxAgg(), const MaxAgg());
      expect(const DistinctCountAgg(), const DistinctCountAgg());
      // Different subtypes are not equal.
      expect(const SumAgg() == const AverageAgg(), isFalse);
    });

    test('PercentileAgg equal iff p matches', () {
      expect(const PercentileAgg(p: 0.5), const PercentileAgg(p: 0.5));
      expect(
        const PercentileAgg(p: 0.5) == const PercentileAgg(p: 0.95),
        isFalse,
      );
    });
  });

  group('Measure equality', () {
    test('CountMeasure equal iff label matches', () {
      expect(const CountMeasure(), const CountMeasure());
      expect(const CountMeasure(label: 'a'), const CountMeasure(label: 'a'));
      expect(
        const CountMeasure(label: 'a') == const CountMeasure(label: 'b'),
        isFalse,
      );
    });

    test('FieldMeasure equal iff fieldRef, aggregation, and label match', () {
      final a = FieldMeasure(
        fieldRef: ref('tasks', 'priority'),
        aggregation: const SumAgg(),
      );
      final aSame = FieldMeasure(
        fieldRef: ref('tasks', 'priority'),
        aggregation: const SumAgg(),
      );
      expect(a, aSame);
      expect(a.hashCode, aSame.hashCode);

      // Differ in aggregation.
      expect(
        a ==
            FieldMeasure(
              fieldRef: ref('tasks', 'priority'),
              aggregation: const AverageAgg(),
            ),
        isFalse,
      );
      // Differ in fieldRef.
      expect(
        a ==
            FieldMeasure(
              fieldRef: ref('tasks', 'title'),
              aggregation: const SumAgg(),
            ),
        isFalse,
      );
      // Differ in label.
      expect(
        a ==
            FieldMeasure(
              fieldRef: ref('tasks', 'priority'),
              aggregation: const SumAgg(),
              label: 'x',
            ),
        isFalse,
      );
    });

    test('StreakMeasure equal iff every field matches', () {
      StreakMeasure build({int? topN}) => StreakMeasure(
        entityIdField: ref('events', 'kind'),
        scheduledDateField: ref('events', 'occurredAt'),
        statusField: ref('events', 'kind'),
        completedStatusValue: 'done',
        topN: topN,
      );
      expect(build(topN: 5), build(topN: 5));
      expect(build(topN: 5) == build(topN: 10), isFalse);
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // GroupBy, Sort, HavingClause, DerivedOp
  // ────────────────────────────────────────────────────────────────────

  group('GroupBy, Sort, HavingClause, DerivedOp equality', () {
    test('FieldGroupBy and TimeGroupBy compare by their structural fields', () {
      expect(
        FieldGroupBy(fieldRef: ref('tasks', 'status')),
        FieldGroupBy(fieldRef: ref('tasks', 'status')),
      );
      expect(
        TimeGroupBy(
          dateFieldRef: ref('events', 'occurredAt'),
          grain: TimeGrain.day,
        ),
        TimeGroupBy(
          dateFieldRef: ref('events', 'occurredAt'),
          grain: TimeGrain.day,
        ),
      );
      // Different grain → unequal.
      expect(
        TimeGroupBy(
              dateFieldRef: ref('events', 'occurredAt'),
              grain: TimeGrain.day,
            ) ==
            TimeGroupBy(
              dateFieldRef: ref('events', 'occurredAt'),
              grain: TimeGrain.week,
            ),
        isFalse,
      );
    });

    test('GroupBy.label is excluded from == and hashCode', () {
      // Display labels are a presentation concern; two queries that
      // differ only by alias must still compare structurally equal so
      // paired-query alignability is preserved.
      final a = FieldGroupBy(fieldRef: ref('tasks', 'status'));
      final b = FieldGroupBy(
        fieldRef: ref('tasks', 'status'),
        label: 'category',
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));

      final t1 = TimeGroupBy(
        dateFieldRef: ref('events', 'occurredAt'),
        grain: TimeGrain.day,
      );
      final t2 = TimeGroupBy(
        dateFieldRef: ref('events', 'occurredAt'),
        grain: TimeGrain.day,
        label: 'day',
      );
      expect(t1, equals(t2));
      expect(t1.hashCode, equals(t2.hashCode));
    });

    test('GroupBy.effectiveLabel falls back to the underlying field id', () {
      expect(
        FieldGroupBy(fieldRef: ref('tasks', 'status')).effectiveLabel,
        'status',
      );
      expect(
        FieldGroupBy(
          fieldRef: ref('tasks', 'status'),
          label: 'category',
        ).effectiveLabel,
        'category',
      );
      expect(
        TimeGroupBy(
          dateFieldRef: ref('events', 'occurredAt'),
          grain: TimeGrain.day,
        ).effectiveLabel,
        'occurredAt',
      );
    });

    test('Sort and SortTarget compare structurally', () {
      const asc = Sort(
        target: MeasureValueSort(),
        direction: SortDirection.ascending,
      );
      const ascSame = Sort(
        target: MeasureValueSort(),
        direction: SortDirection.ascending,
      );
      expect(asc, ascSame);
      // Different direction.
      const desc = Sort(
        target: MeasureValueSort(),
        direction: SortDirection.descending,
      );
      expect(asc == desc, isFalse);
      // MeasureValueSort label affects equality.
      expect(
        const MeasureValueSort(measureLabel: 'a') ==
            const MeasureValueSort(measureLabel: 'b'),
        isFalse,
      );
    });

    test('Sort.forceNullsLast is included in equality and hashCode', () {
      // forceNullsLast changes runtime ordering, so two sorts that
      // differ only by the knob are NOT equal — the opposite
      // treatment from GroupBy.label.
      const a = Sort(
        target: MeasureValueSort(),
        direction: SortDirection.ascending,
      );
      const b = Sort(
        target: MeasureValueSort(),
        direction: SortDirection.ascending,
        forceNullsLast: true,
      );
      expect(a == b, isFalse);
      expect(a.hashCode == b.hashCode, isFalse);
    });

    test('HavingClause compares structurally on all three fields', () {
      const base = HavingClause(
        operator: HavingOperator.greaterThan,
        threshold: IntValue(5),
      );
      expect(
        base,
        const HavingClause(
          operator: HavingOperator.greaterThan,
          threshold: IntValue(5),
        ),
      );
      // Different threshold.
      expect(
        base ==
            const HavingClause(
              operator: HavingOperator.greaterThan,
              threshold: IntValue(6),
            ),
        isFalse,
      );
      // Different operator.
      expect(
        base ==
            const HavingClause(
              operator: HavingOperator.lessThan,
              threshold: IntValue(5),
            ),
        isFalse,
      );
    });

    test(
      'DerivedOperation singletons compare equal; MovingAverageOp by window',
      () {
        expect(const NoDerivedOp(), const NoDerivedOp());
        expect(const CumulativeSumOp(), const CumulativeSumOp());
        expect(const DeltaOp(), const DeltaOp());
        expect(
          const MovingAverageOp(window: 7),
          const MovingAverageOp(window: 7),
        );
        expect(
          const MovingAverageOp(window: 7) == const MovingAverageOp(window: 14),
          isFalse,
        );
      },
    );
  });

  // ────────────────────────────────────────────────────────────────────
  // Filter, AnalyticsQuerySpec
  // ────────────────────────────────────────────────────────────────────

  group('Filter and AnalyticsQuerySpec equality', () {
    test('Filter compares by fieldRef, operator, and value', () {
      final base = Filter(
        fieldRef: ref('tasks', 'priority'),
        operator: FilterOperator.equals,
        value: const IntValue(3),
      );
      expect(
        base,
        Filter(
          fieldRef: ref('tasks', 'priority'),
          operator: FilterOperator.equals,
          value: const IntValue(3),
        ),
      );
      expect(
        base ==
            Filter(
              fieldRef: ref('tasks', 'priority'),
              operator: FilterOperator.equals,
              value: const IntValue(4),
            ),
        isFalse,
      );
    });

    test('AnalyticsQuerySpec compares structurally; list order matters', () {
      AnalyticsQuerySpec build() => AnalyticsQuerySpec(
        source: 'tasks',
        measures: [
          FieldMeasure(
            fieldRef: ref('tasks', 'priority'),
            aggregation: const SumAgg(),
          ),
        ],
        filters: [
          Filter(
            fieldRef: ref('tasks', 'status'),
            operator: FilterOperator.equals,
            value: const EnumValue('done'),
          ),
        ],
        groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
        limit: 5,
      );
      expect(build(), build());
      expect(build().hashCode, build().hashCode);

      // Re-ordered measures → unequal.
      final aMeasures = AnalyticsQuerySpec(
        source: 'tasks',
        measures: const [
          CountMeasure(label: 'a'),
          CountMeasure(label: 'b'),
        ],
      );
      final bMeasures = AnalyticsQuerySpec(
        source: 'tasks',
        measures: const [
          CountMeasure(label: 'b'),
          CountMeasure(label: 'a'),
        ],
      );
      expect(aMeasures == bMeasures, isFalse);
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // BucketKey, RowKey
  // ────────────────────────────────────────────────────────────────────

  group('BucketKey and RowKey equality', () {
    test('BucketKey subtypes compare by their wrapped value', () {
      expect(const StringBucketKey('x'), const StringBucketKey('x'));
      expect(const EnumBucketKey('done'), const EnumBucketKey('done'));
      expect(const IntBucketKey(1), const IntBucketKey(1));
      expect(const BoolBucketKey(true), const BoolBucketKey(true));
      expect(const NullBucketKey(), const NullBucketKey());
      // Different content.
      expect(const StringBucketKey('a') == const StringBucketKey('b'), isFalse);
    });

    test('RowKey compares element-wise', () {
      expect(
        RowKey(const [StringBucketKey('a'), IntBucketKey(1)]),
        RowKey(const [StringBucketKey('a'), IntBucketKey(1)]),
      );
      expect(
        RowKey(const [StringBucketKey('a')]) ==
            RowKey(const [StringBucketKey('b')]),
        isFalse,
      );
      // Empty row keys compare equal.
      expect(RowKey(const []), RowKey(const []));
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // Date-range types
  // ────────────────────────────────────────────────────────────────────

  group('WidgetDateRange and DateRangeMode equality', () {
    test('PresetRange and CustomRange compare structurally', () {
      expect(
        const PresetRange(preset: DateRangePreset.last7Days),
        const PresetRange(preset: DateRangePreset.last7Days),
      );
      expect(
        const PresetRange(preset: DateRangePreset.last7Days) ==
            const PresetRange(preset: DateRangePreset.last30Days),
        isFalse,
      );
      final c = CustomRange(
        start: DateTime(2026, 5, 1),
        end: DateTime(2026, 5, 11),
      );
      expect(
        c,
        CustomRange(start: DateTime(2026, 5, 1), end: DateTime(2026, 5, 11)),
      );
    });

    test('DateRangeMode subtypes compare structurally', () {
      expect(const UsePageRange(), const UsePageRange());
      expect(const NoDateRange(), const NoDateRange());
      expect(const UsePageRange() == const NoDateRange(), isFalse);
      expect(
        const FixedOverride(
          range: PresetRange(preset: DateRangePreset.thisMonth),
        ),
        const FixedOverride(
          range: PresetRange(preset: DateRangePreset.thisMonth),
        ),
      );
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // AnalyticsWidgetSpec — intentionally id-based
  // ────────────────────────────────────────────────────────────────────

  group('AnalyticsWidgetSpec is id-based, not structural', () {
    test('same id with different content is equal; different id is not', () {
      final t = DateTime(2026, 1, 1);
      AnalyticsWidgetSpec build(String id, String title) => AnalyticsWidgetSpec(
        id: id,
        title: title,
        queryJson: '{}',
        displayJson: '{}',
        dateRangeModeJson: '{}',
        sortOrder: 0,
        createdAt: t,
        updatedAt: t,
      );
      expect(build('w1', 'A'), build('w1', 'B (different title)'));
      expect(build('w1', 'A') == build('w2', 'A'), isFalse);
    });
  });
}
