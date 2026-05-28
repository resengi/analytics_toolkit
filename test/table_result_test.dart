import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:test/test.dart';

/// `TableResult` public API.
///
/// `groupKeyColumns` / `measureColumns` filter by [TableColumnKind].
/// `columnByLabel` looks up by stable label. `RowKey.singleKey`
/// returns the only element of a length-1 row key, throwing
/// `StateError` for any other length (including 0). `RowKey([])` is
/// the legal empty row key used by `(0, N)` multi-measure results.
/// `bucketKeyToTypedValue` round-trips `BucketKey` subtypes back to
/// their typed-value form.
void main() {
  /// Builds a minimal 2-column TableResult: one group-key column and
  /// one measure column, with two rows.
  TableResult sampleTable() => TableResult(
    columns: [
      TableColumn(
        label: 'status',
        fieldType: FieldType.enumeration,
        kind: TableColumnKind.groupKey,
        values: const [EnumValue('todo'), EnumValue('done')],
      ),
      TableColumn(
        label: 'count',
        fieldType: FieldType.integer,
        kind: TableColumnKind.measure,
        values: const [IntValue(3), IntValue(5)],
      ),
    ],
    rowKeys: [
      RowKey(const [StringBucketKey('todo')]),
      RowKey(const [StringBucketKey('done')]),
    ],
  );

  // ────────────────────────────────────────────────────────────────────
  // Column-kind filtering
  // ────────────────────────────────────────────────────────────────────

  group('groupKeyColumns and measureColumns', () {
    test('groupKeyColumns returns only group-key columns in display order', () {
      final t = sampleTable();
      expect(t.groupKeyColumns, hasLength(1));
      expect(t.groupKeyColumns.single.label, 'status');
    });

    test('measureColumns returns only measure columns in display order', () {
      final t = sampleTable();
      expect(t.measureColumns, hasLength(1));
      expect(t.measureColumns.single.label, 'count');
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // columnByLabel lookup
  // ────────────────────────────────────────────────────────────────────

  group('columnByLabel', () {
    test('returns the matching column', () {
      final t = sampleTable();
      expect(t.columnByLabel('status'), same(t.columns[0]));
      expect(t.columnByLabel('count'), same(t.columns[1]));
    });

    test('returns null for an unknown label', () {
      final t = sampleTable();
      expect(t.columnByLabel('nope'), isNull);
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // rowCount / isEmpty
  // ────────────────────────────────────────────────────────────────────

  group('rowCount and isEmpty', () {
    test('rowCount matches rowKeys.length and each column.values.length', () {
      final t = sampleTable();
      expect(t.rowCount, 2);
      expect(t.rowCount, t.rowKeys.length);
      for (final c in t.columns) {
        expect(c.values, hasLength(t.rowCount));
      }
    });

    test('isEmpty is true when rowKeys is empty', () {
      final t = TableResult(
        columns: [
          TableColumn(
            label: 'm',
            fieldType: FieldType.integer,
            kind: TableColumnKind.measure,
            values: const [],
          ),
        ],
        rowKeys: const [],
      );
      expect(t.isEmpty, isTrue);
      expect(t.rowCount, 0);
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // truncatedCount default
  // ────────────────────────────────────────────────────────────────────

  group('truncatedCount default', () {
    test('defaults to 0 when not specified', () {
      expect(sampleTable().truncatedCount, 0);
    });

    test('can be set non-zero via constructor', () {
      final t = TableResult(
        columns: sampleTable().columns,
        rowKeys: sampleTable().rowKeys,
        truncatedCount: 7,
      );
      expect(t.truncatedCount, 7);
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // RowKey.singleKey semantics
  // ────────────────────────────────────────────────────────────────────

  group('RowKey.singleKey', () {
    test('returns the single element for a length-1 row key', () {
      final rk = RowKey(const [StringBucketKey('x')]);
      expect(rk.singleKey, const StringBucketKey('x'));
    });

    test('throws StateError for a multi-element row key', () {
      final rk = RowKey(const [StringBucketKey('a'), StringBucketKey('b')]);
      expect(() => rk.singleKey, throwsStateError);
    });

    test('throws StateError for a length-0 row key', () {
      // Used legitimately by (0, N) multi-measure results, but
      // singleKey is undefined on it.
      final rk = RowKey(const []);
      expect(() => rk.singleKey, throwsStateError);
    });
  });

  group('RowKey empty tuple is legal', () {
    test('RowKey([]) constructs successfully and has zero keys', () {
      final rk = RowKey(const []);
      expect(rk.keys, isEmpty);
    });

    test('RowKey([]) equals another RowKey([])', () {
      expect(RowKey(const []), RowKey(const []));
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // bucketKeyToTypedValue round-trip
  // ────────────────────────────────────────────────────────────────────

  group('bucketKeyToTypedValue round-trips every BucketKey subtype', () {
    test('StringBucketKey → StringValue', () {
      expect(
        bucketKeyToTypedValue(const StringBucketKey('x'), FieldType.string),
        const StringValue('x'),
      );
    });

    test('EnumBucketKey → EnumValue', () {
      expect(
        bucketKeyToTypedValue(
          const EnumBucketKey('done'),
          FieldType.enumeration,
        ),
        const EnumValue('done'),
      );
    });

    test('BoolBucketKey → BoolValue', () {
      expect(
        bucketKeyToTypedValue(const BoolBucketKey(true), FieldType.boolean),
        const BoolValue(true),
      );
    });

    test('IntBucketKey → IntValue when fieldType is integer', () {
      expect(
        bucketKeyToTypedValue(const IntBucketKey(42), FieldType.integer),
        const IntValue(42),
      );
    });

    test('IntBucketKey → DurationValue when fieldType is duration', () {
      // Integer-keyed durations carry microseconds; this is the only
      // place the fieldType disambiguates an integer key.
      expect(
        bucketKeyToTypedValue(const IntBucketKey(1000), FieldType.duration),
        const DurationValue(Duration(microseconds: 1000)),
      );
    });

    test('DoubleBucketKey → DoubleValue', () {
      expect(
        bucketKeyToTypedValue(const DoubleBucketKey(3.14), FieldType.double),
        const DoubleValue(3.14),
      );
    });

    test('TimeBucketKey → DateTimeValue', () {
      final dt = DateTime(2026, 5, 1);
      expect(
        bucketKeyToTypedValue(
          TimeBucketKey(instant: dt, grain: TimeGrain.day),
          FieldType.dateTime,
        ),
        DateTimeValue(dt),
      );
    });

    test('NullBucketKey → NullValue with the column field type', () {
      expect(
        bucketKeyToTypedValue(const NullBucketKey(), FieldType.string),
        const NullValue(FieldType.string),
      );
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // Constructor invariants
  // ────────────────────────────────────────────────────────────────────

  group('constructor invariants', () {
    test('rejects a column whose length disagrees with rowKeys', () {
      expect(
        () => TableResult(
          columns: [
            TableColumn(
              label: 'status',
              fieldType: FieldType.enumeration,
              kind: TableColumnKind.groupKey,
              values: const [EnumValue('todo'), EnumValue('done')],
            ),
            TableColumn(
              label: 'count',
              fieldType: FieldType.integer,
              kind: TableColumnKind.measure,
              // One value, two row keys — mismatch.
              values: const [IntValue(3)],
            ),
          ],
          rowKeys: [
            RowKey(const [StringBucketKey('todo')]),
            RowKey(const [StringBucketKey('done')]),
          ],
        ),
        throwsArgumentError,
      );
    });

    test('rejects a syntheticRowIndices entry outside [0, rowCount)', () {
      expect(
        () => TableResult(
          columns: [
            TableColumn(
              label: 'status',
              fieldType: FieldType.enumeration,
              kind: TableColumnKind.groupKey,
              values: const [EnumValue('todo')],
            ),
          ],
          rowKeys: [
            RowKey(const [StringBucketKey('todo')]),
          ],
          // The only valid index for a single-row table is 0.
          syntheticRowIndices: const {1},
        ),
        throwsArgumentError,
      );
    });

    test('accepts a zero-row table with no columns', () {
      // The empty case must still construct cleanly. All columns have
      // length 0, matching rowKeys.length.
      expect(
        () => TableResult(columns: const [], rowKeys: const []),
        returnsNormally,
      );
    });
  });
}
