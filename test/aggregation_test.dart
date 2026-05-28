import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:test/test.dart';

/// Pins the actual aggregation arithmetic against representative
/// records — the math, not the dispatch (the dispatch is in
/// `field_aggregation_test.dart`). Each test runs a no-grouping query
/// and asserts the resulting `ScalarResult.value`.
///
/// `CountMeasure` counts every record in a bucket (including those
/// with `NullValue` fields or missing fields) because it doesn't
/// read any field. Every other aggregation reads a specific field
/// and skips `NullValue` and missing-field entries. The asymmetry is
/// intentional and is pinned by the per-aggregation tests below.
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
        groupable: false,
        aggregatable: true,
        sortable: true,
      ),
    ],
  );

  FieldRef refOf(String id) => FieldRef(sourceId: 'mixed', fieldId: id);

  /// Three records with `i = 1/2/3`, `d = 1.5/2.5/3.5`,
  /// `dur = 100/200/300 ms`, `dt = May 1/2/3, 2026`. Reused across
  /// the per-aggregation groups below.
  List<SourceRecord> mixedRecords() => [
    SourceRecord(
      fields: {
        'i': const IntValue(1),
        'd': const DoubleValue(1.5),
        'dur': const DurationValue(Duration(milliseconds: 100)),
        'dt': DateTimeValue(DateTime(2026, 5, 1)),
      },
    ),
    SourceRecord(
      fields: {
        'i': const IntValue(2),
        'd': const DoubleValue(2.5),
        'dur': const DurationValue(Duration(milliseconds: 200)),
        'dt': DateTimeValue(DateTime(2026, 5, 2)),
      },
    ),
    SourceRecord(
      fields: {
        'i': const IntValue(3),
        'd': const DoubleValue(3.5),
        'dur': const DurationValue(Duration(milliseconds: 300)),
        'dt': DateTimeValue(DateTime(2026, 5, 3)),
      },
    ),
  ];

  /// Runs a no-grouping single-measure query and returns the
  /// `ScalarResult`. Casts on failure produce a clear test diagnostic.
  ScalarResult runScalar(Measure measure, List<SourceRecord> records) {
    final result = AnalyticsExecutor.execute(
      query: AnalyticsQuerySpec(source: 'mixed', measures: [measure]),
      records: records,
      sources: [source],
    );
    return result.okOrNull as ScalarResult;
  }

  // ────────────────────────────────────────────────────────────────────
  // count
  // ────────────────────────────────────────────────────────────────────

  group('count — record-presence count, not field-aware', () {
    test('over N records returns IntValue(N)', () {
      final r = runScalar(const CountMeasure(), mixedRecords());
      expect(r.value, const IntValue(3));
    });

    test('over zero records returns IntValue(0)', () {
      final r = runScalar(const CountMeasure(), const []);
      expect(r.value, const IntValue(0));
    });

    test('counts records with NullValue and missing-field entries', () {
      // Count reads no field — it just measures bucket size — so
      // records with NullValue or no entry for any field are still
      // counted. This is the asymmetry vs. every other aggregation.
      final records = [
        SourceRecord(fields: {'i': const IntValue(1)}),
        SourceRecord(fields: {'i': const NullValue(FieldType.integer)}),
        SourceRecord(fields: const <String, TypedValue>{}),
      ];
      final r = runScalar(const CountMeasure(), records);
      expect(r.value, const IntValue(3));
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // sum
  // ────────────────────────────────────────────────────────────────────

  group('sum — additive total, output type preserves input type', () {
    test('integer field returns IntValue', () {
      final r = runScalar(
        FieldMeasure(fieldRef: refOf('i'), aggregation: const SumAgg()),
        mixedRecords(),
      );
      expect(r.value, const IntValue(6));
    });

    test('double field returns DoubleValue', () {
      final r = runScalar(
        FieldMeasure(fieldRef: refOf('d'), aggregation: const SumAgg()),
        mixedRecords(),
      );
      expect(r.value, const DoubleValue(7.5));
    });

    test('duration field returns DurationValue', () {
      final r = runScalar(
        FieldMeasure(fieldRef: refOf('dur'), aggregation: const SumAgg()),
        mixedRecords(),
      );
      expect(r.value, const DurationValue(Duration(milliseconds: 600)));
    });

    test('integer field over empty returns IntValue(0)', () {
      final r = runScalar(
        FieldMeasure(fieldRef: refOf('i'), aggregation: const SumAgg()),
        const [],
      );
      expect(r.value, const IntValue(0));
    });

    test('double field over empty returns DoubleValue(0.0)', () {
      final r = runScalar(
        FieldMeasure(fieldRef: refOf('d'), aggregation: const SumAgg()),
        const [],
      );
      expect(r.value, const DoubleValue(0.0));
    });

    test('duration field over empty returns DurationValue(zero)', () {
      final r = runScalar(
        FieldMeasure(fieldRef: refOf('dur'), aggregation: const SumAgg()),
        const [],
      );
      expect(r.value, const DurationValue(Duration.zero));
    });

    test('skips NullValue entries', () {
      final records = [
        SourceRecord(fields: {'i': const IntValue(2)}),
        SourceRecord(fields: {'i': const NullValue(FieldType.integer)}),
        SourceRecord(fields: {'i': const IntValue(3)}),
      ];
      final r = runScalar(
        FieldMeasure(fieldRef: refOf('i'), aggregation: const SumAgg()),
        records,
      );
      expect(r.value, const IntValue(5));
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // average
  // ────────────────────────────────────────────────────────────────────

  group('average — mean, widens integer to double', () {
    test('integer field returns DoubleValue', () {
      final r = runScalar(
        FieldMeasure(fieldRef: refOf('i'), aggregation: const AverageAgg()),
        mixedRecords(),
      );
      expect(r.value, const DoubleValue(2.0));
    });

    test('double field returns DoubleValue', () {
      final r = runScalar(
        FieldMeasure(fieldRef: refOf('d'), aggregation: const AverageAgg()),
        mixedRecords(),
      );
      expect(r.value, const DoubleValue(2.5));
    });

    test('duration field returns DurationValue', () {
      final r = runScalar(
        FieldMeasure(fieldRef: refOf('dur'), aggregation: const AverageAgg()),
        mixedRecords(),
      );
      expect(r.value, const DurationValue(Duration(milliseconds: 200)));
    });

    test('over empty returns null', () {
      final r = runScalar(
        FieldMeasure(fieldRef: refOf('i'), aggregation: const AverageAgg()),
        const [],
      );
      expect(r.value, isNull);
    });

    test('skips NullValue entries', () {
      final records = [
        SourceRecord(fields: {'i': const IntValue(2)}),
        SourceRecord(fields: {'i': const NullValue(FieldType.integer)}),
        SourceRecord(fields: {'i': const IntValue(4)}),
      ];
      final r = runScalar(
        FieldMeasure(fieldRef: refOf('i'), aggregation: const AverageAgg()),
        records,
      );
      // (2 + 4) / 2 = 3.0; the NullValue record doesn't count.
      expect(r.value, const DoubleValue(3.0));
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // min
  // ────────────────────────────────────────────────────────────────────

  group('min — smallest value, preserves input type', () {
    test('integer field returns smallest IntValue', () {
      final r = runScalar(
        FieldMeasure(fieldRef: refOf('i'), aggregation: const MinAgg()),
        mixedRecords(),
      );
      expect(r.value, const IntValue(1));
    });

    test('double field returns smallest DoubleValue', () {
      final r = runScalar(
        FieldMeasure(fieldRef: refOf('d'), aggregation: const MinAgg()),
        mixedRecords(),
      );
      expect(r.value, const DoubleValue(1.5));
    });

    test('duration field returns smallest DurationValue', () {
      final r = runScalar(
        FieldMeasure(fieldRef: refOf('dur'), aggregation: const MinAgg()),
        mixedRecords(),
      );
      expect(r.value, const DurationValue(Duration(milliseconds: 100)));
    });

    test('dateTime field returns earliest DateTimeValue', () {
      final r = runScalar(
        FieldMeasure(fieldRef: refOf('dt'), aggregation: const MinAgg()),
        mixedRecords(),
      );
      expect(r.value, DateTimeValue(DateTime(2026, 5, 1)));
    });

    test('over empty returns null', () {
      final r = runScalar(
        FieldMeasure(fieldRef: refOf('i'), aggregation: const MinAgg()),
        const [],
      );
      expect(r.value, isNull);
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // max
  // ────────────────────────────────────────────────────────────────────

  group('max — largest value, preserves input type', () {
    test('integer field returns largest IntValue', () {
      final r = runScalar(
        FieldMeasure(fieldRef: refOf('i'), aggregation: const MaxAgg()),
        mixedRecords(),
      );
      expect(r.value, const IntValue(3));
    });

    test('double field returns largest DoubleValue', () {
      final r = runScalar(
        FieldMeasure(fieldRef: refOf('d'), aggregation: const MaxAgg()),
        mixedRecords(),
      );
      expect(r.value, const DoubleValue(3.5));
    });

    test('duration field returns largest DurationValue', () {
      final r = runScalar(
        FieldMeasure(fieldRef: refOf('dur'), aggregation: const MaxAgg()),
        mixedRecords(),
      );
      expect(r.value, const DurationValue(Duration(milliseconds: 300)));
    });

    test('dateTime field returns latest DateTimeValue', () {
      final r = runScalar(
        FieldMeasure(fieldRef: refOf('dt'), aggregation: const MaxAgg()),
        mixedRecords(),
      );
      expect(r.value, DateTimeValue(DateTime(2026, 5, 3)));
    });

    test('over empty returns null', () {
      final r = runScalar(
        FieldMeasure(fieldRef: refOf('i'), aggregation: const MaxAgg()),
        const [],
      );
      expect(r.value, isNull);
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // distinctCount
  // ────────────────────────────────────────────────────────────────────

  group('distinctCount — unique non-null values, always integer', () {
    test('integer field counts unique IntValues', () {
      final r = runScalar(
        FieldMeasure(
          fieldRef: refOf('i'),
          aggregation: const DistinctCountAgg(),
        ),
        mixedRecords(),
      );
      expect(r.value, const IntValue(3));
    });

    test('duplicate values are collapsed', () {
      final records = [
        SourceRecord(fields: {'i': const IntValue(1)}),
        SourceRecord(fields: {'i': const IntValue(1)}),
        SourceRecord(fields: {'i': const IntValue(2)}),
      ];
      final r = runScalar(
        FieldMeasure(
          fieldRef: refOf('i'),
          aggregation: const DistinctCountAgg(),
        ),
        records,
      );
      expect(r.value, const IntValue(2));
    });

    test('skips NullValue and missing-field entries', () {
      final records = [
        SourceRecord(fields: {'i': const IntValue(1)}),
        SourceRecord(fields: {'i': const IntValue(1)}),
        SourceRecord(fields: {'i': const NullValue(FieldType.integer)}),
        SourceRecord(fields: const <String, TypedValue>{}),
      ];
      final r = runScalar(
        FieldMeasure(
          fieldRef: refOf('i'),
          aggregation: const DistinctCountAgg(),
        ),
        records,
      );
      expect(r.value, const IntValue(1));
    });

    test('over empty returns IntValue(0)', () {
      final r = runScalar(
        FieldMeasure(
          fieldRef: refOf('i'),
          aggregation: const DistinctCountAgg(),
        ),
        const [],
      );
      expect(r.value, const IntValue(0));
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // percentile
  // ────────────────────────────────────────────────────────────────────

  group('percentile — type-7 interpolation between surrounding indices', () {
    /// Builds a record set with `i` taking the listed values.
    List<SourceRecord> records(List<int> values) => [
      for (final v in values) SourceRecord(fields: {'i': IntValue(v)}),
    ];

    test('p=0.0 returns the smallest value', () {
      final r = runScalar(
        FieldMeasure(
          fieldRef: refOf('i'),
          aggregation: const PercentileAgg(p: 0.0),
        ),
        records([10, 30, 20]),
      );
      // Sorted: [10, 20, 30]; idx = 0 → 10.
      expect(r.value, const DoubleValue(10.0));
    });

    test('p=1.0 returns the largest value', () {
      final r = runScalar(
        FieldMeasure(
          fieldRef: refOf('i'),
          aggregation: const PercentileAgg(p: 1.0),
        ),
        records([10, 30, 20]),
      );
      // Sorted: [10, 20, 30]; idx = 2 → 30.
      expect(r.value, const DoubleValue(30.0));
    });

    test('p=0.5 over [1, 2, 3] hits the middle index exactly', () {
      // n = 3; idx = 0.5 × 2 = 1.0 (integer); value at index 1 = 2.
      final r = runScalar(
        FieldMeasure(
          fieldRef: refOf('i'),
          aggregation: const PercentileAgg(p: 0.5),
        ),
        records([1, 2, 3]),
      );
      expect(r.value, const DoubleValue(2.0));
    });

    test('p=0.25 over [1, 2, 3, 4] interpolates between indices 0 and 1', () {
      // n = 4; idx = 0.25 × 3 = 0.75; values at 0 and 1 are 1 and 2.
      // Interpolated: 1 + 0.75 × (2 - 1) = 1.75.
      final r = runScalar(
        FieldMeasure(
          fieldRef: refOf('i'),
          aggregation: const PercentileAgg(p: 0.25),
        ),
        records([1, 2, 3, 4]),
      );
      expect(r.value, const DoubleValue(1.75));
    });

    test('p=0.5 over duration field returns DurationValue median', () {
      final records = [
        SourceRecord(
          fields: {'dur': const DurationValue(Duration(milliseconds: 100))},
        ),
        SourceRecord(
          fields: {'dur': const DurationValue(Duration(milliseconds: 200))},
        ),
        SourceRecord(
          fields: {'dur': const DurationValue(Duration(milliseconds: 300))},
        ),
      ];
      final r = runScalar(
        FieldMeasure(
          fieldRef: refOf('dur'),
          aggregation: const PercentileAgg(p: 0.5),
        ),
        records,
      );
      expect(r.value, const DurationValue(Duration(milliseconds: 200)));
    });

    test('over empty returns null', () {
      final r = runScalar(
        FieldMeasure(
          fieldRef: refOf('i'),
          aggregation: const PercentileAgg(p: 0.5),
        ),
        const [],
      );
      expect(r.value, isNull);
    });

    test('over all-NullValue records returns null', () {
      final records = [
        SourceRecord(fields: {'i': const NullValue(FieldType.integer)}),
        SourceRecord(fields: const <String, TypedValue>{}),
      ];
      final r = runScalar(
        FieldMeasure(
          fieldRef: refOf('i'),
          aggregation: const PercentileAgg(p: 0.5),
        ),
        records,
      );
      expect(r.value, isNull);
    });
  });
}
