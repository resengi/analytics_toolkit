import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:test/test.dart';

import '_fixtures.dart';

/// Filter execution semantics, exercised through the executor.
///
/// The filter engine itself is internal (not exported), so these
/// tests run filters as part of a query and assert the resulting
/// row counts and surviving values. The validator (`filter_validation_test`)
/// covers which filters are legal; this file covers what they
/// actually do at run time.
///
/// Each `FilterOperator` is exercised on one representative field
/// type. The operator × type matrix is already pinned by the
/// validator; here we care about runtime semantics — does `equals`
/// actually compare correctly, does `notEquals` invert correctly,
/// does `inList` walk the list correctly, does `NullValue` equality
/// behave as a null-check.
void main() {
  final tasks = tasksSource();

  /// A small fixture of three task records spanning priority 1, 2, 3
  /// and three distinct statuses. Reused across the operator tests.
  List<SourceRecord> threeTasks() => [
    SourceRecord(
      fields: {
        'status': const EnumValue('todo'),
        'priority': const IntValue(1),
      },
    ),
    SourceRecord(
      fields: {
        'status': const EnumValue('inProgress'),
        'priority': const IntValue(2),
      },
    ),
    SourceRecord(
      fields: {
        'status': const EnumValue('done'),
        'priority': const IntValue(3),
      },
    ),
  ];

  /// Runs a `count` query with the given filter and returns the
  /// resulting count as a plain int — every test below is shaped
  /// "filter, count survivors."
  int countAfterFilter(Filter filter, [List<SourceRecord>? records]) {
    final result = AnalyticsExecutor.execute(
      query: AnalyticsQuerySpec(
        source: 'tasks',
        measures: const [CountMeasure()],
        filters: [filter],
      ),
      records: records ?? threeTasks(),
      sources: [tasks],
    );
    return ((result.okOrNull as ScalarResult).value as IntValue).value;
  }

  // ────────────────────────────────────────────────────────────────────
  // Comparison operators on a numeric field
  // ────────────────────────────────────────────────────────────────────

  group('comparison operators on a numeric field', () {
    Filter cmp(FilterOperator op, int value) => Filter(
      fieldRef: ref('tasks', 'priority'),
      operator: op,
      value: IntValue(value),
    );

    test('equals, notEquals select the documented set', () {
      // priority values are 1, 2, 3.
      expect(countAfterFilter(cmp(FilterOperator.equals, 2)), 1);
      expect(countAfterFilter(cmp(FilterOperator.notEquals, 2)), 2);
    });

    test(
      'lessThan, lessThanOrEqual, greaterThan, greaterThanOrEqual select correctly',
      () {
        expect(countAfterFilter(cmp(FilterOperator.lessThan, 2)), 1);
        expect(countAfterFilter(cmp(FilterOperator.lessThanOrEqual, 2)), 2);
        expect(countAfterFilter(cmp(FilterOperator.greaterThan, 2)), 1);
        expect(countAfterFilter(cmp(FilterOperator.greaterThanOrEqual, 2)), 2);
      },
    );

    test('out-of-range values produce empty results, not errors', () {
      // Below the minimum and above the maximum return zero counts —
      // the filter just rejects every record.
      expect(countAfterFilter(cmp(FilterOperator.greaterThan, 999)), 0);
      expect(countAfterFilter(cmp(FilterOperator.lessThan, -1)), 0);
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // Equality on an enumeration field
  // ────────────────────────────────────────────────────────────────────

  group('equality on an enumeration field', () {
    test('equals selects matching records; notEquals selects the rest', () {
      final eq = Filter(
        fieldRef: ref('tasks', 'status'),
        operator: FilterOperator.equals,
        value: const EnumValue('done'),
      );
      final ne = Filter(
        fieldRef: ref('tasks', 'status'),
        operator: FilterOperator.notEquals,
        value: const EnumValue('done'),
      );
      expect(countAfterFilter(eq), 1);
      expect(countAfterFilter(ne), 2);
    });

    test('no records match an enum value that doesn\'t appear', () {
      final eq = Filter(
        fieldRef: ref('tasks', 'status'),
        operator: FilterOperator.equals,
        value: const EnumValue('archived'),
      );
      expect(countAfterFilter(eq), 0);
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // inList — membership
  // ────────────────────────────────────────────────────────────────────

  group('inList membership', () {
    test(
      'inList on an enum field selects records whose value is in the list',
      () {
        final f = Filter(
          fieldRef: ref('tasks', 'status'),
          operator: FilterOperator.inList,
          value: EnumListValue(const ['todo', 'done']),
        );
        expect(countAfterFilter(f), 2);
      },
    );

    test(
      'inList on an integer field selects records whose value is in the list',
      () {
        final f = Filter(
          fieldRef: ref('tasks', 'priority'),
          operator: FilterOperator.inList,
          value: IntListValue(const [1, 3]),
        );
        expect(countAfterFilter(f), 2);
      },
    );

    test('inList with an empty list matches no records', () {
      final f = Filter(
        fieldRef: ref('tasks', 'priority'),
        operator: FilterOperator.inList,
        value: IntListValue(const []),
      );
      expect(countAfterFilter(f), 0);
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // NullValue equality — null-check semantics
  // ────────────────────────────────────────────────────────────────────

  group('NullValue equality is a null-check, not an equals-comparison', () {
    /// Records with `priority` present, NullValue, and missing.
    /// `equals NullValue` should match the latter two; `notEquals
    /// NullValue` should match only the present one.
    List<SourceRecord> threeNullable() => [
      SourceRecord(
        fields: {
          'status': const EnumValue('todo'),
          'priority': const IntValue(5),
        },
      ),
      SourceRecord(
        fields: {
          'status': const EnumValue('todo'),
          'priority': const NullValue(FieldType.integer),
        },
      ),
      SourceRecord(
        // priority field absent entirely.
        fields: {'status': const EnumValue('todo')},
      ),
    ];

    test('equals NullValue matches records whose field is null or missing', () {
      final f = Filter(
        fieldRef: ref('tasks', 'priority'),
        operator: FilterOperator.equals,
        value: const NullValue(FieldType.integer),
      );
      expect(countAfterFilter(f, threeNullable()), 2);
    });

    test(
      'notEquals NullValue matches only records with a present non-null value',
      () {
        final f = Filter(
          fieldRef: ref('tasks', 'priority'),
          operator: FilterOperator.notEquals,
          value: const NullValue(FieldType.integer),
        );
        expect(countAfterFilter(f, threeNullable()), 1);
      },
    );
  });

  // ────────────────────────────────────────────────────────────────────
  // Multiple filters combine via AND
  // ────────────────────────────────────────────────────────────────────

  group('multiple filters combine via AND', () {
    test('two filters keep only records satisfying both', () {
      final result = AnalyticsExecutor.execute(
        query: AnalyticsQuerySpec(
          source: 'tasks',
          measures: const [CountMeasure()],
          filters: [
            Filter(
              fieldRef: ref('tasks', 'status'),
              operator: FilterOperator.equals,
              value: const EnumValue('done'),
            ),
            Filter(
              fieldRef: ref('tasks', 'priority'),
              operator: FilterOperator.greaterThan,
              value: const IntValue(1),
            ),
          ],
        ),
        records: threeTasks(),
        sources: [tasks],
      );
      // Only the `done` + priority 3 record satisfies both.
      expect(((result.okOrNull as ScalarResult).value as IntValue).value, 1);
    });

    test('empty filter list keeps all records', () {
      final result = AnalyticsExecutor.execute(
        query: AnalyticsQuerySpec(
          source: 'tasks',
          measures: const [CountMeasure()],
        ),
        records: threeTasks(),
        sources: [tasks],
      );
      expect(((result.okOrNull as ScalarResult).value as IntValue).value, 3);
    });
  });
}
