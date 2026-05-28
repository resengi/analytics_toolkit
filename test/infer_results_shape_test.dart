import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:test/test.dart';

import '_fixtures.dart';

/// `InferResultShape` dispatch table, plus the executor cross-check
/// that `AnalyticsExecutor.execute(...)` returns the same runtime
/// shape that inference predicts.
///
/// Inference is a pure function: `(groupBys.length, measures.length)`
/// (plus streak / paired short-circuits) → `ResultShape`. The
/// executor implements the same table in its branching, so the two
/// must agree. Tests below pin both.
void main() {
  final tasks = tasksSource();
  final events = eventsSource();

  StreakMeasure streakOnEvents() => StreakMeasure(
    entityIdField: ref('events', 'kind'),
    scheduledDateField: ref('events', 'occurredAt'),
    statusField: ref('events', 'kind'),
    completedStatusValue: 'done',
  );

  // ────────────────────────────────────────────────────────────────────
  // InferResultShape.ofQuery — every cell of the dispatch table
  // ────────────────────────────────────────────────────────────────────

  group('ofQuery — single-measure dispatch table', () {
    test('(0, 1) → scalar', () {
      final q = AnalyticsQuerySpec(
        source: 'tasks',
        measures: const [CountMeasure()],
      );
      expect(InferResultShape.ofQuery(q), ResultShape.scalar);
    });

    test('(1, 1) → series', () {
      final q = AnalyticsQuerySpec(
        source: 'tasks',
        measures: const [CountMeasure()],
        groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
      );
      expect(InferResultShape.ofQuery(q), ResultShape.series);
    });

    test('(2, 1) → multiSeries', () {
      final q = AnalyticsQuerySpec(
        source: 'tasks',
        measures: const [CountMeasure()],
        groupBys: [
          FieldGroupBy(fieldRef: ref('tasks', 'status')),
          FieldGroupBy(fieldRef: ref('tasks', 'priority')),
        ],
      );
      expect(InferResultShape.ofQuery(q), ResultShape.multiSeries);
    });

    test('(3, 1) → table', () {
      final s = SourceDef(
        sourceId: 'three',
        displayName: 'Three',
        fields: const [
          FieldDef(
            sourceId: 'three',
            fieldId: 'a',
            displayName: 'A',
            fieldType: FieldType.enumeration,
            filterable: true,
            groupable: true,
            aggregatable: false,
            sortable: true,
          ),
          FieldDef(
            sourceId: 'three',
            fieldId: 'b',
            displayName: 'B',
            fieldType: FieldType.enumeration,
            filterable: true,
            groupable: true,
            aggregatable: false,
            sortable: true,
          ),
          FieldDef(
            sourceId: 'three',
            fieldId: 'c',
            displayName: 'C',
            fieldType: FieldType.enumeration,
            filterable: true,
            groupable: true,
            aggregatable: false,
            sortable: true,
          ),
        ],
      );
      final q = AnalyticsQuerySpec(
        source: 'three',
        measures: const [CountMeasure()],
        groupBys: [
          FieldGroupBy(fieldRef: ref('three', 'a')),
          FieldGroupBy(fieldRef: ref('three', 'b')),
          FieldGroupBy(fieldRef: ref('three', 'c')),
        ],
      );
      expect(InferResultShape.ofQuery(q), ResultShape.table);
      // Source unused by inference, but kept on hand if needed.
      expect(s.fields, hasLength(3));
    });
  });

  group('ofQuery — multi-measure dispatch table', () {
    test('(0, N) → table', () {
      final q = AnalyticsQuerySpec(
        source: 'tasks',
        measures: const [
          CountMeasure(label: 'a'),
          CountMeasure(label: 'b'),
        ],
      );
      expect(InferResultShape.ofQuery(q), ResultShape.table);
    });

    test('(1, N) → multiMeasureSeries', () {
      final q = AnalyticsQuerySpec(
        source: 'tasks',
        measures: const [
          CountMeasure(label: 'a'),
          CountMeasure(label: 'b'),
        ],
        groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
      );
      expect(InferResultShape.ofQuery(q), ResultShape.multiMeasureSeries);
    });

    test('(2, N) → table', () {
      final q = AnalyticsQuerySpec(
        source: 'tasks',
        measures: const [
          CountMeasure(label: 'a'),
          CountMeasure(label: 'b'),
        ],
        groupBys: [
          FieldGroupBy(fieldRef: ref('tasks', 'status')),
          FieldGroupBy(fieldRef: ref('tasks', 'priority')),
        ],
      );
      expect(InferResultShape.ofQuery(q), ResultShape.table);
    });
  });

  group('ofQuery — streak short-circuit', () {
    test('streak measure returns table regardless of group-by count', () {
      final q = AnalyticsQuerySpec(
        source: 'events',
        measures: [streakOnEvents()],
      );
      expect(InferResultShape.ofQuery(q), ResultShape.table);
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // InferResultShape.ofPayload — Single delegates, Paired short-circuits
  // ────────────────────────────────────────────────────────────────────

  group('ofPayload — Single and Paired', () {
    test('SingleQuerySpec delegates to ofQuery', () {
      final q = AnalyticsQuerySpec(
        source: 'tasks',
        measures: const [CountMeasure()],
        groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
      );
      expect(
        InferResultShape.ofPayload(SingleQuerySpec(query: q)),
        InferResultShape.ofQuery(q),
      );
    });

    test('PairedQuerySpec returns pairedSeries unconditionally', () {
      // Even if the inner queries would individually infer to
      // something else, the paired payload short-circuits to
      // pairedSeries.
      final inner = AnalyticsQuerySpec(
        source: 'tasks',
        measures: const [CountMeasure()],
      );
      expect(
        InferResultShape.ofPayload(
          PairedQuerySpec(xQuery: inner, yQuery: inner),
        ),
        ResultShape.pairedSeries,
      );
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // Executor cross-check — runtime type matches inferred shape
  // ────────────────────────────────────────────────────────────────────

  group('executor returns the shape inference reports', () {
    test('(0, 1) executes to ScalarResult', () {
      final q = AnalyticsQuerySpec(
        source: 'tasks',
        measures: const [CountMeasure()],
      );
      final result = AnalyticsExecutor.execute(
        query: q,
        records: const <SourceRecord>[],
        sources: [tasks],
      );
      expect(result.okOrNull, isA<ScalarResult>());
    });

    test('(1, 1) executes to SeriesResult', () {
      final q = AnalyticsQuerySpec(
        source: 'tasks',
        measures: const [CountMeasure()],
        groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
      );
      final result = AnalyticsExecutor.execute(
        query: q,
        records: [
          SourceRecord(fields: {'status': const EnumValue('a')}),
        ],
        sources: [tasks],
      );
      expect(result.okOrNull, isA<SeriesResult>());
    });

    test('(2, 1) executes to MultiSeriesResult', () {
      final q = AnalyticsQuerySpec(
        source: 'tasks',
        measures: const [CountMeasure()],
        groupBys: [
          FieldGroupBy(fieldRef: ref('tasks', 'status')),
          FieldGroupBy(fieldRef: ref('tasks', 'priority')),
        ],
      );
      final result = AnalyticsExecutor.execute(
        query: q,
        records: [
          SourceRecord(
            fields: {
              'status': const EnumValue('a'),
              'priority': const IntValue(1),
            },
          ),
        ],
        sources: [tasks],
      );
      expect(result.okOrNull, isA<MultiSeriesResult>());
    });

    test('(0, N) executes to TableResult', () {
      final q = AnalyticsQuerySpec(
        source: 'tasks',
        measures: const [
          CountMeasure(label: 'a'),
          CountMeasure(label: 'b'),
        ],
      );
      final result = AnalyticsExecutor.execute(
        query: q,
        records: const <SourceRecord>[],
        sources: [tasks],
      );
      expect(result.okOrNull, isA<TableResult>());
    });

    test('(1, N) executes to MultiMeasureSeriesResult', () {
      final q = AnalyticsQuerySpec(
        source: 'tasks',
        measures: const [
          CountMeasure(label: 'a'),
          CountMeasure(label: 'b'),
        ],
        groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
      );
      final result = AnalyticsExecutor.execute(
        query: q,
        records: [
          SourceRecord(fields: {'status': const EnumValue('a')}),
        ],
        sources: [tasks],
      );
      expect(result.okOrNull, isA<MultiMeasureSeriesResult>());
    });

    test('streak query executes to TableResult', () {
      final q = AnalyticsQuerySpec(
        source: 'events',
        measures: [streakOnEvents()],
      );
      final result = AnalyticsExecutor.execute(
        query: q,
        records: const <SourceRecord>[],
        sources: [events],
        asOf: DateTime(2026, 1, 1),
      );
      expect(result.okOrNull, isA<TableResult>());
    });
  });
}
