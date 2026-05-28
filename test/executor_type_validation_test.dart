import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:test/test.dart';

/// Pins the executor's first-pass record validation that rejects any
/// record whose [TypedValue] subtype doesn't match the declared
/// [FieldType] on the source.
///
/// Two contracts:
///
/// 1. Records carrying wrong-typed values cause the executor to
///    return `Err(AnalyticsErrorKind.sourceRecordTypeMismatch)`.
/// 2. `NullValue` of any declared type and missing fields are valid
///    "no data" signals, not type violations. Fields not declared on
///    the source are ignored entirely.
void main() {
  final source = SourceDef(
    sourceId: 'mixed',
    displayName: 'Mixed',
    fields: const [
      FieldDef(
        sourceId: 'mixed',
        fieldId: 'i',
        displayName: 'Integer',
        fieldType: FieldType.integer,
        filterable: true,
        groupable: true,
        aggregatable: true,
        sortable: true,
      ),
      FieldDef(
        sourceId: 'mixed',
        fieldId: 'd',
        displayName: 'Double',
        fieldType: FieldType.double,
        filterable: true,
        groupable: true,
        aggregatable: true,
        sortable: true,
      ),
      FieldDef(
        sourceId: 'mixed',
        fieldId: 'dur',
        displayName: 'Duration',
        fieldType: FieldType.duration,
        filterable: true,
        groupable: true,
        aggregatable: true,
        sortable: true,
      ),
      FieldDef(
        sourceId: 'mixed',
        fieldId: 'dt',
        displayName: 'DateTime',
        fieldType: FieldType.dateTime,
        filterable: true,
        groupable: true,
        aggregatable: true,
        sortable: true,
      ),
      FieldDef(
        sourceId: 'mixed',
        fieldId: 's',
        displayName: 'String',
        fieldType: FieldType.string,
        filterable: true,
        groupable: true,
        aggregatable: true,
        sortable: true,
      ),
      FieldDef(
        sourceId: 'mixed',
        fieldId: 'e',
        displayName: 'Enum',
        fieldType: FieldType.enumeration,
        filterable: true,
        groupable: true,
        aggregatable: true,
        sortable: true,
      ),
      FieldDef(
        sourceId: 'mixed',
        fieldId: 'b',
        displayName: 'Boolean',
        fieldType: FieldType.boolean,
        filterable: true,
        groupable: true,
        aggregatable: true,
        sortable: true,
      ),
    ],
    primaryDateFieldId: 'dt',
  );

  FieldRef refOf(String id) => FieldRef(sourceId: 'mixed', fieldId: id);

  Result<AnalyticsResult, AnalyticsError> run(
    AnalyticsQuerySpec query,
    List<SourceRecord> records, {
    DateTime? asOf,
  }) => AnalyticsExecutor.execute(
    query: query,
    records: records,
    sources: [source],
    asOf: asOf,
  );

  void expectTypeMismatch(Result<AnalyticsResult, AnalyticsError> result) {
    expect(result.isErr, isTrue);
    expect(result.errOrNull!.kind, AnalyticsErrorKind.sourceRecordTypeMismatch);
  }

  // ────────────────────────────────────────────────────────────────────
  // Wrong-typed values reach the executor via each pipeline stage
  // ────────────────────────────────────────────────────────────────────

  group('wrong-typed records during aggregation', () {
    // The executor's first pass walks every record and checks each
    // declared field's TypedValue against the field's declared type.
    // A mismatch fails the whole execution before any aggregation
    // runs.

    test('integer field receiving DoubleValue is rejected', () {
      final result = run(
        AnalyticsQuerySpec(
          source: 'mixed',
          measures: [
            FieldMeasure(fieldRef: refOf('i'), aggregation: const SumAgg()),
          ],
        ),
        [
          SourceRecord(fields: {'i': const DoubleValue(1.0)}),
        ],
      );
      expectTypeMismatch(result);
    });

    test('double field receiving IntValue is rejected', () {
      final result = run(
        AnalyticsQuerySpec(
          source: 'mixed',
          measures: [
            FieldMeasure(fieldRef: refOf('d'), aggregation: const SumAgg()),
          ],
        ),
        [
          SourceRecord(fields: {'d': const IntValue(1)}),
        ],
      );
      expectTypeMismatch(result);
    });

    test('duration field receiving IntValue is rejected', () {
      final result = run(
        AnalyticsQuerySpec(
          source: 'mixed',
          measures: [
            FieldMeasure(fieldRef: refOf('dur'), aggregation: const SumAgg()),
          ],
        ),
        [
          SourceRecord(fields: {'dur': const IntValue(100)}),
        ],
      );
      expectTypeMismatch(result);
    });

    test('dateTime field receiving StringValue is rejected', () {
      final result = run(
        AnalyticsQuerySpec(
          source: 'mixed',
          measures: [
            FieldMeasure(fieldRef: refOf('dt'), aggregation: const MaxAgg()),
          ],
        ),
        [
          SourceRecord(fields: {'dt': const StringValue('2026-05-01')}),
        ],
      );
      expectTypeMismatch(result);
    });

    test('enumeration field receiving StringValue is rejected', () {
      final result = run(
        AnalyticsQuerySpec(
          source: 'mixed',
          measures: [
            FieldMeasure(
              fieldRef: refOf('e'),
              aggregation: const DistinctCountAgg(),
            ),
          ],
        ),
        [
          SourceRecord(fields: {'e': const StringValue('done')}),
        ],
      );
      expectTypeMismatch(result);
    });

    test('boolean field receiving IntValue is rejected', () {
      final result = run(
        AnalyticsQuerySpec(
          source: 'mixed',
          measures: [
            FieldMeasure(
              fieldRef: refOf('b'),
              aggregation: const DistinctCountAgg(),
            ),
          ],
        ),
        [
          SourceRecord(fields: {'b': const IntValue(1)}),
        ],
      );
      expectTypeMismatch(result);
    });
  });

  group('wrong-typed records during filtering', () {
    test('equality filter against a wrong-typed value is rejected', () {
      final result = run(
        AnalyticsQuerySpec(
          source: 'mixed',
          measures: const [CountMeasure()],
          filters: [
            Filter(
              fieldRef: refOf('i'),
              operator: FilterOperator.equals,
              value: const IntValue(1),
            ),
          ],
        ),
        [
          SourceRecord(fields: {'i': const DoubleValue(1.0)}),
        ],
      );
      expectTypeMismatch(result);
    });

    test('inList filter against wrong-typed values is rejected', () {
      final result = run(
        AnalyticsQuerySpec(
          source: 'mixed',
          measures: const [CountMeasure()],
          filters: [
            Filter(
              fieldRef: refOf('s'),
              operator: FilterOperator.inList,
              value: StringListValue(const ['a', 'b']),
            ),
          ],
        ),
        [
          SourceRecord(fields: {'s': const IntValue(1)}),
        ],
      );
      expectTypeMismatch(result);
    });
  });

  group('wrong-typed records during grouping', () {
    test('TimeGroupBy against a non-DateTimeValue field is rejected', () {
      final result = run(
        AnalyticsQuerySpec(
          source: 'mixed',
          measures: const [CountMeasure()],
          groupBys: [
            TimeGroupBy(dateFieldRef: refOf('dt'), grain: TimeGrain.day),
          ],
        ),
        [
          SourceRecord(fields: {'dt': const StringValue('2026-05-01')}),
        ],
      );
      expectTypeMismatch(result);
    });
  });

  group('wrong-typed records during streak execution', () {
    final streak = StreakMeasure(
      entityIdField: refOf('s'),
      scheduledDateField: refOf('dt'),
      statusField: refOf('e'),
      completedStatusValue: 'done',
    );

    test('scheduled-date field receiving non-DateTimeValue is rejected', () {
      final result = run(
        AnalyticsQuerySpec(source: 'mixed', measures: [streak]),
        [
          SourceRecord(
            fields: {
              's': const StringValue('habit-1'),
              'dt': const StringValue('2026-05-01'),
              'e': const EnumValue('done'),
            },
          ),
        ],
        asOf: DateTime(2026, 5, 3),
      );
      expectTypeMismatch(result);
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // NullValue and missing fields are accepted
  // ────────────────────────────────────────────────────────────────────

  group('NullValue and missing fields are valid', () {
    test('NullValue of the declared type is accepted', () {
      final result = run(
        AnalyticsQuerySpec(
          source: 'mixed',
          measures: [
            FieldMeasure(fieldRef: refOf('i'), aggregation: const SumAgg()),
          ],
        ),
        [
          SourceRecord(fields: {'i': const NullValue(FieldType.integer)}),
          SourceRecord(fields: {'i': const IntValue(5)}),
        ],
      );
      expect(result.isOk, isTrue);
      expect((result.okOrNull as ScalarResult).value, const IntValue(5));
    });

    test('NullValue with a non-matching declared type is also accepted', () {
      // NullValue is the universal "no data" signal regardless of the
      // type it carries. Even NullValue(string) for an integer field
      // is accepted — the executor treats it as "no data."
      final result = run(
        AnalyticsQuerySpec(
          source: 'mixed',
          measures: [
            FieldMeasure(fieldRef: refOf('i'), aggregation: const SumAgg()),
          ],
        ),
        [
          SourceRecord(fields: {'i': const NullValue(FieldType.string)}),
          SourceRecord(fields: {'i': const IntValue(5)}),
        ],
      );
      expect(result.isOk, isTrue);
      expect((result.okOrNull as ScalarResult).value, const IntValue(5));
    });

    test('records with no entry for a field are accepted', () {
      final result = run(
        AnalyticsQuerySpec(
          source: 'mixed',
          measures: [
            FieldMeasure(fieldRef: refOf('i'), aggregation: const SumAgg()),
          ],
        ),
        [
          SourceRecord(fields: const <String, TypedValue>{}),
          SourceRecord(fields: {'i': const IntValue(5)}),
        ],
      );
      expect(result.isOk, isTrue);
      expect((result.okOrNull as ScalarResult).value, const IntValue(5));
    });

    test('fields not declared on the source are ignored', () {
      // Records may carry fields the source doesn't declare; type
      // validation doesn't look at undeclared fields at all.
      final result = run(
        AnalyticsQuerySpec(source: 'mixed', measures: const [CountMeasure()]),
        [
          SourceRecord(
            fields: {
              'i': const IntValue(1),
              'undeclared': const StringValue('whatever'),
            },
          ),
        ],
      );
      expect(result.isOk, isTrue);
      expect((result.okOrNull as ScalarResult).value, const IntValue(1));
    });
  });
}
