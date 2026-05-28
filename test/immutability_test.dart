import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:test/test.dart';

import '_fixtures.dart';

/// Defensive-copy and constructor-invariant contracts.
///
/// Every container that takes a list-valued parameter stores an
/// unmodifiable copy; post-construction mutation of the caller's list
/// must not be visible through the container, and the accessor itself
/// must reject in-place mutation. Constructor invariants (`SourceDef`
/// requires unique field IDs, `CustomRange` rejects reversed ranges,
/// `TimeGrain` rejects nonsensical `count`/`weekStartDay` values)
/// throw `ArgumentError`.
///
/// One test per family, with multiple `expect`s exhausting the
/// accessors for that family. Failure messages include the failing
/// accessor so locating is direct.
void main() {
  // ────────────────────────────────────────────────────────────────────
  // AnalyticsQuerySpec — list-valued fields are unmodifiable
  // ────────────────────────────────────────────────────────────────────

  group('AnalyticsQuerySpec', () {
    test(
      'measures, filters, and groupBys are unmodifiable through accessors',
      () {
        final spec = AnalyticsQuerySpec(
          source: 'tasks',
          measures: const [CountMeasure()],
          filters: [
            Filter(
              fieldRef: ref('tasks', 'priority'),
              operator: FilterOperator.equals,
              value: const IntValue(1),
            ),
          ],
          groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
        );
        expect(
          () => spec.measures.add(const CountMeasure()),
          throwsUnsupportedError,
          reason: 'measures',
        );
        expect(
          () => spec.filters.add(
            Filter(
              fieldRef: ref('tasks', 'priority'),
              operator: FilterOperator.equals,
              value: const IntValue(2),
            ),
          ),
          throwsUnsupportedError,
          reason: 'filters',
        );
        expect(
          () => spec.groupBys.add(
            FieldGroupBy(fieldRef: ref('tasks', 'priority')),
          ),
          throwsUnsupportedError,
          reason: 'groupBys',
        );
      },
    );

    test(
      'mutating the caller list after construction does not affect the spec',
      () {
        final mutMeasures = <Measure>[const CountMeasure(label: 'a')];
        final spec = AnalyticsQuerySpec(source: 'tasks', measures: mutMeasures);
        mutMeasures.add(const CountMeasure(label: 'b'));
        expect(spec.measures, hasLength(1));
      },
    );

    test('withAdditionalFilters always returns a new instance', () {
      final spec = AnalyticsQuerySpec(
        source: 'tasks',
        measures: const [CountMeasure()],
      );
      // Even with empty extra, the result is a new instance — but
      // value-equal.
      final copy = spec.withAdditionalFilters(const []);
      expect(identical(copy, spec), isFalse);
      expect(copy, spec);
    });

    test('withAdditionalFilters appends in order', () {
      final spec = AnalyticsQuerySpec(
        source: 'tasks',
        measures: const [CountMeasure()],
        filters: [
          Filter(
            fieldRef: ref('tasks', 'priority'),
            operator: FilterOperator.equals,
            value: const IntValue(1),
          ),
        ],
      );
      final extra = [
        Filter(
          fieldRef: ref('tasks', 'status'),
          operator: FilterOperator.equals,
          value: const EnumValue('done'),
        ),
      ];
      final result = spec.withAdditionalFilters(extra);
      expect(result.filters, [spec.filters[0], extra[0]]);
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // SourceRecord, list-valued TypedValues
  // ────────────────────────────────────────────────────────────────────

  group('SourceRecord and list-valued TypedValues', () {
    test('SourceRecord.fields is unmodifiable and copies on construct', () {
      final mut = <String, TypedValue>{'k': const IntValue(1)};
      final record = SourceRecord(fields: mut);
      // Read-only accessor.
      expect(
        () => record.fields['k'] = const IntValue(2),
        throwsUnsupportedError,
      );
      // Caller-side mutation doesn't leak.
      mut['k'] = const IntValue(99);
      expect(record.fields['k'], const IntValue(1));
    });

    test(
      'list-valued TypedValues copy on construct and reject in-place mutation',
      () {
        // Verify the pattern for one int and one string list — same
        // contract for all list-valued TypedValues.
        final mutInts = <int>[1, 2];
        final iv = IntListValue(mutInts);
        mutInts.add(3);
        expect(iv.values, [1, 2]);
        expect(() => iv.values.add(99), throwsUnsupportedError);

        final mutStrs = <String>['a', 'b'];
        final sv = StringListValue(mutStrs);
        mutStrs.add('c');
        expect(sv.values, ['a', 'b']);
        expect(() => sv.values.add('z'), throwsUnsupportedError);
      },
    );
  });

  // ────────────────────────────────────────────────────────────────────
  // SourceDef constructor invariants
  // ────────────────────────────────────────────────────────────────────

  group('SourceDef', () {
    FieldDef field(
      String sourceId,
      String fieldId, [
      FieldType type = FieldType.string,
    ]) => FieldDef(
      sourceId: sourceId,
      fieldId: fieldId,
      displayName: fieldId,
      fieldType: type,
      filterable: true,
      groupable: true,
      aggregatable: false,
      sortable: true,
    );

    test('rejects misconfigured fields with ArgumentError', () {
      // Mismatched sourceId on the inner field.
      expect(
        () => SourceDef(
          sourceId: 'tasks',
          displayName: 'Tasks',
          fields: [field('other', 'status')],
        ),
        throwsArgumentError,
        reason: 'cross-source field',
      );
      // Duplicate fieldId.
      expect(
        () => SourceDef(
          sourceId: 'tasks',
          displayName: 'Tasks',
          fields: [field('tasks', 'status'), field('tasks', 'status')],
        ),
        throwsArgumentError,
        reason: 'duplicate fieldId',
      );
      // primaryDateFieldId points to a non-existent field.
      expect(
        () => SourceDef(
          sourceId: 'tasks',
          displayName: 'Tasks',
          fields: [field('tasks', 'status')],
          primaryDateFieldId: 'nope',
        ),
        throwsArgumentError,
        reason: 'unknown primaryDateFieldId',
      );
      // primaryDateFieldId points to a non-dateTime field.
      expect(
        () => SourceDef(
          sourceId: 'tasks',
          displayName: 'Tasks',
          fields: [field('tasks', 'status')],
          primaryDateFieldId: 'status',
        ),
        throwsArgumentError,
        reason: 'non-dateTime primaryDateFieldId',
      );
    });

    test('fields list is unmodifiable through the accessor', () {
      final source = tasksSource();
      expect(
        () => source.fields.add(field('tasks', 'extra')),
        throwsUnsupportedError,
      );
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // Result containers — all list-valued fields unmodifiable
  // ────────────────────────────────────────────────────────────────────

  group('result containers — every list-valued field is unmodifiable', () {
    test(
      'SeriesResult.buckets, MultiSeriesResult.xAxis/series, MultiMeasureSeriesResult.xAxis/series',
      () {
        final series = SeriesResult(
          buckets: const [
            SeriesBucket(key: StringBucketKey('a'), value: IntValue(1)),
          ],
          groupKind: SeriesGroupKind.categorical,
          groupColumnLabel: 'status',
          groupColumnFieldType: FieldType.string,
          measureLabel: 'count',
          measureFieldType: FieldType.integer,
        );
        expect(
          () => series.buckets.add(
            const SeriesBucket(key: StringBucketKey('b'), value: IntValue(2)),
          ),
          throwsUnsupportedError,
          reason: 'SeriesResult.buckets',
        );

        final ms = MultiSeriesResult(
          xAxis: [const XAxisPosition(key: StringBucketKey('a'))],
          series: [
            NamedSeries(
              key: const StringBucketKey('x'),
              values: const [IntValue(1)],
            ),
          ],
          groupKind: SeriesGroupKind.categorical,
          primaryColumnLabel: 'p',
          primaryColumnFieldType: FieldType.string,
          secondaryColumnLabel: 's',
          secondaryColumnFieldType: FieldType.string,
          measureLabel: 'm',
          measureFieldType: FieldType.integer,
        );
        expect(
          () => ms.xAxis.add(const XAxisPosition(key: StringBucketKey('b'))),
          throwsUnsupportedError,
          reason: 'MultiSeriesResult.xAxis',
        );
        expect(
          () => ms.series.add(
            NamedSeries(
              key: const StringBucketKey('y'),
              values: const [IntValue(2)],
            ),
          ),
          throwsUnsupportedError,
          reason: 'MultiSeriesResult.series',
        );

        final mm = MultiMeasureSeriesResult(
          xAxis: [const XAxisPosition(key: StringBucketKey('a'))],
          series: [
            MeasureSeries(
              label: 'm',
              fieldType: FieldType.integer,
              values: const [IntValue(1)],
            ),
          ],
          groupKind: SeriesGroupKind.categorical,
          groupColumnLabel: 'g',
          groupColumnFieldType: FieldType.string,
        );
        expect(
          () => mm.xAxis.add(const XAxisPosition(key: StringBucketKey('b'))),
          throwsUnsupportedError,
          reason: 'MultiMeasureSeriesResult.xAxis',
        );
        expect(
          () => mm.series.add(
            MeasureSeries(
              label: 'm2',
              fieldType: FieldType.integer,
              values: const [IntValue(2)],
            ),
          ),
          throwsUnsupportedError,
          reason: 'MultiMeasureSeriesResult.series',
        );
        expect(
          () => mm.series[0].values.add(const IntValue(2)),
          throwsUnsupportedError,
          reason: 'MeasureSeries.values',
        );
      },
    );

    test('TableResult.columns/rowKeys, TableColumn.values, RowKey.keys', () {
      final t = TableResult(
        columns: [
          TableColumn(
            label: 'm',
            fieldType: FieldType.integer,
            kind: TableColumnKind.measure,
            values: const [IntValue(1)],
          ),
        ],
        rowKeys: [RowKey(const [])],
      );
      expect(
        () => t.columns.add(
          TableColumn(
            label: 'n',
            fieldType: FieldType.integer,
            kind: TableColumnKind.measure,
            values: const [IntValue(2)],
          ),
        ),
        throwsUnsupportedError,
        reason: 'TableResult.columns',
      );
      expect(
        () => t.rowKeys.add(RowKey(const [])),
        throwsUnsupportedError,
        reason: 'TableResult.rowKeys',
      );
      expect(
        () => t.columns[0].values.add(const IntValue(2)),
        throwsUnsupportedError,
        reason: 'TableColumn.values',
      );

      final rk = RowKey(const [StringBucketKey('a')]);
      expect(
        () => rk.keys.add(const StringBucketKey('b')),
        throwsUnsupportedError,
        reason: 'RowKey.keys',
      );
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // Synthetic-tracking sets are unmodifiable
  // ────────────────────────────────────────────────────────────────────

  group('synthetic-tracking sets — unmodifiable and copied on construct', () {
    test(
      'TableResult.syntheticRowIndices is unmodifiable and copies on construct',
      () {
        final mut = <int>{0, 1};
        final t = TableResult(
          columns: [
            TableColumn(
              label: 'm',
              fieldType: FieldType.integer,
              kind: TableColumnKind.measure,
              values: const [IntValue(1), IntValue(2)],
            ),
          ],
          rowKeys: [
            RowKey(const [StringBucketKey('a')]),
            RowKey(const [StringBucketKey('b')]),
          ],
          syntheticRowIndices: mut,
        );
        // Read-only accessor.
        expect(() => t.syntheticRowIndices.add(99), throwsUnsupportedError);
        // Caller-side mutation doesn't leak.
        mut.add(99);
        expect(t.syntheticRowIndices, {0, 1});
      },
    );

    test('NamedSeries.syntheticValueIndices is unmodifiable', () {
      final s = NamedSeries(
        key: const StringBucketKey('x'),
        values: const [IntValue(1)],
        syntheticValueIndices: const {0},
      );
      expect(() => s.syntheticValueIndices.add(99), throwsUnsupportedError);
    });

    test('MultiMeasureSeriesResult.syntheticXAxisIndices is unmodifiable', () {
      final mm = MultiMeasureSeriesResult(
        xAxis: [const XAxisPosition(key: StringBucketKey('a'))],
        series: [
          MeasureSeries(
            label: 'm',
            fieldType: FieldType.integer,
            values: const [IntValue(1)],
          ),
        ],
        groupKind: SeriesGroupKind.categorical,
        groupColumnLabel: 'g',
        groupColumnFieldType: FieldType.string,
        syntheticXAxisIndices: const {0},
      );
      expect(() => mm.syntheticXAxisIndices.add(99), throwsUnsupportedError);
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // CustomRange invariants
  // ────────────────────────────────────────────────────────────────────

  group('CustomRange invariants', () {
    test('start.isAfter(end) throws ArgumentError', () {
      expect(
        () => CustomRange(
          start: DateTime(2026, 5, 10),
          end: DateTime(2026, 5, 1),
        ),
        throwsArgumentError,
      );
    });

    test('start == end produces a one-day window', () {
      final r = CustomRange(
        start: DateTime(2026, 5, 1),
        end: DateTime(2026, 5, 1),
      );
      expect(r.start, DateTime(2026, 5, 1));
      expect(r.endExclusive, DateTime(2026, 5, 2));
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // AnalyticsChange.sourceIds defensive copy
  // ────────────────────────────────────────────────────────────────────

  group('AnalyticsChange', () {
    test('sourceIds set is unmodifiable and copies on construct', () {
      final mut = <String>{'tasks'};
      final change = AnalyticsChange(
        kind: AnalyticsChangeKind.sourceData,
        sourceIds: mut,
      );
      expect(() => change.sourceIds!.add('extra'), throwsUnsupportedError);
      // Caller-side mutation doesn't leak.
      mut.add('events');
      expect(change.sourceIds, {'tasks'});
    });

    test('null sourceIds stays null (no spurious copy)', () {
      final change = AnalyticsChange(kind: AnalyticsChangeKind.sourceData);
      expect(change.sourceIds, isNull);
    });
  });
}
