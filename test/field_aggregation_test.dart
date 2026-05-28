import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:test/test.dart';

import '_fixtures.dart';

/// Pins the sealed dispatch on [FieldAggregation]. Both the validator
/// and the executor consult `compatibleWith` and `outputFieldType` as
/// the single source of truth for the
/// `(aggregation × field type) → (compatible?, output type)` table.
///
/// Each test pins one row of the dispatch table; multiple `expect`s
/// inside a test exhaust the field-type axis for that aggregation. A
/// failure points to the specific aggregation and includes the
/// failing field-type in the assertion line, which is enough locating
/// information given the table's small size.
///
/// `PercentileAgg.p` parameter validation lives here too because the
/// parameter belongs to the dispatch family.
void main() {
  // ────────────────────────────────────────────────────────────────────
  // compatibleWith — per-aggregation contract row
  // ────────────────────────────────────────────────────────────────────

  group('compatibleWith — per-aggregation field-type acceptance', () {
    test(
      'SumAgg, AverageAgg, PercentileAgg accept only numeric field types',
      () {
        // The three numeric aggregations share one acceptance row.
        const numericAggs = <FieldAggregation>[
          SumAgg(),
          AverageAgg(),
          PercentileAgg(p: 0.5),
        ];
        for (final agg in numericAggs) {
          // Accepted: integer, double, duration.
          expect(agg.compatibleWith(FieldType.integer), isTrue, reason: '$agg');
          expect(agg.compatibleWith(FieldType.double), isTrue, reason: '$agg');
          expect(
            agg.compatibleWith(FieldType.duration),
            isTrue,
            reason: '$agg',
          );
          // Rejected: string, enumeration, boolean, dateTime.
          expect(agg.compatibleWith(FieldType.string), isFalse, reason: '$agg');
          expect(
            agg.compatibleWith(FieldType.enumeration),
            isFalse,
            reason: '$agg',
          );
          expect(
            agg.compatibleWith(FieldType.boolean),
            isFalse,
            reason: '$agg',
          );
          expect(
            agg.compatibleWith(FieldType.dateTime),
            isFalse,
            reason: '$agg',
          );
        }
      },
    );

    test(
      'MinAgg and MaxAgg accept ordered field types (numeric + dateTime)',
      () {
        const orderedAggs = <FieldAggregation>[MinAgg(), MaxAgg()];
        for (final agg in orderedAggs) {
          expect(agg.compatibleWith(FieldType.integer), isTrue, reason: '$agg');
          expect(agg.compatibleWith(FieldType.double), isTrue, reason: '$agg');
          expect(
            agg.compatibleWith(FieldType.duration),
            isTrue,
            reason: '$agg',
          );
          expect(
            agg.compatibleWith(FieldType.dateTime),
            isTrue,
            reason: '$agg',
          );
          // Categorical/boolean lack a meaningful ordering for extrema.
          expect(agg.compatibleWith(FieldType.string), isFalse, reason: '$agg');
          expect(
            agg.compatibleWith(FieldType.enumeration),
            isFalse,
            reason: '$agg',
          );
          expect(
            agg.compatibleWith(FieldType.boolean),
            isFalse,
            reason: '$agg',
          );
        }
      },
    );

    test('DistinctCountAgg accepts every field type', () {
      // The count is type-agnostic; the field type's structure doesn't
      // matter to counting distinct non-null raw values.
      const agg = DistinctCountAgg();
      for (final t in FieldType.values) {
        expect(agg.compatibleWith(t), isTrue, reason: 'failed for ${t.name}');
      }
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // outputFieldType — per-aggregation contract row
  // ────────────────────────────────────────────────────────────────────

  group('outputFieldType — preserve, widen, or fix', () {
    test('SumAgg, MinAgg, MaxAgg preserve input type', () {
      const preserving = <FieldAggregation>[SumAgg(), MinAgg(), MaxAgg()];
      for (final agg in preserving) {
        expect(agg.outputFieldType(FieldType.integer), FieldType.integer);
        expect(agg.outputFieldType(FieldType.double), FieldType.double);
        expect(agg.outputFieldType(FieldType.duration), FieldType.duration);
      }
      // Min/Max additionally accept dateTime.
      expect(
        const MinAgg().outputFieldType(FieldType.dateTime),
        FieldType.dateTime,
      );
      expect(
        const MaxAgg().outputFieldType(FieldType.dateTime),
        FieldType.dateTime,
      );
    });

    test('AverageAgg and PercentileAgg widen integer to double', () {
      const widening = <FieldAggregation>[AverageAgg(), PercentileAgg(p: 0.5)];
      for (final agg in widening) {
        // Mean/percentile of integers is generally fractional.
        expect(agg.outputFieldType(FieldType.integer), FieldType.double);
        // double and duration preserve.
        expect(agg.outputFieldType(FieldType.double), FieldType.double);
        expect(agg.outputFieldType(FieldType.duration), FieldType.duration);
      }
    });

    test('DistinctCountAgg always returns integer regardless of input', () {
      const agg = DistinctCountAgg();
      for (final t in FieldType.values) {
        expect(
          agg.outputFieldType(t),
          FieldType.integer,
          reason: 'failed for ${t.name}',
        );
      }
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // outputFieldType throws on incompatible pair
  // ────────────────────────────────────────────────────────────────────

  group('outputFieldType — incompatible pair throws StateError', () {
    test('every incompatible (agg, type) pair throws', () {
      // The validator should reject these upstream; the throw is a
      // last-line defense against a silent wrong-answer bug. We sample
      // one mismatch per aggregation family.
      expect(
        () => const SumAgg().outputFieldType(FieldType.string),
        throwsStateError,
      );
      expect(
        () => const AverageAgg().outputFieldType(FieldType.dateTime),
        throwsStateError,
      );
      expect(
        () => const MinAgg().outputFieldType(FieldType.boolean),
        throwsStateError,
      );
      expect(
        () =>
            const PercentileAgg(p: 0.5).outputFieldType(FieldType.enumeration),
        throwsStateError,
      );
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // PercentileAgg.p validator boundary handling
  // ────────────────────────────────────────────────────────────────────

  group('PercentileAgg.p — validator boundary handling', () {
    // The constructor doesn't range-check p; the validator does, with
    // kind `invalidAggregationParameter`. Boundary values 0 and 1 are
    // accepted; anything outside [0, 1], and NaN, is rejected.

    final tasks = tasksSource();

    Result<Unit, AnalyticsError> validate(double p) {
      return QueryValidator.validateQuery(
        AnalyticsQuerySpec(
          source: 'tasks',
          measures: [
            FieldMeasure(
              fieldRef: ref('tasks', 'priority'),
              aggregation: PercentileAgg(p: p),
            ),
          ],
        ),
        sources: [tasks],
      );
    }

    test('boundary values 0.0, 0.5, and 1.0 are accepted', () {
      for (final p in const [0.0, 0.5, 1.0]) {
        expect(validate(p).isOk, isTrue, reason: 'p=$p should be accepted');
      }
    });

    test(
      'values just outside [0, 1] are rejected with invalidAggregationParameter',
      () {
        for (final p in const [-0.001, 1.001, -1.0, 2.0]) {
          final r = validate(p);
          expect(r.isErr, isTrue, reason: 'p=$p should be rejected');
          expect(
            r.errOrNull!.kind,
            AnalyticsErrorKind.invalidAggregationParameter,
            reason: 'p=$p should fire invalidAggregationParameter',
          );
        }
      },
    );

    test('NaN is rejected with invalidAggregationParameter', () {
      final r = validate(double.nan);
      expect(r.isErr, isTrue);
      expect(r.errOrNull!.kind, AnalyticsErrorKind.invalidAggregationParameter);
    });
  });
}
