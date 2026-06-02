import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:test/test.dart';

import '_fixtures.dart';

/// Behavioral tests for `DerivedEngine`. Derived operations transform
/// the values of a `SeriesResult` in place — they must not change the
/// bucket count, the bucket keys, or the per-bucket metadata that
/// downstream consumers rely on. The per-bucket metadata at issue
/// here is `SeriesBucket.isSynthetic`, which marks buckets that came
/// from densification rather than from observed records.
void main() {
  final events = eventsSource();

  /// Records on May 1 and May 3 over the range May 1 – May 4 with day
  /// grain yields three day-buckets with `isSynthetic = [false, true,
  /// false]`. Used by the per-op tests below: the derived operation is
  /// the only thing that varies.
  List<SourceRecord> recordsOnFirstAndThird() => [
    SourceRecord(
      fields: {
        'occurredAt': DateTimeValue(DateTime(2026, 5, 1)),
        'amount': const IntValue(1),
      },
    ),
    SourceRecord(
      fields: {
        'occurredAt': DateTimeValue(DateTime(2026, 5, 3)),
        'amount': const IntValue(1),
      },
    ),
  ];

  /// Executes a day-grained `CountMeasure` query over [records] with
  /// the supplied derived [operation], densified across May 1 – May 4.
  SeriesResult runWithOperation({
    required List<SourceRecord> records,
    required DerivedOperation operation,
  }) {
    return AnalyticsExecutor.execute(
          query: AnalyticsQuerySpec(
            source: 'events',
            measures: const [CountMeasure()],
            groupBys: [
              TimeGroupBy(
                dateFieldRef: ref('events', 'occurredAt'),
                grain: TimeGrain.day,
              ),
            ],
            derivedOperation: operation,
          ),
          records: records,
          sources: [events],
          dateRange: (DateTime(2026, 5, 1), DateTime(2026, 5, 4)),
        ).okOrNull
        as SeriesResult;
  }

  /// Sanity check on the fixture itself, so the per-op assertions
  /// below have a clear reference point.
  test('fixture has expected synthetic-bucket pattern', () {
    final s = runWithOperation(
      records: recordsOnFirstAndThird(),
      operation: const NoDerivedOp(),
    );
    expect(s.buckets.length, 3);
    expect(s.buckets.map((b) => b.isSynthetic).toList(), [false, true, false]);
  });

  /// All three non-trivial derived ops share the same contract for
  /// `isSynthetic`: the output bucket at position `i` carries the same
  /// flag as the input bucket at position `i`. A single parametrized
  /// test pins this for every op rather than three near-identical
  /// copies.
  group('isSynthetic is preserved per bucket position', () {
    final ops = <String, DerivedOperation>{
      'CumulativeSumOp': const CumulativeSumOp(),
      'DeltaOp': const DeltaOp(),
      'MovingAverageOp(window: 2)': const MovingAverageOp(window: 2),
    };
    for (final entry in ops.entries) {
      test(entry.key, () {
        final result = runWithOperation(
          records: recordsOnFirstAndThird(),
          operation: entry.value,
        );
        expect(result.buckets.map((b) => b.isSynthetic).toList(), [
          false,
          true,
          false,
        ]);
      });
    }
  });

  /// The measure-type rule for derived ops, exercised through the query
  /// path (the executor calls `DerivedEngine.apply` on the aggregated
  /// series). The fixture's `CountMeasure` is integer-typed, so this
  /// pins how each op maps that input type.
  group('measure type follows the operation output-type rule', () {
    test('cumulative sum preserves the integer measure type', () {
      final s = runWithOperation(
        records: recordsOnFirstAndThird(),
        operation: const CumulativeSumOp(),
      );
      expect(s.measureFieldType, FieldType.integer);
    });

    test('delta preserves the integer measure type', () {
      final s = runWithOperation(
        records: recordsOnFirstAndThird(),
        operation: const DeltaOp(),
      );
      expect(s.measureFieldType, FieldType.integer);
    });

    test('moving average over an integer measure reports double', () {
      final s = runWithOperation(
        records: recordsOnFirstAndThird(),
        operation: const MovingAverageOp(window: 2),
      );
      expect(s.measureFieldType, FieldType.double);
      expect(
        s.buckets.every((b) => b.value == null || b.value is DoubleValue),
        isTrue,
      );
    });
  });
}
