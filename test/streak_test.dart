import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:test/test.dart';

/// Streak measure execution.
///
/// The result is a `TableResult` with one row per entity and exactly
/// four columns: `entityId` (group-key, string), `entityLabel`
/// (measure, string), `currentStreak` (measure, integer), and
/// `longestStreak` (measure, integer). Rows are sorted by current
/// streak desc, then longest streak desc, then entity label asc.
/// `topN` truncates the result; the dropped count is reported as
/// `truncatedCount`. `asOf` is required.
void main() {
  /// Builds a habits source. The status field is an enumeration and
  /// the entityLabelField is a separate string field.
  SourceDef habitsSource() => SourceDef(
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
        fieldType: FieldType.string,
        filterable: true,
        groupable: true,
        aggregatable: false,
        sortable: true,
      ),
    ],
  );

  FieldRef refOf(String id) => FieldRef(sourceId: 'habits', fieldId: id);

  /// Builds a streak measure with the standard field set; optional
  /// [entityLabelField] and [topN].
  StreakMeasure streak({FieldRef? entityLabelField, int? topN}) =>
      StreakMeasure(
        entityIdField: refOf('habitId'),
        scheduledDateField: refOf('scheduledAt'),
        statusField: refOf('status'),
        completedStatusValue: 'done',
        entityLabelField: entityLabelField,
        topN: topN,
      );

  /// Builds a single record for habit [id] on [day] with [status].
  SourceRecord record({
    required String id,
    required int day,
    required String status,
    String? label,
  }) => SourceRecord(
    fields: {
      'habitId': StringValue(id),
      'scheduledAt': DateTimeValue(DateTime(2026, 5, day)),
      'status': EnumValue(status),
      if (label != null) 'label': StringValue(label),
    },
  );

  Result<AnalyticsResult, AnalyticsError> run(
    StreakMeasure measure,
    List<SourceRecord> records, {
    DateTime? asOf,
  }) => AnalyticsExecutor.execute(
    query: AnalyticsQuerySpec(source: 'habits', measures: [measure]),
    records: records,
    sources: [habitsSource()],
    asOf: asOf,
  );

  // ────────────────────────────────────────────────────────────────────
  // 4-column shape
  // ────────────────────────────────────────────────────────────────────

  group('streak result shape — 4 columns, 1 row per entity', () {
    test('TableResult has exactly four columns in the documented order', () {
      final result = run(streak(), [
        record(id: 'h1', day: 1, status: 'done'),
      ], asOf: DateTime(2026, 5, 1));
      final table = result.okOrNull as TableResult;
      expect(table.columns, hasLength(4));
      expect(table.columns[0].label, 'entityId');
      expect(table.columns[1].label, 'entityLabel');
      expect(table.columns[2].label, 'currentStreak');
      expect(table.columns[3].label, 'longestStreak');
    });

    test('column kinds: entityId is groupKey, the other three are measure', () {
      final table =
          run(streak(), [
                record(id: 'h1', day: 1, status: 'done'),
              ], asOf: DateTime(2026, 5, 1)).okOrNull
              as TableResult;
      expect(table.columns[0].kind, TableColumnKind.groupKey);
      for (final c in table.columns.sublist(1)) {
        expect(c.kind, TableColumnKind.measure);
      }
    });

    test('column field types: string, string, integer, integer', () {
      final table =
          run(streak(), [
                record(id: 'h1', day: 1, status: 'done'),
              ], asOf: DateTime(2026, 5, 1)).okOrNull
              as TableResult;
      expect(table.columns[0].fieldType, FieldType.string);
      expect(table.columns[1].fieldType, FieldType.string);
      expect(table.columns[2].fieldType, FieldType.integer);
      expect(table.columns[3].fieldType, FieldType.integer);
    });

    test('row key is length 1 wrapping a StringBucketKey of the entity id', () {
      final table =
          run(streak(), [
                record(id: 'h1', day: 1, status: 'done'),
              ], asOf: DateTime(2026, 5, 1)).okOrNull
              as TableResult;
      expect(table.rowKeys, hasLength(1));
      expect(table.rowKeys.single.keys, [const StringBucketKey('h1')]);
    });

    test('one row per distinct entity id', () {
      final table =
          run(streak(), [
                record(id: 'h1', day: 1, status: 'done'),
                record(id: 'h2', day: 1, status: 'done'),
                record(id: 'h1', day: 2, status: 'done'),
              ], asOf: DateTime(2026, 5, 2)).okOrNull
              as TableResult;
      expect(table.rowCount, 2);
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // Current / longest streak math
  // ────────────────────────────────────────────────────────────────────

  group('current and longest streak math', () {
    test('docstring example — days 1-5 done, 6-7 missed, 8-10 done', () {
      // asOf=day 10 → current=3 (days 8-10), longest=5 (days 1-5).
      final records = <SourceRecord>[
        for (final d in [1, 2, 3, 4, 5])
          record(id: 'h1', day: d, status: 'done'),
        record(id: 'h1', day: 6, status: 'missed'),
        record(id: 'h1', day: 7, status: 'missed'),
        for (final d in [8, 9, 10]) record(id: 'h1', day: d, status: 'done'),
      ];
      final table =
          run(streak(), records, asOf: DateTime(2026, 5, 10)).okOrNull
              as TableResult;
      expect(table.columns[2].values.single, const IntValue(3));
      expect(table.columns[3].values.single, const IntValue(5));
    });

    test('today scheduled but not yet completed: current streak preserved', () {
      // Days 1, 2: done. Day 3 (today/asOf): scheduled but not done.
      // The streak should remain 2, not break to 0.
      final records = [
        record(id: 'h1', day: 1, status: 'done'),
        record(id: 'h1', day: 2, status: 'done'),
        record(id: 'h1', day: 3, status: 'missed'),
      ];
      final table =
          run(streak(), records, asOf: DateTime(2026, 5, 3)).okOrNull
              as TableResult;
      expect(table.columns[2].values.single, const IntValue(2));
    });

    test('past scheduled day without completion breaks the streak', () {
      // Day 1: done. Day 2: missed (in the past, before asOf=day 3).
      // The streak breaks.
      final records = [
        record(id: 'h1', day: 1, status: 'done'),
        record(id: 'h1', day: 2, status: 'missed'),
      ];
      final table =
          run(streak(), records, asOf: DateTime(2026, 5, 3)).okOrNull
              as TableResult;
      expect(table.columns[2].values.single, const IntValue(0));
      expect(table.columns[3].values.single, const IntValue(1));
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // Label resolution
  // ────────────────────────────────────────────────────────────────────

  group('entityLabel resolution', () {
    test('entityLabelField set → first non-empty label per entity', () {
      final records = [
        record(id: 'h1', day: 1, status: 'done', label: 'Morning run'),
      ];
      final table =
          run(
                streak(entityLabelField: refOf('label')),
                records,
                asOf: DateTime(2026, 5, 1),
              ).okOrNull
              as TableResult;
      expect(
        table.columnByLabel('entityLabel')!.values.single,
        const StringValue('Morning run'),
      );
    });

    test('entityLabelField null → falls back to entity id', () {
      final records = [record(id: 'h1', day: 1, status: 'done')];
      final table =
          run(streak(), records, asOf: DateTime(2026, 5, 1)).okOrNull
              as TableResult;
      expect(
        table.columnByLabel('entityLabel')!.values.single,
        const StringValue('h1'),
      );
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // topN truncation
  // ────────────────────────────────────────────────────────────────────

  group('topN truncation', () {
    test('keeps topN rows by current streak descending', () {
      // Three entities: h1 has current 3, h2 has current 1, h3 has
      // current 2. topN=2 keeps h1 then h3.
      final records = <SourceRecord>[
        for (final d in [1, 2, 3]) record(id: 'h1', day: d, status: 'done'),
        record(id: 'h2', day: 1, status: 'done'),
        for (final d in [1, 2]) record(id: 'h3', day: d, status: 'done'),
      ];
      final table =
          run(streak(topN: 2), records, asOf: DateTime(2026, 5, 3)).okOrNull
              as TableResult;
      expect(table.rowCount, 2);
      // First row: h1 with current=3. Second: h3 with current=2.
      expect(
        table.columnByLabel('entityId')!.values[0],
        const StringValue('h1'),
      );
      expect(
        table.columnByLabel('entityId')!.values[1],
        const StringValue('h3'),
      );
      expect(table.truncatedCount, 1);
    });

    test('no topN → truncatedCount is 0', () {
      final records = [
        record(id: 'h1', day: 1, status: 'done'),
        record(id: 'h2', day: 1, status: 'done'),
      ];
      final table =
          run(streak(), records, asOf: DateTime(2026, 5, 1)).okOrNull
              as TableResult;
      expect(table.truncatedCount, 0);
    });

    test('topN >= total rows → no truncation', () {
      final records = [
        record(id: 'h1', day: 1, status: 'done'),
        record(id: 'h2', day: 1, status: 'done'),
      ];
      final table =
          run(streak(topN: 10), records, asOf: DateTime(2026, 5, 1)).okOrNull
              as TableResult;
      expect(table.rowCount, 2);
      expect(table.truncatedCount, 0);
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // asOf is required
  // ────────────────────────────────────────────────────────────────────

  group('asOf is required', () {
    test('streak query without asOf returns preconditionViolation', () {
      final result = run(
        streak(),
        [record(id: 'h1', day: 1, status: 'done')],
        // asOf intentionally omitted
      );
      expect(result.isErr, isTrue);
      expect(result.errOrNull!.kind, AnalyticsErrorKind.preconditionViolation);
    });
  });
}
