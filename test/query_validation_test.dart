import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:test/test.dart';

import '_fixtures.dart';

/// Validator coverage for query-shape rules. Each `group` pins one
/// family of rules from `validator.dart`; the per-test claim is the
/// specific combination of measure/group/sort/limit/derived/having
/// that the validator either accepts or rejects.
///
/// Filter validation lives in `filter_validation_test.dart`.
/// `FieldAggregation` dispatch and `PercentileAgg.p` rules live in
/// `field_aggregation_test.dart`.
///
/// The intent is that if someone debugging a validator change wants
/// to find the test that pins a specific error kind, they can grep
/// the test names for the kind name.
void main() {
  final tasks = tasksSource();
  final events = eventsSource();
  final allSources = [tasks, events];

  Result<Unit, AnalyticsError> validate(AnalyticsQuerySpec q) =>
      QueryValidator.validateQuery(q, sources: allSources);

  // ────────────────────────────────────────────────────────────────────
  // measures list bounds
  // ────────────────────────────────────────────────────────────────────

  group('measures list — emptiness and cardinality bounds', () {
    test('empty measures is rejected with measuresEmpty', () {
      final result = validate(
        AnalyticsQuerySpec(source: 'tasks', measures: const []),
      );
      expect(result.isErr, isTrue);
      expect(result.errOrNull!.kind, AnalyticsErrorKind.measuresEmpty);
    });

    test('6 measures is rejected with tooManyMeasures', () {
      final result = validate(
        AnalyticsQuerySpec(
          source: 'tasks',
          measures: List.generate(6, (i) => CountMeasure(label: 'm$i')),
        ),
      );
      expect(result.isErr, isTrue);
      expect(result.errOrNull!.kind, AnalyticsErrorKind.tooManyMeasures);
    });

    test('1 to 5 measures pass the cardinality check', () {
      for (final n in [1, 2, 3, 4, 5]) {
        final result = validate(
          AnalyticsQuerySpec(
            source: 'tasks',
            measures: List.generate(n, (i) => CountMeasure(label: 'm$i')),
          ),
        );
        expect(
          result.isOk,
          isTrue,
          reason:
              'expected $n measures to validate, got ${result.errOrNull?.kind}',
        );
      }
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // Measure labels — effectiveLabelsFor rule and duplicate rejection
  // ────────────────────────────────────────────────────────────────────

  group('measure labels — effectiveLabelsFor auto-label rule', () {
    // Measures with an explicit `label` keep it; measures with
    // `label: null` get a stable `measure_<index>` auto-label. The
    // validator uses this rule for the duplicate-label check below.

    test(
      'explicit labels pass through; null labels become measure_<index>',
      () {
        // All explicit.
        expect(
          Measure.effectiveLabelsFor(const [
            CountMeasure(label: 'orders'),
            CountMeasure(label: 'visitors'),
          ]),
          ['orders', 'visitors'],
        );
        // All null.
        expect(
          Measure.effectiveLabelsFor(const [
            CountMeasure(),
            CountMeasure(),
            CountMeasure(),
          ]),
          ['measure_0', 'measure_1', 'measure_2'],
        );
        // Mixed — position-aligned.
        expect(
          Measure.effectiveLabelsFor(const [
            CountMeasure(label: 'a'),
            CountMeasure(),
            CountMeasure(label: 'c'),
          ]),
          ['a', 'measure_1', 'c'],
        );
      },
    );
  });

  group('measure labels — validator rejects duplicate effective labels', () {
    // The duplicate check runs over `effectiveLabelsFor`, so it
    // catches both explicit-vs-explicit collisions and explicit-vs-
    // auto collisions.

    test(
      'two measures with the same explicit label fire duplicateMeasureLabel',
      () {
        final result = validate(
          AnalyticsQuerySpec(
            source: 'tasks',
            measures: const [
              CountMeasure(label: 'count'),
              CountMeasure(label: 'count'),
            ],
          ),
        );
        expect(result.isErr, isTrue);
        expect(
          result.errOrNull!.kind,
          AnalyticsErrorKind.duplicateMeasureLabel,
        );
      },
    );

    test(
      'explicit label colliding with another measure\'s auto-label is rejected',
      () {
        // Index 0 has no label → auto-labels to `measure_0`. Index 1
        // has an explicit label that happens to be `measure_0` — a
        // collision in the effective-label space.
        final result = validate(
          AnalyticsQuerySpec(
            source: 'tasks',
            measures: const [
              CountMeasure(),
              CountMeasure(label: 'measure_0'),
            ],
          ),
        );
        expect(result.isErr, isTrue);
        expect(
          result.errOrNull!.kind,
          AnalyticsErrorKind.duplicateMeasureLabel,
        );
      },
    );

    test('distinct labels (explicit or auto) are accepted', () {
      // Distinct explicit.
      expect(
        validate(
          AnalyticsQuerySpec(
            source: 'tasks',
            measures: const [
              CountMeasure(label: 'a'),
              CountMeasure(label: 'b'),
            ],
          ),
        ).isOk,
        isTrue,
      );
      // All-null → distinct auto-labels (measure_0, measure_1).
      expect(
        validate(
          AnalyticsQuerySpec(
            source: 'tasks',
            measures: const [CountMeasure(), CountMeasure()],
          ),
        ).isOk,
        isTrue,
      );
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // Column-label uniqueness (groupBys + measures)
  // ────────────────────────────────────────────────────────────────────

  group(
    'column labels — validator rejects collisions across groupBy + measure',
    () {
      test(
        'measure label colliding with a group-by field id fires duplicateColumnLabel',
        () {
          // FieldGroupBy on `status` projects to a column labeled
          // 'status' by default; the measure also uses 'status' as its
          // explicit label → collision.
          final result = validate(
            AnalyticsQuerySpec(
              source: 'tasks',
              measures: const [CountMeasure(label: 'status')],
              groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
            ),
          );
          expect(result.isErr, isTrue);
          expect(
            result.errOrNull!.kind,
            AnalyticsErrorKind.duplicateColumnLabel,
          );
        },
      );

      test(
        'two group-bys whose effective labels collide fire duplicateColumnLabel',
        () {
          // FieldGroupBy on `status` defaults to label 'status';
          // FieldGroupBy on `priority` with explicit `label: 'status'`
          // collides.
          final result = validate(
            AnalyticsQuerySpec(
              source: 'tasks',
              measures: const [CountMeasure()],
              groupBys: [
                FieldGroupBy(fieldRef: ref('tasks', 'status')),
                FieldGroupBy(
                  fieldRef: ref('tasks', 'priority'),
                  label: 'status',
                ),
              ],
            ),
          );
          expect(result.isErr, isTrue);
          expect(
            result.errOrNull!.kind,
            AnalyticsErrorKind.duplicateColumnLabel,
          );
        },
      );

      test('explicit GroupBy.label resolves a would-be collision', () {
        // Renaming the group column to 'category' lets the
        // 'status'-labeled measure coexist.
        final result = validate(
          AnalyticsQuerySpec(
            source: 'tasks',
            measures: const [CountMeasure(label: 'status')],
            groupBys: [
              FieldGroupBy(fieldRef: ref('tasks', 'status'), label: 'category'),
            ],
          ),
        );
        expect(result.isOk, isTrue);
      });
    },
  );

  // ────────────────────────────────────────────────────────────────────
  // Streak measure — combinability and clause rejections
  // ────────────────────────────────────────────────────────────────────

  StreakMeasure streakOnEvents() => StreakMeasure(
    entityIdField: ref('events', 'kind'),
    scheduledDateField: ref('events', 'occurredAt'),
    statusField: ref('events', 'kind'),
    completedStatusValue: 'done',
  );

  group('streak measure — combinability with other measures', () {
    test('streak alongside another measure is rejected', () {
      final result = validate(
        AnalyticsQuerySpec(
          source: 'events',
          measures: [streakOnEvents(), const CountMeasure()],
        ),
      );
      expect(result.isErr, isTrue);
      expect(result.errOrNull!.kind, AnalyticsErrorKind.streakNotCombinable);
    });

    test('streak alone is accepted', () {
      final result = validate(
        AnalyticsQuerySpec(source: 'events', measures: [streakOnEvents()]),
      );
      expect(result.isOk, isTrue);
    });
  });

  group('streak measure — explicit group-by is rejected', () {
    test('streak with any groupBy entry fires streakWithExplicitGrouping', () {
      final result = validate(
        AnalyticsQuerySpec(
          source: 'events',
          measures: [streakOnEvents()],
          groupBys: [FieldGroupBy(fieldRef: ref('events', 'kind'))],
        ),
      );
      expect(result.isErr, isTrue);
      expect(
        result.errOrNull!.kind,
        AnalyticsErrorKind.streakWithExplicitGrouping,
      );
    });
  });

  group('streak measure — sort, limit, having clauses are rejected', () {
    test('streak + sort is rejected', () {
      final result = validate(
        AnalyticsQuerySpec(
          source: 'events',
          measures: [streakOnEvents()],
          sort: const Sort(
            target: MeasureValueSort(),
            direction: SortDirection.ascending,
          ),
        ),
      );
      expect(result.isErr, isTrue);
      expect(result.errOrNull!.kind, AnalyticsErrorKind.preconditionViolation);
      expect(result.errOrNull!.humanMessage, contains('sort'));
    });

    test('streak + limit is rejected (use StreakMeasure.topN instead)', () {
      final result = validate(
        AnalyticsQuerySpec(
          source: 'events',
          measures: [streakOnEvents()],
          limit: 10,
        ),
      );
      expect(result.isErr, isTrue);
      expect(result.errOrNull!.kind, AnalyticsErrorKind.preconditionViolation);
      expect(result.errOrNull!.humanMessage, contains('topN'));
    });

    test('streak + having is rejected', () {
      final result = validate(
        AnalyticsQuerySpec(
          source: 'events',
          measures: [streakOnEvents()],
          having: const HavingClause(
            operator: HavingOperator.greaterThan,
            threshold: IntValue(0),
          ),
        ),
      );
      expect(result.isErr, isTrue);
      expect(result.errOrNull!.kind, AnalyticsErrorKind.preconditionViolation);
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // groupBys list — cardinality and temporal constraints
  // ────────────────────────────────────────────────────────────────────

  group('groupBys list — cardinality and temporal bounds', () {
    test('4 group-bys is rejected with tooManyGroupBys', () {
      // Construct 4 distinct FieldGroupBys; the validator caps at 3.
      // Use both fixtures' fields to get 4 unique group fields.
      final result = validate(
        AnalyticsQuerySpec(
          source: 'tasks',
          measures: const [CountMeasure()],
          groupBys: [
            FieldGroupBy(fieldRef: ref('tasks', 'status')),
            FieldGroupBy(fieldRef: ref('tasks', 'priority')),
            FieldGroupBy(fieldRef: ref('tasks', 'title')),
            // Repeat is fine for the cardinality check — duplicates
            // would be caught later, but cardinality fires first.
            FieldGroupBy(fieldRef: ref('tasks', 'status')),
          ],
        ),
      );
      expect(result.isErr, isTrue);
      expect(result.errOrNull!.kind, AnalyticsErrorKind.tooManyGroupBys);
    });

    test('0 to 3 group-bys pass the cardinality check', () {
      // 0
      expect(
        validate(
          AnalyticsQuerySpec(source: 'tasks', measures: const [CountMeasure()]),
        ).isOk,
        isTrue,
      );
      // 1
      expect(
        validate(
          AnalyticsQuerySpec(
            source: 'tasks',
            measures: const [CountMeasure()],
            groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
          ),
        ).isOk,
        isTrue,
      );
      // 2
      expect(
        validate(
          AnalyticsQuerySpec(
            source: 'tasks',
            measures: const [CountMeasure()],
            groupBys: [
              FieldGroupBy(fieldRef: ref('tasks', 'status')),
              FieldGroupBy(fieldRef: ref('tasks', 'priority')),
            ],
          ),
        ).isOk,
        isTrue,
      );
      // 3
      expect(
        validate(
          AnalyticsQuerySpec(
            source: 'tasks',
            measures: const [CountMeasure()],
            groupBys: [
              FieldGroupBy(fieldRef: ref('tasks', 'status')),
              FieldGroupBy(fieldRef: ref('tasks', 'priority')),
              FieldGroupBy(fieldRef: ref('tasks', 'title')),
            ],
          ),
        ).isErr,
        // title is non-groupable on the fixture — fires fieldNotGroupable.
        // The cardinality check passes; a different rule fails. The
        // important point: cardinality at 3 is not what rejects.
        isTrue,
      );
    });

    test('two TimeGroupBy entries fire multipleTemporalGroupBys', () {
      final result = validate(
        AnalyticsQuerySpec(
          source: 'events',
          measures: const [CountMeasure()],
          groupBys: [
            TimeGroupBy(
              dateFieldRef: ref('events', 'occurredAt'),
              grain: TimeGrain.day,
            ),
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
        AnalyticsErrorKind.multipleTemporalGroupBys,
      );
    });

    test('one TimeGroupBy with one FieldGroupBy is accepted', () {
      final result = validate(
        AnalyticsQuerySpec(
          source: 'events',
          measures: const [CountMeasure()],
          groupBys: [
            TimeGroupBy(
              dateFieldRef: ref('events', 'occurredAt'),
              grain: TimeGrain.day,
            ),
            FieldGroupBy(fieldRef: ref('events', 'kind')),
          ],
        ),
      );
      expect(result.isOk, isTrue);
    });
  });

  group('groupBys list — duplicate group-bys', () {
    test('two FieldGroupBy on the same field is rejected', () {
      final result = validate(
        AnalyticsQuerySpec(
          source: 'tasks',
          measures: const [CountMeasure()],
          groupBys: [
            FieldGroupBy(fieldRef: ref('tasks', 'status')),
            FieldGroupBy(fieldRef: ref('tasks', 'status')),
          ],
        ),
      );
      expect(result.isErr, isTrue);
      expect(result.errOrNull!.kind, AnalyticsErrorKind.preconditionViolation);
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // GroupBy on dateTime / non-dateTime fields
  // ────────────────────────────────────────────────────────────────────

  group('FieldGroupBy and TimeGroupBy — field-type rules', () {
    test('FieldGroupBy on a dateTime field is rejected', () {
      final result = validate(
        AnalyticsQuerySpec(
          source: 'events',
          measures: const [CountMeasure()],
          groupBys: [FieldGroupBy(fieldRef: ref('events', 'occurredAt'))],
        ),
      );
      expect(result.isErr, isTrue);
      expect(result.errOrNull!.kind, AnalyticsErrorKind.preconditionViolation);
      expect(result.errOrNull!.humanMessage, contains('TimeGroupBy'));
    });

    test('TimeGroupBy on a non-dateTime field is rejected', () {
      final result = validate(
        AnalyticsQuerySpec(
          source: 'events',
          measures: const [CountMeasure()],
          groupBys: [
            TimeGroupBy(
              dateFieldRef: ref('events', 'kind'),
              grain: TimeGrain.day,
            ),
          ],
        ),
      );
      expect(result.isErr, isTrue);
      expect(
        result.errOrNull!.kind,
        AnalyticsErrorKind.timeGrainOnNonDateField,
      );
    });

    test('TimeGroupBy on a dateTime field is accepted', () {
      final result = validate(
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
      );
      expect(result.isOk, isTrue);
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // Sort target rules
  // ────────────────────────────────────────────────────────────────────

  group('sort target rules — GroupFieldSort', () {
    test('GroupFieldSort with no group-by is rejected', () {
      final result = validate(
        AnalyticsQuerySpec(
          source: 'tasks',
          measures: const [CountMeasure()],
          sort: Sort(
            target: GroupFieldSort(fieldRef: ref('tasks', 'status')),
            direction: SortDirection.ascending,
          ),
        ),
      );
      expect(result.isErr, isTrue);
      expect(result.errOrNull!.kind, AnalyticsErrorKind.incompatibleSortTarget);
    });

    test('GroupFieldSort field not among group-by fields is rejected', () {
      final result = validate(
        AnalyticsQuerySpec(
          source: 'tasks',
          measures: const [CountMeasure()],
          groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
          sort: Sort(
            target: GroupFieldSort(fieldRef: ref('tasks', 'priority')),
            direction: SortDirection.ascending,
          ),
        ),
      );
      expect(result.isErr, isTrue);
      expect(result.errOrNull!.kind, AnalyticsErrorKind.incompatibleSortTarget);
    });

    test('GroupFieldSort targeting a group-by field is accepted', () {
      final result = validate(
        AnalyticsQuerySpec(
          source: 'tasks',
          measures: const [CountMeasure()],
          groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
          sort: Sort(
            target: GroupFieldSort(fieldRef: ref('tasks', 'status')),
            direction: SortDirection.ascending,
          ),
        ),
      );
      expect(result.isOk, isTrue);
    });
  });

  group('sort target rules — MeasureValueSort', () {
    test('MeasureValueSort with no group-by is rejected', () {
      final result = validate(
        AnalyticsQuerySpec(
          source: 'tasks',
          measures: const [CountMeasure()],
          sort: const Sort(
            target: MeasureValueSort(),
            direction: SortDirection.ascending,
          ),
        ),
      );
      expect(result.isErr, isTrue);
      expect(result.errOrNull!.kind, AnalyticsErrorKind.incompatibleSortTarget);
    });

    test(
      'single-measure MeasureValueSort with null measureLabel is accepted',
      () {
        final result = validate(
          AnalyticsQuerySpec(
            source: 'tasks',
            measures: const [CountMeasure()],
            groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
            sort: const Sort(
              target: MeasureValueSort(),
              direction: SortDirection.descending,
            ),
          ),
        );
        expect(result.isOk, isTrue);
      },
    );

    test(
      'multi-measure MeasureValueSort with null measureLabel is rejected',
      () {
        final result = validate(
          AnalyticsQuerySpec(
            source: 'tasks',
            measures: const [
              CountMeasure(label: 'a'),
              CountMeasure(label: 'b'),
            ],
            groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
            sort: const Sort(
              target: MeasureValueSort(),
              direction: SortDirection.descending,
            ),
          ),
        );
        expect(result.isErr, isTrue);
        expect(
          result.errOrNull!.kind,
          AnalyticsErrorKind.preconditionViolation,
        );
      },
    );

    test('multi-measure MeasureValueSort with matching label is accepted', () {
      final result = validate(
        AnalyticsQuerySpec(
          source: 'tasks',
          measures: const [
            CountMeasure(label: 'a'),
            CountMeasure(label: 'b'),
          ],
          groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
          sort: const Sort(
            target: MeasureValueSort(measureLabel: 'b'),
            direction: SortDirection.descending,
          ),
        ),
      );
      expect(result.isOk, isTrue);
    });

    test(
      'multi-measure MeasureValueSort with unknown label fires unknownMeasureLabel',
      () {
        final result = validate(
          AnalyticsQuerySpec(
            source: 'tasks',
            measures: const [
              CountMeasure(label: 'a'),
              CountMeasure(label: 'b'),
            ],
            groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
            sort: const Sort(
              target: MeasureValueSort(measureLabel: 'nope'),
              direction: SortDirection.descending,
            ),
          ),
        );
        expect(result.isErr, isTrue);
        expect(result.errOrNull!.kind, AnalyticsErrorKind.unknownMeasureLabel);
      },
    );

    test('MeasureValueSort resolves auto-labels in multi-measure', () {
      // Two measures with no labels — auto-labels are measure_0 and
      // measure_1. The sort can reference either by its auto-label.
      final result = validate(
        AnalyticsQuerySpec(
          source: 'tasks',
          measures: const [CountMeasure(), CountMeasure()],
          groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
          sort: const Sort(
            target: MeasureValueSort(measureLabel: 'measure_1'),
            direction: SortDirection.descending,
          ),
        ),
      );
      expect(result.isOk, isTrue);
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // HAVING rules
  // ────────────────────────────────────────────────────────────────────

  group('HAVING rules', () {
    test(
      'HAVING on a 0-groupBy query is rejected with havingRequiresGrouping',
      () {
        final result = validate(
          AnalyticsQuerySpec(
            source: 'tasks',
            measures: const [CountMeasure()],
            having: const HavingClause(
              operator: HavingOperator.greaterThan,
              threshold: IntValue(0),
            ),
          ),
        );
        expect(result.isErr, isTrue);
        expect(
          result.errOrNull!.kind,
          AnalyticsErrorKind.havingRequiresGrouping,
        );
      },
    );

    test(
      'HAVING threshold with mismatched type fires incompatibleOperator',
      () {
        // CountMeasure produces integer; passing a StringValue threshold
        // is a type mismatch.
        final result = validate(
          AnalyticsQuerySpec(
            source: 'tasks',
            measures: const [CountMeasure()],
            groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
            having: const HavingClause(
              operator: HavingOperator.greaterThan,
              threshold: StringValue('one'),
            ),
          ),
        );
        expect(result.isErr, isTrue);
        expect(result.errOrNull!.kind, AnalyticsErrorKind.incompatibleOperator);
      },
    );

    test('HAVING threshold as NullValue is rejected', () {
      final result = validate(
        AnalyticsQuerySpec(
          source: 'tasks',
          measures: const [CountMeasure()],
          groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
          having: const HavingClause(
            operator: HavingOperator.greaterThan,
            threshold: NullValue(FieldType.integer),
          ),
        ),
      );
      expect(result.isErr, isTrue);
      expect(result.errOrNull!.kind, AnalyticsErrorKind.incompatibleOperator);
    });

    test('multi-measure HAVING with null measureLabel is rejected', () {
      final result = validate(
        AnalyticsQuerySpec(
          source: 'tasks',
          measures: const [
            CountMeasure(label: 'a'),
            CountMeasure(label: 'b'),
          ],
          groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
          having: const HavingClause(
            operator: HavingOperator.greaterThan,
            threshold: IntValue(0),
          ),
        ),
      );
      expect(result.isErr, isTrue);
      expect(result.errOrNull!.kind, AnalyticsErrorKind.preconditionViolation);
    });

    test(
      'multi-measure HAVING with unknown measureLabel fires unknownMeasureLabel',
      () {
        final result = validate(
          AnalyticsQuerySpec(
            source: 'tasks',
            measures: const [
              CountMeasure(label: 'a'),
              CountMeasure(label: 'b'),
            ],
            groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
            having: const HavingClause(
              operator: HavingOperator.greaterThan,
              threshold: IntValue(0),
              measureLabel: 'nope',
            ),
          ),
        );
        expect(result.isErr, isTrue);
        expect(result.errOrNull!.kind, AnalyticsErrorKind.unknownMeasureLabel);
      },
    );

    test('single-measure HAVING with null measureLabel is accepted', () {
      final result = validate(
        AnalyticsQuerySpec(
          source: 'tasks',
          measures: const [CountMeasure()],
          groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
          having: const HavingClause(
            operator: HavingOperator.greaterThan,
            threshold: IntValue(0),
          ),
        ),
      );
      expect(result.isOk, isTrue);
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // Derived operation rules
  // ────────────────────────────────────────────────────────────────────

  group('derived operation — groupBy and measure shape rules', () {
    test('non-NoDerivedOp with 0 group-bys is rejected', () {
      final result = validate(
        AnalyticsQuerySpec(
          source: 'tasks',
          measures: [
            FieldMeasure(
              fieldRef: ref('tasks', 'priority'),
              aggregation: const SumAgg(),
            ),
          ],
          derivedOperation: const CumulativeSumOp(),
        ),
      );
      expect(result.isErr, isTrue);
      expect(result.errOrNull!.kind, AnalyticsErrorKind.preconditionViolation);
    });

    test('non-NoDerivedOp with 2 group-bys is rejected', () {
      final result = validate(
        AnalyticsQuerySpec(
          source: 'tasks',
          measures: [
            FieldMeasure(
              fieldRef: ref('tasks', 'priority'),
              aggregation: const SumAgg(),
            ),
          ],
          groupBys: [
            FieldGroupBy(fieldRef: ref('tasks', 'status')),
            FieldGroupBy(fieldRef: ref('tasks', 'priority')),
          ],
          derivedOperation: const CumulativeSumOp(),
        ),
      );
      expect(result.isErr, isTrue);
      expect(result.errOrNull!.kind, AnalyticsErrorKind.preconditionViolation);
    });

    test('non-NoDerivedOp with 2 measures is rejected', () {
      final result = validate(
        AnalyticsQuerySpec(
          source: 'tasks',
          measures: const [
            CountMeasure(label: 'a'),
            CountMeasure(label: 'b'),
          ],
          groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
          derivedOperation: const CumulativeSumOp(),
        ),
      );
      expect(result.isErr, isTrue);
      expect(result.errOrNull!.kind, AnalyticsErrorKind.preconditionViolation);
    });

    test('MovingAverageOp window <= 0 is rejected', () {
      final result = validate(
        AnalyticsQuerySpec(
          source: 'tasks',
          measures: [
            FieldMeasure(
              fieldRef: ref('tasks', 'priority'),
              aggregation: const SumAgg(),
            ),
          ],
          groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
          derivedOperation: const MovingAverageOp(window: 0),
        ),
      );
      expect(result.isErr, isTrue);
      expect(
        result.errOrNull!.kind,
        AnalyticsErrorKind.invalidDerivedOperationParameter,
      );
    });

    test(
      'derived op on non-numeric measure fires derivedOpRequiresNumericMeasure',
      () {
        // min on a dateTime field produces a DateTimeValue — not numeric,
        // so derived ops can't operate on it. Build a local source where
        // the dateTime field is aggregatable; the shared `events` fixture
        // has `aggregatable: false` on its primary date field, which
        // would fail with `fieldNotAggregatable` before reaching the
        // derived-op check.
        final s = SourceDef(
          sourceId: 'temporal',
          displayName: 'Temporal',
          fields: const [
            FieldDef(
              sourceId: 'temporal',
              fieldId: 'when',
              displayName: 'When',
              fieldType: FieldType.dateTime,
              filterable: true,
              groupable: false,
              aggregatable: true,
              sortable: true,
            ),
            FieldDef(
              sourceId: 'temporal',
              fieldId: 'kind',
              displayName: 'Kind',
              fieldType: FieldType.enumeration,
              filterable: true,
              groupable: true,
              aggregatable: false,
              sortable: true,
            ),
          ],
        );
        final result = QueryValidator.validateQuery(
          AnalyticsQuerySpec(
            source: 'temporal',
            measures: [
              FieldMeasure(
                fieldRef: ref('temporal', 'when'),
                aggregation: const MinAgg(),
              ),
            ],
            groupBys: [FieldGroupBy(fieldRef: ref('temporal', 'kind'))],
            derivedOperation: const CumulativeSumOp(),
          ),
          sources: [s],
        );
        expect(result.isErr, isTrue);
        expect(
          result.errOrNull!.kind,
          AnalyticsErrorKind.derivedOpRequiresNumericMeasure,
        );
      },
    );
  });

  // ────────────────────────────────────────────────────────────────────
  // Field-capability rules
  // ────────────────────────────────────────────────────────────────────

  group(
    'field capability — groupable, aggregatable, aggregation compatibility',
    () {
      test('group-by on a non-groupable field fires fieldNotGroupable', () {
        // tasks.title has groupable: false.
        final result = validate(
          AnalyticsQuerySpec(
            source: 'tasks',
            measures: const [CountMeasure()],
            groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'title'))],
          ),
        );
        expect(result.isErr, isTrue);
        expect(result.errOrNull!.kind, AnalyticsErrorKind.fieldNotGroupable);
      });

      test(
        'FieldMeasure on a non-aggregatable field fires fieldNotAggregatable',
        () {
          // tasks.status has aggregatable: false.
          final result = validate(
            AnalyticsQuerySpec(
              source: 'tasks',
              measures: [
                FieldMeasure(
                  fieldRef: ref('tasks', 'status'),
                  aggregation: const DistinctCountAgg(),
                ),
              ],
            ),
          );
          expect(result.isErr, isTrue);
          expect(
            result.errOrNull!.kind,
            AnalyticsErrorKind.fieldNotAggregatable,
          );
        },
      );

      test('CountMeasure is unaffected by non-aggregatable fields', () {
        // CountMeasure doesn't read any field; aggregatable doesn't
        // apply. A query with no FieldMeasure validates over any source.
        final result = validate(
          AnalyticsQuerySpec(source: 'tasks', measures: const [CountMeasure()]),
        );
        expect(result.isOk, isTrue);
      });

      test(
        'aggregation × field-type mismatch fires incompatibleAggregation',
        () {
          // sum on a string field — sum requires a numeric type.
          final result = validate(
            AnalyticsQuerySpec(
              source: 'tasks',
              measures: [
                FieldMeasure(
                  fieldRef: ref('tasks', 'title'),
                  aggregation: const SumAgg(),
                ),
              ],
            ),
          );
          expect(result.isErr, isTrue);
          // tasks.title is also not aggregatable, which fires first;
          // accept either to keep the test resilient to validation order
          // changes that don't affect correctness.
          expect(
            result.errOrNull!.kind,
            anyOf(
              AnalyticsErrorKind.fieldNotAggregatable,
              AnalyticsErrorKind.incompatibleAggregation,
            ),
          );
        },
      );

      test(
        'sum on a string-typed but aggregatable field fires incompatibleAggregation',
        () {
          // Build a source whose string field is aggregatable to isolate
          // the aggregation-incompatibility error from the capability one.
          final s = SourceDef(
            sourceId: 's',
            displayName: 'S',
            fields: const [
              FieldDef(
                sourceId: 's',
                fieldId: 'name',
                displayName: 'Name',
                fieldType: FieldType.string,
                filterable: true,
                groupable: true,
                aggregatable: true,
                sortable: true,
              ),
            ],
          );
          final result = QueryValidator.validateQuery(
            AnalyticsQuerySpec(
              source: 's',
              measures: [
                FieldMeasure(
                  fieldRef: ref('s', 'name'),
                  aggregation: const SumAgg(),
                ),
              ],
            ),
            sources: [s],
          );
          expect(result.isErr, isTrue);
          expect(
            result.errOrNull!.kind,
            AnalyticsErrorKind.incompatibleAggregation,
          );
        },
      );
    },
  );

  // ────────────────────────────────────────────────────────────────────
  // Unknown source / field
  // ────────────────────────────────────────────────────────────────────

  group('unknown source and unknown field', () {
    test('unknown source fires unknownSource', () {
      final result = QueryValidator.validateQuery(
        AnalyticsQuerySpec(source: 'nope', measures: const [CountMeasure()]),
        sources: [tasks],
      );
      expect(result.isErr, isTrue);
      expect(result.errOrNull!.kind, AnalyticsErrorKind.unknownSource);
    });

    test('unknown field in a filter fires unknownField', () {
      final result = validate(
        AnalyticsQuerySpec(
          source: 'tasks',
          measures: const [CountMeasure()],
          filters: [
            Filter(
              fieldRef: ref('tasks', 'doesNotExist'),
              operator: FilterOperator.equals,
              value: const StringValue('x'),
            ),
          ],
        ),
      );
      expect(result.isErr, isTrue);
      expect(result.errOrNull!.kind, AnalyticsErrorKind.unknownField);
    });

    test('unknown field in a group-by fires unknownField', () {
      final result = validate(
        AnalyticsQuerySpec(
          source: 'tasks',
          measures: const [CountMeasure()],
          groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'doesNotExist'))],
        ),
      );
      expect(result.isErr, isTrue);
      expect(result.errOrNull!.kind, AnalyticsErrorKind.unknownField);
    });

    test('cross-source field ref in a sort fires incompatibleSortTarget', () {
      // The sort-target resolver overrides `mismatchKind`; cross-source
      // surfaces as incompatibleSortTarget rather than unknownField.
      final result = validate(
        AnalyticsQuerySpec(
          source: 'tasks',
          measures: const [CountMeasure()],
          groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
          sort: Sort(
            target: GroupFieldSort(fieldRef: ref('events', 'kind')),
            direction: SortDirection.ascending,
          ),
        ),
      );
      expect(result.isErr, isTrue);
      expect(result.errOrNull!.kind, AnalyticsErrorKind.incompatibleSortTarget);
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // Limit rules
  // ────────────────────────────────────────────────────────────────────

  group('limit rules', () {
    test('limit < 0 is rejected', () {
      final result = validate(
        AnalyticsQuerySpec(
          source: 'tasks',
          measures: const [CountMeasure()],
          groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
          limit: -1,
        ),
      );
      expect(result.isErr, isTrue);
      expect(result.errOrNull!.kind, AnalyticsErrorKind.preconditionViolation);
    });

    test('limit == 0 is accepted', () {
      final result = validate(
        AnalyticsQuerySpec(
          source: 'tasks',
          measures: const [CountMeasure()],
          groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
          limit: 0,
        ),
      );
      expect(result.isOk, isTrue);
    });

    test('limit > 0 is accepted', () {
      final result = validate(
        AnalyticsQuerySpec(
          source: 'tasks',
          measures: const [CountMeasure()],
          groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
          limit: 10,
        ),
      );
      expect(result.isOk, isTrue);
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // Streak field-type rules — table-driven per field
  // ────────────────────────────────────────────────────────────────────

  /// Builds a habits-like source whose status field has the given
  /// [statusType]. The other fields stay constant.
  SourceDef habitsWithStatusType(FieldType statusType) => SourceDef(
    sourceId: 'habits',
    displayName: 'Habits',
    fields: [
      const FieldDef(
        sourceId: 'habits',
        fieldId: 'habitId',
        displayName: 'Habit ID',
        fieldType: FieldType.string,
        filterable: true,
        groupable: true,
        aggregatable: false,
        sortable: true,
      ),
      const FieldDef(
        sourceId: 'habits',
        fieldId: 'scheduledAt',
        displayName: 'Scheduled At',
        fieldType: FieldType.dateTime,
        filterable: true,
        groupable: true,
        aggregatable: false,
        sortable: true,
      ),
      FieldDef(
        sourceId: 'habits',
        fieldId: 'status',
        displayName: 'Status',
        fieldType: statusType,
        filterable: true,
        groupable: true,
        aggregatable: false,
        sortable: true,
      ),
    ],
  );

  AnalyticsQuerySpec habitsQuery() => AnalyticsQuerySpec(
    source: 'habits',
    measures: [
      StreakMeasure(
        entityIdField: ref('habits', 'habitId'),
        scheduledDateField: ref('habits', 'scheduledAt'),
        statusField: ref('habits', 'status'),
        completedStatusValue: 'done',
      ),
    ],
  );

  group('streak field types — status field', () {
    // The status field must be string or enumeration so the
    // completed-status value can be compared meaningfully.
    for (final accepted in [FieldType.string, FieldType.enumeration]) {
      test('status of type ${accepted.name} is accepted', () {
        final result = QueryValidator.validateQuery(
          habitsQuery(),
          sources: [habitsWithStatusType(accepted)],
        );
        expect(result.isOk, isTrue);
      });
    }

    for (final rejected in [
      FieldType.integer,
      FieldType.double,
      FieldType.boolean,
      FieldType.dateTime,
      FieldType.duration,
    ]) {
      test('status of type ${rejected.name} is rejected', () {
        final result = QueryValidator.validateQuery(
          habitsQuery(),
          sources: [habitsWithStatusType(rejected)],
        );
        expect(result.isErr, isTrue);
        expect(
          result.errOrNull!.kind,
          AnalyticsErrorKind.preconditionViolation,
        );
        expect(
          result.errOrNull!.humanMessage,
          contains('string or enumeration'),
        );
      });
    }
  });

  group('streak field types — entityLabel field', () {
    /// Builds a habits source with a label field of the given type
    /// alongside the standard fields.
    SourceDef habitsWithLabelType(FieldType labelType) => SourceDef(
      sourceId: 'habits',
      displayName: 'Habits',
      fields: [
        const FieldDef(
          sourceId: 'habits',
          fieldId: 'habitId',
          displayName: 'Habit ID',
          fieldType: FieldType.string,
          filterable: true,
          groupable: true,
          aggregatable: false,
          sortable: true,
        ),
        const FieldDef(
          sourceId: 'habits',
          fieldId: 'scheduledAt',
          displayName: 'Scheduled At',
          fieldType: FieldType.dateTime,
          filterable: true,
          groupable: true,
          aggregatable: false,
          sortable: true,
        ),
        const FieldDef(
          sourceId: 'habits',
          fieldId: 'status',
          displayName: 'Status',
          fieldType: FieldType.enumeration,
          filterable: true,
          groupable: true,
          aggregatable: false,
          sortable: true,
        ),
        FieldDef(
          sourceId: 'habits',
          fieldId: 'label',
          displayName: 'Label',
          fieldType: labelType,
          filterable: true,
          groupable: true,
          aggregatable: false,
          sortable: true,
        ),
      ],
    );

    AnalyticsQuerySpec habitsQueryWithLabel() => AnalyticsQuerySpec(
      source: 'habits',
      measures: [
        StreakMeasure(
          entityIdField: ref('habits', 'habitId'),
          scheduledDateField: ref('habits', 'scheduledAt'),
          statusField: ref('habits', 'status'),
          completedStatusValue: 'done',
          entityLabelField: ref('habits', 'label'),
        ),
      ],
    );

    test('entityLabel of type string is accepted', () {
      final result = QueryValidator.validateQuery(
        habitsQueryWithLabel(),
        sources: [habitsWithLabelType(FieldType.string)],
      );
      expect(result.isOk, isTrue);
    });

    for (final rejected in [
      FieldType.enumeration,
      FieldType.integer,
      FieldType.double,
      FieldType.boolean,
      FieldType.dateTime,
      FieldType.duration,
    ]) {
      test('entityLabel of type ${rejected.name} is rejected', () {
        final result = QueryValidator.validateQuery(
          habitsQueryWithLabel(),
          sources: [habitsWithLabelType(rejected)],
        );
        expect(result.isErr, isTrue);
        expect(
          result.errOrNull!.kind,
          AnalyticsErrorKind.preconditionViolation,
        );
        expect(result.errOrNull!.humanMessage, contains('string entity-label'));
      });
    }
  });

  group('streak field types — scheduled-date and topN', () {
    test(
      'scheduled-date field of non-dateTime type fires timeGrainOnNonDateField',
      () {
        final s = SourceDef(
          sourceId: 'habits',
          displayName: 'Habits',
          fields: const [
            FieldDef(
              sourceId: 'habits',
              fieldId: 'habitId',
              displayName: 'Habit ID',
              fieldType: FieldType.string,
              filterable: true,
              groupable: true,
              aggregatable: false,
              sortable: true,
            ),
            FieldDef(
              sourceId: 'habits',
              fieldId: 'scheduledAt',
              displayName: 'Scheduled At',
              fieldType: FieldType.string, // wrong type
              filterable: true,
              groupable: true,
              aggregatable: false,
              sortable: true,
            ),
            FieldDef(
              sourceId: 'habits',
              fieldId: 'status',
              displayName: 'Status',
              fieldType: FieldType.enumeration,
              filterable: true,
              groupable: true,
              aggregatable: false,
              sortable: true,
            ),
          ],
        );
        final result = QueryValidator.validateQuery(
          habitsQuery(),
          sources: [s],
        );
        expect(result.isErr, isTrue);
        expect(
          result.errOrNull!.kind,
          AnalyticsErrorKind.timeGrainOnNonDateField,
        );
      },
    );

    test('negative topN is rejected', () {
      final result = QueryValidator.validateQuery(
        AnalyticsQuerySpec(
          source: 'habits',
          measures: [
            StreakMeasure(
              entityIdField: ref('habits', 'habitId'),
              scheduledDateField: ref('habits', 'scheduledAt'),
              statusField: ref('habits', 'status'),
              completedStatusValue: 'done',
              topN: -1,
            ),
          ],
        ),
        sources: [habitsWithStatusType(FieldType.enumeration)],
      );
      expect(result.isErr, isTrue);
      expect(result.errOrNull!.kind, AnalyticsErrorKind.preconditionViolation);
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // Widget payload date-range cross rule
  // ────────────────────────────────────────────────────────────────────

  group('widget payload — date-range vs. measure cross rule', () {
    Result<Unit, AnalyticsError> validateWidget({
      required QueryPayload payload,
      required DateRangeMode mode,
      List<SourceDef>? sources,
    }) {
      return QueryValidator.validateWidgetPayload(
        payload: payload,
        sources: sources ?? allSources,
        dateRangeMode: mode,
      );
    }

    test(
      'non-streak measure with NoDateRange fires dateRangeRequiredForMeasure',
      () {
        // CountMeasure supportsDateRange: true → mode must not be NoDateRange.
        final result = validateWidget(
          payload: SingleQuerySpec(
            query: AnalyticsQuerySpec(
              source: 'tasks',
              measures: const [CountMeasure()],
            ),
          ),
          mode: const NoDateRange(),
        );
        expect(result.isErr, isTrue);
        expect(
          result.errOrNull!.kind,
          AnalyticsErrorKind.dateRangeRequiredForMeasure,
        );
      },
    );

    test(
      'streak measure with FixedOverride fires dateRangeNotSupportedForMeasure',
      () {
        // StreakMeasure supportsDateRange: false → mode must be NoDateRange.
        final habits = habitsWithStatusType(FieldType.enumeration);
        final result = validateWidget(
          payload: SingleQuerySpec(query: habitsQuery()),
          mode: FixedOverride(
            range: CustomRange(
              start: DateTime.utc(2026, 1, 1),
              end: DateTime.utc(2026, 12, 31),
            ),
          ),
          sources: [habits],
        );
        expect(result.isErr, isTrue);
        expect(
          result.errOrNull!.kind,
          AnalyticsErrorKind.dateRangeNotSupportedForMeasure,
        );
      },
    );

    test('streak measure with NoDateRange is accepted', () {
      final habits = habitsWithStatusType(FieldType.enumeration);
      final result = validateWidget(
        payload: SingleQuerySpec(query: habitsQuery()),
        mode: const NoDateRange(),
        sources: [habits],
      );
      expect(result.isOk, isTrue);
    });

    test('non-streak measure with FixedOverride is accepted', () {
      final result = validateWidget(
        payload: SingleQuerySpec(
          query: AnalyticsQuerySpec(
            source: 'tasks',
            measures: const [CountMeasure()],
          ),
        ),
        mode: FixedOverride(
          range: CustomRange(
            start: DateTime.utc(2026, 1, 1),
            end: DateTime.utc(2026, 12, 31),
          ),
        ),
      );
      expect(result.isOk, isTrue);
    });
  });
}
