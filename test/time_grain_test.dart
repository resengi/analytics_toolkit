import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:test/test.dart';

/// `TimeGrain` constructor invariants and the effective-anchor rule.
///
/// `count` must be positive. `weekStartDay` is only meaningful when
/// `unit == TimeUnit.week`; passing it on any other unit throws
/// `ArgumentError`. `weekStartDay` must be in `[1, 7]` (Dart's
/// `1 = Monday .. 7 = Sunday` convention).
///
/// The week-aligned `startOfBucket` honors `weekStartDay`: bucket
/// boundaries fall on the chosen weekday regardless of where
/// `anchor` lands.
void main() {
  // ────────────────────────────────────────────────────────────────────
  // Constructor invariants
  // ────────────────────────────────────────────────────────────────────

  group('TimeGrain constructor — count invariant', () {
    test('count == 0 throws ArgumentError', () {
      expect(
        () => TimeGrain(
          count: 0,
          unit: TimeUnit.day,
          anchor: DateTime.utc(2000, 1, 1),
        ),
        throwsArgumentError,
      );
    });

    test('negative count throws ArgumentError', () {
      expect(
        () => TimeGrain(
          count: -1,
          unit: TimeUnit.day,
          anchor: DateTime.utc(2000, 1, 1),
        ),
        throwsArgumentError,
      );
    });

    test('count == 1 is accepted', () {
      expect(
        TimeGrain(
          count: 1,
          unit: TimeUnit.day,
          anchor: DateTime.utc(2000, 1, 1),
        ).count,
        1,
      );
    });

    test('count > 1 is accepted', () {
      expect(
        TimeGrain(
          count: 7,
          unit: TimeUnit.day,
          anchor: DateTime.utc(2000, 1, 1),
        ).count,
        7,
      );
    });
  });

  group('TimeGrain constructor — weekStartDay invariant', () {
    test('weekStartDay on non-week unit throws ArgumentError', () {
      expect(
        () => TimeGrain(
          count: 1,
          unit: TimeUnit.day,
          anchor: DateTime.utc(2000, 1, 1),
          weekStartDay: DateTime.monday,
        ),
        throwsArgumentError,
      );
    });

    test('weekStartDay on TimeUnit.month throws', () {
      expect(
        () => TimeGrain(
          count: 1,
          unit: TimeUnit.month,
          anchor: DateTime.utc(2000, 1, 1),
          weekStartDay: DateTime.monday,
        ),
        throwsArgumentError,
      );
    });

    test('weekStartDay out of [1, 7] throws ArgumentError', () {
      // Below the range.
      expect(
        () => TimeGrain(
          count: 1,
          unit: TimeUnit.week,
          anchor: DateTime.utc(2000, 1, 2),
          weekStartDay: 0,
        ),
        throwsArgumentError,
      );
      // Above the range.
      expect(
        () => TimeGrain(
          count: 1,
          unit: TimeUnit.week,
          anchor: DateTime.utc(2000, 1, 2),
          weekStartDay: 8,
        ),
        throwsArgumentError,
      );
    });

    test('weekStartDay at the boundaries is accepted', () {
      // Monday and Sunday — the inclusive endpoints.
      expect(
        TimeGrain(
          count: 1,
          unit: TimeUnit.week,
          anchor: DateTime.utc(2000, 1, 2),
          weekStartDay: DateTime.monday,
        ).weekStartDay,
        DateTime.monday,
      );
      expect(
        TimeGrain(
          count: 1,
          unit: TimeUnit.week,
          anchor: DateTime.utc(2000, 1, 2),
          weekStartDay: DateTime.sunday,
        ).weekStartDay,
        DateTime.sunday,
      );
    });

    test('null weekStartDay is always accepted (any unit)', () {
      // No weekStartDay means "use anchor's weekday as-is."
      for (final unit in TimeUnit.values) {
        expect(
          TimeGrain(
            count: 1,
            unit: unit,
            anchor: DateTime.utc(2000, 1, 1),
          ).weekStartDay,
          isNull,
        );
      }
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // Predefined constants
  // ────────────────────────────────────────────────────────────────────

  group('predefined TimeGrain constants', () {
    test('TimeGrain.day has count=1, unit=day, weekStartDay=null', () {
      expect(TimeGrain.day.count, 1);
      expect(TimeGrain.day.unit, TimeUnit.day);
      expect(TimeGrain.day.weekStartDay, isNull);
    });

    test('TimeGrain.week has count=1, unit=week, weekStartDay=null', () {
      expect(TimeGrain.week.count, 1);
      expect(TimeGrain.week.unit, TimeUnit.week);
      expect(TimeGrain.week.weekStartDay, isNull);
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // Equality
  // ────────────────────────────────────────────────────────────────────

  group('TimeGrain equality includes weekStartDay', () {
    test('week grains with different weekStartDay are unequal', () {
      final monday = TimeGrain(
        count: 1,
        unit: TimeUnit.week,
        anchor: DateTime.utc(2000, 1, 2),
        weekStartDay: DateTime.monday,
      );
      final sunday = TimeGrain(
        count: 1,
        unit: TimeUnit.week,
        anchor: DateTime.utc(2000, 1, 2),
        weekStartDay: DateTime.sunday,
      );
      expect(monday == sunday, isFalse);
    });

    test('week grains with matching weekStartDay compare equal', () {
      final a = TimeGrain(
        count: 1,
        unit: TimeUnit.week,
        anchor: DateTime.utc(2000, 1, 2),
        weekStartDay: DateTime.monday,
      );
      final b = TimeGrain(
        count: 1,
        unit: TimeUnit.week,
        anchor: DateTime.utc(2000, 1, 2),
        weekStartDay: DateTime.monday,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });
}
