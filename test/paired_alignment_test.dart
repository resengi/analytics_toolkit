import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:test/test.dart';

import '_fixtures.dart';

/// Paired-query alignability rules.
///
/// Paired queries must produce results with a shared x-axis. The
/// validator enforces this by requiring both halves to infer to a
/// series shape, and additionally requiring matching `groupBys` for
/// same-source pairs and matching grain for cross-source pairs.
void main() {
  final tasks = tasksSource();
  final events = eventsSource();

  // A second temporal source for cross-source pair tests.
  final events2 = SourceDef(
    sourceId: 'events2',
    displayName: 'Events 2',
    fields: const [
      FieldDef(
        sourceId: 'events2',
        fieldId: 'at',
        displayName: 'At',
        fieldType: FieldType.dateTime,
        filterable: true,
        groupable: true,
        aggregatable: false,
        sortable: true,
      ),
      FieldDef(
        sourceId: 'events2',
        fieldId: 'kind',
        displayName: 'Kind',
        fieldType: FieldType.enumeration,
        filterable: true,
        groupable: true,
        aggregatable: false,
        sortable: true,
      ),
    ],
    primaryDateFieldId: 'at',
  );

  // A source without primaryDateFieldId so we can exercise the
  // cross-source-requires-primaryDateFieldId rule.
  final eventsNoDate = SourceDef(
    sourceId: 'eventsNoDate',
    displayName: 'Events (no date)',
    fields: const [
      FieldDef(
        sourceId: 'eventsNoDate',
        fieldId: 'whenever',
        displayName: 'Whenever',
        fieldType: FieldType.dateTime,
        filterable: true,
        groupable: true,
        aggregatable: false,
        sortable: true,
      ),
      FieldDef(
        sourceId: 'eventsNoDate',
        fieldId: 'kind',
        displayName: 'Kind',
        fieldType: FieldType.enumeration,
        filterable: true,
        groupable: true,
        aggregatable: false,
        sortable: true,
      ),
    ],
    // no primaryDateFieldId
  );

  final allSources = [tasks, events, events2, eventsNoDate];

  Result<Unit, AnalyticsError> validatePaired(
    AnalyticsQuerySpec xQ,
    AnalyticsQuerySpec yQ, {
    DateRangeMode mode = const NoDateRange(),
    List<SourceDef>? sources,
  }) {
    return QueryValidator.validateWidgetPayload(
      payload: PairedQuerySpec(xQuery: xQ, yQuery: yQ),
      sources: sources ?? allSources,
      dateRangeMode: mode,
    );
  }

  // For pairs whose halves both `supportsDateRange: true`, the
  // cross-rule requires a non-NoDateRange mode. Any FixedOverride
  // works for that purpose.
  final fixedRange = FixedOverride(
    range: CustomRange(
      start: DateTime.utc(2026, 1, 1),
      end: DateTime.utc(2026, 1, 31),
    ),
  );

  // ────────────────────────────────────────────────────────────────────
  // Same-source pairs
  // ────────────────────────────────────────────────────────────────────

  group('same-source pair — both halves must infer to series shape', () {
    test('both halves ungrouped (each scalar) is rejected', () {
      final result = validatePaired(
        AnalyticsQuerySpec(source: 'events', measures: const [CountMeasure()]),
        AnalyticsQuerySpec(source: 'events', measures: const [CountMeasure()]),
      );
      expect(result.isErr, isTrue);
      expect(
        result.errOrNull!.kind,
        AnalyticsErrorKind.incompatiblePairedQueryShapes,
      );
    });

    test('one multi-measure half (multiMeasureSeries shape) is rejected', () {
      final result = validatePaired(
        AnalyticsQuerySpec(
          source: 'events',
          measures: const [CountMeasure()],
          groupBys: [
            TimeGroupBy(
              dateFieldRef: ref('events', 'occurredAt'),
              grain: TimeGrain.day,
            ),
          ],
        ),
        AnalyticsQuerySpec(
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
        mode: fixedRange,
      );
      expect(result.isErr, isTrue);
      expect(
        result.errOrNull!.kind,
        AnalyticsErrorKind.incompatiblePairedQueryShapes,
      );
    });
  });

  group('same-source pair — group-by shapes must match', () {
    test('matching FieldGroupBy on same source is accepted', () {
      final result = validatePaired(
        AnalyticsQuerySpec(
          source: 'tasks',
          measures: const [CountMeasure()],
          groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
        ),
        AnalyticsQuerySpec(
          source: 'tasks',
          measures: [
            FieldMeasure(
              fieldRef: ref('tasks', 'priority'),
              aggregation: const SumAgg(),
            ),
          ],
          groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
        ),
        mode: fixedRange,
      );
      expect(result.isOk, isTrue);
    });

    test('matching TimeGroupBy on same source is accepted', () {
      final result = validatePaired(
        AnalyticsQuerySpec(
          source: 'events',
          measures: const [CountMeasure()],
          groupBys: [
            TimeGroupBy(
              dateFieldRef: ref('events', 'occurredAt'),
              grain: TimeGrain.day,
            ),
          ],
        ),
        AnalyticsQuerySpec(
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
        mode: fixedRange,
      );
      expect(result.isOk, isTrue);
    });

    test('mismatched group-by shapes on same source are rejected', () {
      // One half groups by time, the other by a categorical field —
      // their x-axes are incompatible.
      final result = validatePaired(
        AnalyticsQuerySpec(
          source: 'events',
          measures: const [CountMeasure()],
          groupBys: [
            TimeGroupBy(
              dateFieldRef: ref('events', 'occurredAt'),
              grain: TimeGrain.day,
            ),
          ],
        ),
        AnalyticsQuerySpec(
          source: 'events',
          measures: const [CountMeasure()],
          groupBys: [FieldGroupBy(fieldRef: ref('events', 'kind'))],
        ),
      );
      expect(result.isErr, isTrue);
      expect(
        result.errOrNull!.kind,
        AnalyticsErrorKind.incompatiblePairedQueryShapes,
      );
    });

    test('TimeGroupBy with different grains on same source is rejected', () {
      final result = validatePaired(
        AnalyticsQuerySpec(
          source: 'events',
          measures: const [CountMeasure()],
          groupBys: [
            TimeGroupBy(
              dateFieldRef: ref('events', 'occurredAt'),
              grain: TimeGrain.day,
            ),
          ],
        ),
        AnalyticsQuerySpec(
          source: 'events',
          measures: const [CountMeasure()],
          groupBys: [
            TimeGroupBy(
              dateFieldRef: ref('events', 'occurredAt'),
              grain: TimeGrain.week,
            ),
          ],
        ),
      );
      expect(result.isErr, isTrue);
      expect(
        result.errOrNull!.kind,
        AnalyticsErrorKind.incompatiblePairedQueryShapes,
      );
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // Cross-source pairs
  // ────────────────────────────────────────────────────────────────────

  group(
    'cross-source pair — requires temporal grouping with matching grain',
    () {
      test('matching grain across two temporal sources is accepted', () {
        final result = validatePaired(
          AnalyticsQuerySpec(
            source: 'events',
            measures: const [CountMeasure()],
            groupBys: [
              TimeGroupBy(
                dateFieldRef: ref('events', 'occurredAt'),
                grain: TimeGrain.day,
              ),
            ],
          ),
          AnalyticsQuerySpec(
            source: 'events2',
            measures: const [CountMeasure()],
            groupBys: [
              TimeGroupBy(
                dateFieldRef: ref('events2', 'at'),
                grain: TimeGrain.day,
              ),
            ],
          ),
          mode: fixedRange,
        );
        expect(result.isOk, isTrue);
      });

      test('non-temporal cross-source pair is rejected', () {
        final result = validatePaired(
          AnalyticsQuerySpec(
            source: 'events',
            measures: const [CountMeasure()],
            groupBys: [FieldGroupBy(fieldRef: ref('events', 'kind'))],
          ),
          AnalyticsQuerySpec(
            source: 'events2',
            measures: const [CountMeasure()],
            groupBys: [FieldGroupBy(fieldRef: ref('events2', 'kind'))],
          ),
        );
        expect(result.isErr, isTrue);
        expect(
          result.errOrNull!.kind,
          AnalyticsErrorKind.incompatiblePairedQueryShapes,
        );
      });

      test(
        'cross-source pair requires both sources to have a primary date field',
        () {
          // eventsNoDate has no primaryDateFieldId; a cross-source pair
          // that grouping by time on it cannot align.
          final result = validatePaired(
            AnalyticsQuerySpec(
              source: 'events',
              measures: const [CountMeasure()],
              groupBys: [
                TimeGroupBy(
                  dateFieldRef: ref('events', 'occurredAt'),
                  grain: TimeGrain.day,
                ),
              ],
            ),
            AnalyticsQuerySpec(
              source: 'eventsNoDate',
              measures: const [CountMeasure()],
              groupBys: [
                TimeGroupBy(
                  dateFieldRef: ref('eventsNoDate', 'whenever'),
                  grain: TimeGrain.day,
                ),
              ],
            ),
            mode: fixedRange,
          );
          expect(result.isErr, isTrue);
          expect(
            result.errOrNull!.kind,
            AnalyticsErrorKind.primaryDateFieldRequiredForOperation,
          );
        },
      );
    },
  );
}
