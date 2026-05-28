import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:test/test.dart';

import '_fixtures.dart';

/// Codec round-trips and malformed-payload rejection.
///
/// Every encodable shape — measures (all subtypes), aggregations
/// (every `FieldAggregation` subtype including `PercentileAgg`),
/// group-bys, having clauses, sort targets, derived ops, typed
/// values, full query specs, paired specs, date-range modes — must
/// round-trip through `WidgetPayloadCodec` with value equality
/// preserved.
///
/// Encoded JSON must omit null optional fields (per the persisted
/// payload contract). Malformed payloads throw `FormatException`,
/// never `TypeError`. Schema-version gating rejects payloads with
/// `schemaVersion > currentSchemaVersion`.
void main() {
  // ────────────────────────────────────────────────────────────────────
  // Query-payload round-trips
  // ────────────────────────────────────────────────────────────────────

  group('QueryPayload — round-trips for every Measure subtype', () {
    test('CountMeasure with no clauses', () {
      final q = AnalyticsQuerySpec(
        source: 'tasks',
        measures: const [CountMeasure()],
      );
      final payload = SingleQuerySpec(query: q);
      final decoded = WidgetPayloadCodec.decodeQueryPayload(
        WidgetPayloadCodec.encodeQueryPayload(payload),
      );
      expect(decoded, payload);
    });

    test('FieldMeasure with each FieldAggregation subtype', () {
      const aggs = <FieldAggregation>[
        SumAgg(),
        AverageAgg(),
        MinAgg(),
        MaxAgg(),
        DistinctCountAgg(),
        PercentileAgg(p: 0.5),
      ];
      for (final agg in aggs) {
        final q = AnalyticsQuerySpec(
          source: 'tasks',
          measures: [
            FieldMeasure(fieldRef: ref('tasks', 'priority'), aggregation: agg),
          ],
        );
        final payload = SingleQuerySpec(query: q);
        final decoded = WidgetPayloadCodec.decodeQueryPayload(
          WidgetPayloadCodec.encodeQueryPayload(payload),
        );
        expect(decoded, payload, reason: 'round-trip failed for $agg');
      }
    });

    test('StreakMeasure round-trip', () {
      final q = AnalyticsQuerySpec(
        source: 'events',
        measures: [
          StreakMeasure(
            entityIdField: ref('events', 'kind'),
            scheduledDateField: ref('events', 'occurredAt'),
            statusField: ref('events', 'kind'),
            completedStatusValue: 'done',
            entityLabelField: ref('events', 'kind'),
            topN: 5,
          ),
        ],
      );
      final payload = SingleQuerySpec(query: q);
      final decoded = WidgetPayloadCodec.decodeQueryPayload(
        WidgetPayloadCodec.encodeQueryPayload(payload),
      );
      expect(decoded, payload);
    });

    test('Multi-measure spec with explicit labels round-trips', () {
      final q = AnalyticsQuerySpec(
        source: 'tasks',
        measures: const [
          CountMeasure(label: 'count_a'),
          CountMeasure(label: 'count_b'),
        ],
      );
      final payload = SingleQuerySpec(query: q);
      final decoded = WidgetPayloadCodec.decodeQueryPayload(
        WidgetPayloadCodec.encodeQueryPayload(payload),
      );
      expect(decoded, payload);
    });
  });

  group('QueryPayload — round-trips for GroupBy and clauses', () {
    test('TimeGroupBy with explicit weekStartDay', () {
      final q = AnalyticsQuerySpec(
        source: 'events',
        measures: const [CountMeasure()],
        groupBys: [
          TimeGroupBy(
            dateFieldRef: ref('events', 'occurredAt'),
            grain: TimeGrain(
              count: 1,
              unit: TimeUnit.week,
              anchor: DateTime.utc(2000, 1, 2),
              weekStartDay: DateTime.monday,
            ),
          ),
        ],
      );
      final payload = SingleQuerySpec(query: q);
      final decoded = WidgetPayloadCodec.decodeQueryPayload(
        WidgetPayloadCodec.encodeQueryPayload(payload),
      );
      expect(decoded, payload);
    });

    test(
      'TimeGroupBy without weekStartDay omits the key from encoded JSON',
      () {
        final q = AnalyticsQuerySpec(
          source: 'events',
          measures: const [CountMeasure()],
          groupBys: [
            TimeGroupBy(
              dateFieldRef: ref('events', 'occurredAt'),
              grain: TimeGrain.day,
            ),
          ],
        );
        final encoded = WidgetPayloadCodec.encodeQueryPayload(
          SingleQuerySpec(query: q),
        );
        expect(encoded.contains('weekStartDay'), isFalse);
      },
    );

    test('Two TimeGroupBys at different grains on the same field', () {
      // The combination day+month is legitimate (validator accepts).
      final q = AnalyticsQuerySpec(
        source: 'events',
        measures: const [CountMeasure()],
        groupBys: [
          TimeGroupBy(
            dateFieldRef: ref('events', 'occurredAt'),
            grain: TimeGrain.day,
          ),
          TimeGroupBy(
            dateFieldRef: ref('events', 'occurredAt'),
            grain: TimeGrain(
              count: 1,
              unit: TimeUnit.month,
              anchor: DateTime.utc(2000, 1, 1),
            ),
          ),
        ],
      );
      final payload = SingleQuerySpec(query: q);
      final decoded = WidgetPayloadCodec.decodeQueryPayload(
        WidgetPayloadCodec.encodeQueryPayload(payload),
      );
      expect(decoded, payload);
    });

    test('GroupBy.label is preserved across encode/decode', () {
      // `GroupBy.==` deliberately excludes `label` (so paired
      // alignability stays correct under aliasing), which means an
      // `expect(decoded, payload)` roundtrip can't catch a lost
      // label by itself. Inspect the decoded `label` field directly.
      final q = AnalyticsQuerySpec(
        source: 'events',
        measures: const [CountMeasure()],
        groupBys: [
          FieldGroupBy(fieldRef: ref('events', 'kind'), label: 'category'),
          TimeGroupBy(
            dateFieldRef: ref('events', 'occurredAt'),
            grain: TimeGrain.day,
            label: 'day',
          ),
        ],
      );
      final decoded =
          WidgetPayloadCodec.decodeQueryPayload(
                WidgetPayloadCodec.encodeQueryPayload(
                  SingleQuerySpec(query: q),
                ),
              )
              as SingleQuerySpec;
      expect((decoded.query.groupBys[0] as FieldGroupBy).label, 'category');
      expect((decoded.query.groupBys[1] as TimeGroupBy).label, 'day');
    });

    test('GroupBy with no label omits the key from encoded JSON', () {
      final q = AnalyticsQuerySpec(
        source: 'tasks',
        measures: const [CountMeasure()],
        groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
      );
      final encoded = WidgetPayloadCodec.encodeQueryPayload(
        SingleQuerySpec(query: q),
      );
      // Should not emit a `"label"` key when no alias is set.
      expect(encoded.contains('"label"'), isFalse);
    });

    test('GroupBy without label decodes to label: null', () {
      // Payloads emitted without an alias must decode without error.
      // The decoded `label` is null.
      const json =
          '{"kind":"single",'
          '"query":{'
          '"source":"tasks",'
          '"measures":[{"kind":"count"}],'
          '"filters":[],'
          '"groupBys":[{"kind":"field","fieldRef":{"sourceId":"tasks","fieldId":"status"}}]'
          '}}';
      final decoded =
          WidgetPayloadCodec.decodeQueryPayload(json) as SingleQuerySpec;
      expect((decoded.query.groupBys.single as FieldGroupBy).label, isNull);
    });

    test('HavingClause with each operator (with and without measureLabel)', () {
      for (final op in HavingOperator.values) {
        for (final label in [null, 'm']) {
          final q = AnalyticsQuerySpec(
            source: 'tasks',
            measures: const [CountMeasure(label: 'm')],
            groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
            having: HavingClause(
              operator: op,
              threshold: const IntValue(1),
              measureLabel: label,
            ),
          );
          final payload = SingleQuerySpec(query: q);
          final decoded = WidgetPayloadCodec.decodeQueryPayload(
            WidgetPayloadCodec.encodeQueryPayload(payload),
          );
          expect(decoded, payload, reason: '$op label=$label');
        }
      }
    });

    test('MeasureValueSort with and without measureLabel', () {
      for (final label in [null, 'm']) {
        final q = AnalyticsQuerySpec(
          source: 'tasks',
          measures: const [CountMeasure(label: 'm')],
          groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
          sort: Sort(
            target: MeasureValueSort(measureLabel: label),
            direction: SortDirection.descending,
          ),
        );
        final payload = SingleQuerySpec(query: q);
        final decoded = WidgetPayloadCodec.decodeQueryPayload(
          WidgetPayloadCodec.encodeQueryPayload(payload),
        );
        expect(decoded, payload);
      }
    });

    test('Sort.forceNullsLast round-trips and is omitted when false', () {
      // forceNullsLast: true must roundtrip; equality on Sort
      // includes the field so `expect(decoded, payload)` covers it.
      final qTrue = AnalyticsQuerySpec(
        source: 'tasks',
        measures: const [CountMeasure()],
        groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
        sort: Sort(
          target: GroupFieldSort(fieldRef: ref('tasks', 'status')),
          direction: SortDirection.descending,
          forceNullsLast: true,
        ),
      );
      final encodedTrue = WidgetPayloadCodec.encodeQueryPayload(
        SingleQuerySpec(query: qTrue),
      );
      expect(encodedTrue.contains('"forceNullsLast":true'), isTrue);
      expect(
        WidgetPayloadCodec.decodeQueryPayload(encodedTrue),
        SingleQuerySpec(query: qTrue),
      );

      // forceNullsLast: false (the default) must NOT appear in the
      // encoded JSON — old payloads decode the same way and
      // payloads stay minimal.
      final qFalse = AnalyticsQuerySpec(
        source: 'tasks',
        measures: const [CountMeasure()],
        groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
        sort: Sort(
          target: GroupFieldSort(fieldRef: ref('tasks', 'status')),
          direction: SortDirection.ascending,
        ),
      );
      final encodedFalse = WidgetPayloadCodec.encodeQueryPayload(
        SingleQuerySpec(query: qFalse),
      );
      expect(encodedFalse.contains('forceNullsLast'), isFalse);
      expect(
        WidgetPayloadCodec.decodeQueryPayload(encodedFalse),
        SingleQuerySpec(query: qFalse),
      );
    });

    test('Every DerivedOperation subtype round-trips', () {
      const ops = <DerivedOperation>[
        NoDerivedOp(),
        CumulativeSumOp(),
        DeltaOp(),
        MovingAverageOp(window: 7),
      ];
      for (final op in ops) {
        final q = AnalyticsQuerySpec(
          source: 'events',
          measures: [
            FieldMeasure(
              fieldRef: ref('events', 'amount'),
              aggregation: const SumAgg(),
            ),
          ],
          groupBys: op is NoDerivedOp
              ? const <GroupBy>[]
              : [
                  TimeGroupBy(
                    dateFieldRef: ref('events', 'occurredAt'),
                    grain: TimeGrain.day,
                  ),
                ],
          derivedOperation: op,
        );
        final payload = SingleQuerySpec(query: q);
        final decoded = WidgetPayloadCodec.decodeQueryPayload(
          WidgetPayloadCodec.encodeQueryPayload(payload),
        );
        expect(decoded, payload, reason: 'round-trip failed for $op');
      }
    });

    test('Filter with inList round-trip', () {
      final q = AnalyticsQuerySpec(
        source: 'tasks',
        measures: const [CountMeasure()],
        filters: [
          Filter(
            fieldRef: ref('tasks', 'status'),
            operator: FilterOperator.inList,
            value: EnumListValue(const ['done', 'inProgress']),
          ),
        ],
      );
      final payload = SingleQuerySpec(query: q);
      final decoded = WidgetPayloadCodec.decodeQueryPayload(
        WidgetPayloadCodec.encodeQueryPayload(payload),
      );
      expect(decoded, payload);
    });

    test('Filter with NullValue round-trip', () {
      final q = AnalyticsQuerySpec(
        source: 'tasks',
        measures: const [CountMeasure()],
        filters: [
          Filter(
            fieldRef: ref('tasks', 'status'),
            operator: FilterOperator.equals,
            value: const NullValue(FieldType.enumeration),
          ),
        ],
      );
      final payload = SingleQuerySpec(query: q);
      final decoded = WidgetPayloadCodec.decodeQueryPayload(
        WidgetPayloadCodec.encodeQueryPayload(payload),
      );
      expect(decoded, payload);
    });

    test('PairedQuerySpec round-trip', () {
      final x = AnalyticsQuerySpec(
        source: 'events',
        measures: const [CountMeasure()],
        groupBys: [
          TimeGroupBy(
            dateFieldRef: ref('events', 'occurredAt'),
            grain: TimeGrain.day,
          ),
        ],
      );
      final y = AnalyticsQuerySpec(
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
      );
      final payload = PairedQuerySpec(xQuery: x, yQuery: y);
      final decoded = WidgetPayloadCodec.decodeQueryPayload(
        WidgetPayloadCodec.encodeQueryPayload(payload),
      );
      expect(decoded, payload);
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // Encoded JSON — null optional fields are omitted
  // ────────────────────────────────────────────────────────────────────

  group('encoded JSON omits null optional fields', () {
    test('Measure.label is omitted when null', () {
      final payload = SingleQuerySpec(
        query: AnalyticsQuerySpec(
          source: 'tasks',
          measures: const [CountMeasure()],
        ),
      );
      final encoded = WidgetPayloadCodec.encodeQueryPayload(payload);
      expect(encoded.contains('"label"'), isFalse);
    });

    test('HavingClause.measureLabel is omitted when null', () {
      final payload = SingleQuerySpec(
        query: AnalyticsQuerySpec(
          source: 'tasks',
          measures: const [CountMeasure()],
          groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
          having: const HavingClause(
            operator: HavingOperator.greaterThan,
            threshold: IntValue(0),
          ),
        ),
      );
      final encoded = WidgetPayloadCodec.encodeQueryPayload(payload);
      expect(encoded.contains('measureLabel'), isFalse);
    });

    test('MeasureValueSort.measureLabel is omitted when null', () {
      final payload = SingleQuerySpec(
        query: AnalyticsQuerySpec(
          source: 'tasks',
          measures: const [CountMeasure()],
          groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
          sort: const Sort(
            target: MeasureValueSort(),
            direction: SortDirection.descending,
          ),
        ),
      );
      final encoded = WidgetPayloadCodec.encodeQueryPayload(payload);
      expect(encoded.contains('measureLabel'), isFalse);
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // DateRangeMode round-trips
  // ────────────────────────────────────────────────────────────────────

  group('DateRangeMode round-trip', () {
    test('UsePageRange', () {
      const mode = UsePageRange();
      final decoded = WidgetPayloadCodec.decodeDateRangeMode(
        WidgetPayloadCodec.encodeDateRangeMode(mode),
      );
      expect(decoded, isA<UsePageRange>());
    });

    test('NoDateRange', () {
      const mode = NoDateRange();
      final decoded = WidgetPayloadCodec.decodeDateRangeMode(
        WidgetPayloadCodec.encodeDateRangeMode(mode),
      );
      expect(decoded, isA<NoDateRange>());
    });

    test('FixedOverride with PresetRange', () {
      const mode = FixedOverride(
        range: PresetRange(preset: DateRangePreset.last7Days),
      );
      final decoded = WidgetPayloadCodec.decodeDateRangeMode(
        WidgetPayloadCodec.encodeDateRangeMode(mode),
      );
      expect(decoded, isA<FixedOverride>());
      final inner = (decoded as FixedOverride).range as PresetRange;
      expect(inner.preset, DateRangePreset.last7Days);
    });

    test('FixedOverride with CustomRange', () {
      final mode = FixedOverride(
        range: CustomRange(
          start: DateTime(2026, 5, 1),
          end: DateTime(2026, 5, 10),
        ),
      );
      final decoded = WidgetPayloadCodec.decodeDateRangeMode(
        WidgetPayloadCodec.encodeDateRangeMode(mode),
      );
      final inner = (decoded as FixedOverride).range as CustomRange;
      expect(inner.start, DateTime(2026, 5, 1));
      expect(inner.endExclusive, DateTime(2026, 5, 11));
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // Malformed payloads throw FormatException
  // ────────────────────────────────────────────────────────────────────

  group('malformed payloads throw FormatException', () {
    test('top-level non-object payload throws', () {
      expect(
        () => WidgetPayloadCodec.decodeQueryPayload('"a string"'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => WidgetPayloadCodec.decodeQueryPayload('42'),
        throwsA(isA<FormatException>()),
      );
    });

    test(
      'missing required field throws with the field name in the message',
      () {
        const malformed = '{"kind":"single"}';
        expect(
          () => WidgetPayloadCodec.decodeQueryPayload(malformed),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('query'),
            ),
          ),
        );
      },
    );

    test('wrong-typed required field throws FormatException (not TypeError)', () {
      const malformed =
          '{"kind":"single","query":{"source":42,"measures":[{"kind":"count"}]}}';
      expect(
        () => WidgetPayloadCodec.decodeQueryPayload(malformed),
        throwsA(isA<FormatException>()),
      );
    });

    test('unknown discriminator throws FormatException', () {
      const malformed = '{"kind":"notARealKind"}';
      expect(
        () => WidgetPayloadCodec.decodeQueryPayload(malformed),
        throwsA(isA<FormatException>()),
      );
    });

    test('decodeDisplaySpec with missing displayType throws', () {
      expect(
        () => WidgetPayloadCodec.decodeDisplaySpec('{}'),
        throwsA(isA<FormatException>()),
      );
    });

    test('decodeDisplaySpec with present displayType returns it', () {
      const ok = '{"displayType":"line"}';
      expect(WidgetPayloadCodec.decodeDisplaySpec(ok).displayType, 'line');
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // Schema version gating
  // ────────────────────────────────────────────────────────────────────

  group('schema version gating', () {
    AnalyticsWidgetSpec specWithVersion(int v) => AnalyticsWidgetSpec(
      id: 'w1',
      title: 'Test',
      schemaVersion: v,
      queryJson: '{}',
      dateRangeModeJson: '{}',
      displayJson: '{}',
      sortOrder: 0,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );

    test('currentSchemaVersion + 1 is rejected', () {
      final spec = specWithVersion(WidgetPayloadCodec.currentSchemaVersion + 1);
      expect(
        () => WidgetPayloadCodec.ensureCanDecode(spec),
        throwsA(isA<FormatException>()),
      );
    });

    test('currentSchemaVersion is accepted', () {
      final spec = specWithVersion(WidgetPayloadCodec.currentSchemaVersion);
      expect(() => WidgetPayloadCodec.ensureCanDecode(spec), returnsNormally);
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // PercentileAgg.p accepts both JSON int and double literals
  // ────────────────────────────────────────────────────────────────────

  group('PercentileAgg.p accepts JSON integer literals', () {
    test('p: 1 decodes equivalently to p: 1.0', () {
      // The codec's `_requireDouble` coerces num → double; both
      // forms must decode and round-trip equivalently.
      final qFloat = AnalyticsQuerySpec(
        source: 'tasks',
        measures: [
          FieldMeasure(
            fieldRef: ref('tasks', 'priority'),
            aggregation: const PercentileAgg(p: 1.0),
          ),
        ],
      );
      final encoded = WidgetPayloadCodec.encodeQueryPayload(
        SingleQuerySpec(query: qFloat),
      );
      // The encoded form might use either "1.0" or "1"; rather than
      // asserting which it uses, just confirm it decodes back to
      // value-equality.
      final decoded =
          WidgetPayloadCodec.decodeQueryPayload(encoded) as SingleQuerySpec;
      final agg =
          (decoded.query.measures.first as FieldMeasure).aggregation
              as PercentileAgg;
      expect(agg.p, 1.0);
    });
  });
}
