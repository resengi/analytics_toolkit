import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:test/test.dart';

/// `TimeGrainArithmetic` extension methods — the public-API surface
/// for bucket alignment.
///
/// `startOfBucket(instant)` truncates to the bucket-start aligned to
/// the grain's effective anchor; `nextBucketStart(bucketStart)`
/// advances by one bucket. Together these drive densification,
/// grouping, and date-range walking.
///
/// Calendar-unit grains (day, week, month, year) use calendar
/// arithmetic — month boundaries, year boundaries, leap years, and
/// `weekStartDay` alignment are non-trivial and tested explicitly.
/// Sub-day units use straightforward microsecond arithmetic.
void main() {
  // ────────────────────────────────────────────────────────────────────
  // Day grain — calendar boundaries
  // ────────────────────────────────────────────────────────────────────

  group('day grain — startOfBucket and nextBucketStart', () {
    test('truncates the time-of-day to the start of the day', () {
      // Anchored at any midnight; bucketing is calendar-day aligned.
      final g = TimeGrain.day;
      expect(
        g.startOfBucket(DateTime(2026, 5, 15, 14, 30, 45)),
        DateTime(2026, 5, 15, 0, 0, 0),
      );
    });

    test('nextBucketStart advances by exactly one calendar day', () {
      final g = TimeGrain.day;
      expect(g.nextBucketStart(DateTime(2026, 5, 15)), DateTime(2026, 5, 16));
    });

    test('next day crosses month boundary correctly', () {
      final g = TimeGrain.day;
      expect(g.nextBucketStart(DateTime(2026, 1, 31)), DateTime(2026, 2, 1));
    });

    test('next day crosses year boundary correctly', () {
      final g = TimeGrain.day;
      expect(g.nextBucketStart(DateTime(2025, 12, 31)), DateTime(2026, 1, 1));
    });

    test('Feb 28 → Feb 29 in a leap year, Feb 28 → Mar 1 otherwise', () {
      final g = TimeGrain.day;
      // 2024 is a leap year, 2025 is not.
      expect(g.nextBucketStart(DateTime(2024, 2, 28)), DateTime(2024, 2, 29));
      expect(g.nextBucketStart(DateTime(2025, 2, 28)), DateTime(2025, 3, 1));
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // Multi-day grain — count > 1
  // ────────────────────────────────────────────────────────────────────

  group('multi-day grain — count > 1', () {
    test('a 3-day grain truncates to the nearest preceding bucket start', () {
      // Anchor at 2026-01-01 (a Thursday); 3-day buckets start
      // 2026-01-01, 2026-01-04, 2026-01-07, ...
      final g = TimeGrain(
        count: 3,
        unit: TimeUnit.day,
        anchor: DateTime(2026, 1, 1),
      );
      // 2026-01-05 falls in the 2026-01-04 bucket.
      expect(g.startOfBucket(DateTime(2026, 1, 5)), DateTime(2026, 1, 4));
    });

    test('a 3-day grain advances by exactly 3 days', () {
      final g = TimeGrain(
        count: 3,
        unit: TimeUnit.day,
        anchor: DateTime(2026, 1, 1),
      );
      expect(g.nextBucketStart(DateTime(2026, 1, 4)), DateTime(2026, 1, 7));
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // Week grain — weekStartDay alignment
  // ────────────────────────────────────────────────────────────────────

  group('week grain — weekStartDay alignment', () {
    // 2026-05-15 is a Friday.

    test('week grain with no weekStartDay uses anchor\'s weekday', () {
      // Anchor 2026-01-01 is a Thursday; the effective anchor stays
      // there, so weeks align to Thursdays.
      final g = TimeGrain(
        count: 1,
        unit: TimeUnit.week,
        anchor: DateTime(2026, 1, 1),
      );
      final start = g.startOfBucket(DateTime(2026, 5, 15));
      // The Thursday on or before May 15 is May 14.
      expect(start, DateTime(2026, 5, 14));
    });

    test('weekStartDay = Sunday aligns buckets to Sundays', () {
      // Anchor 2026-01-01 is a Thursday; weekStartDay=Sunday shifts
      // the effective anchor forward to 2026-01-04 (Sunday). Weeks
      // align to Sundays from there.
      final g = TimeGrain(
        count: 1,
        unit: TimeUnit.week,
        anchor: DateTime(2026, 1, 1),
        weekStartDay: DateTime.sunday,
      );
      final start = g.startOfBucket(DateTime(2026, 5, 15)); // Fri
      // Most recent Sunday on or before May 15 is May 10.
      expect(start, DateTime(2026, 5, 10));
    });

    test('weekStartDay = Monday aligns buckets to Mondays', () {
      final g = TimeGrain(
        count: 1,
        unit: TimeUnit.week,
        anchor: DateTime(2026, 1, 1),
        weekStartDay: DateTime.monday,
      );
      final start = g.startOfBucket(DateTime(2026, 5, 15)); // Fri
      // Most recent Monday on or before May 15 is May 11.
      expect(start, DateTime(2026, 5, 11));
    });

    test('nextBucketStart advances by exactly 7 days', () {
      final g = TimeGrain(
        count: 1,
        unit: TimeUnit.week,
        anchor: DateTime(2026, 1, 1),
        weekStartDay: DateTime.monday,
      );
      expect(g.nextBucketStart(DateTime(2026, 5, 11)), DateTime(2026, 5, 18));
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // Month grain — calendar arithmetic
  // ────────────────────────────────────────────────────────────────────

  group('month grain — calendar arithmetic', () {
    test('truncates to the first of the month', () {
      // Anchor at 2026-01-01; monthly buckets start on the 1st.
      final g = TimeGrain(
        count: 1,
        unit: TimeUnit.month,
        anchor: DateTime(2026, 1, 1),
      );
      expect(
        g.startOfBucket(DateTime(2026, 5, 15, 14, 30)),
        DateTime(2026, 5, 1),
      );
    });

    test('nextBucketStart crosses year boundary correctly', () {
      final g = TimeGrain(
        count: 1,
        unit: TimeUnit.month,
        anchor: DateTime(2026, 1, 1),
      );
      expect(g.nextBucketStart(DateTime(2026, 12, 1)), DateTime(2027, 1, 1));
    });

    test('3-month grain (quarterly) aligns to the quarter starts', () {
      // Anchor 2026-01-01; quarters at 2026-01-01, 2026-04-01,
      // 2026-07-01, 2026-10-01.
      final g = TimeGrain(
        count: 3,
        unit: TimeUnit.month,
        anchor: DateTime(2026, 1, 1),
      );
      expect(g.startOfBucket(DateTime(2026, 5, 15)), DateTime(2026, 4, 1));
      expect(g.nextBucketStart(DateTime(2026, 4, 1)), DateTime(2026, 7, 1));
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // Year grain
  // ────────────────────────────────────────────────────────────────────

  group('year grain', () {
    test('truncates to the start of the year', () {
      final g = TimeGrain(
        count: 1,
        unit: TimeUnit.year,
        anchor: DateTime(2000, 1, 1),
      );
      expect(g.startOfBucket(DateTime(2026, 5, 15)), DateTime(2026, 1, 1));
    });

    test('nextBucketStart advances by one calendar year', () {
      final g = TimeGrain(
        count: 1,
        unit: TimeUnit.year,
        anchor: DateTime(2000, 1, 1),
      );
      expect(g.nextBucketStart(DateTime(2026, 1, 1)), DateTime(2027, 1, 1));
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // Sub-day grains
  // ────────────────────────────────────────────────────────────────────

  group('sub-day grains', () {
    test('15-minute grain truncates and advances correctly', () {
      // Anchor at the top of an hour; 15-minute buckets at :00, :15, :30, :45.
      final g = TimeGrain(
        count: 15,
        unit: TimeUnit.minute,
        anchor: DateTime(2026, 1, 1),
      );
      expect(
        g.startOfBucket(DateTime(2026, 5, 15, 14, 22)),
        DateTime(2026, 5, 15, 14, 15),
      );
      expect(
        g.nextBucketStart(DateTime(2026, 5, 15, 14, 15)),
        DateTime(2026, 5, 15, 14, 30),
      );
    });

    test('hour grain truncates time-of-day to the hour', () {
      final g = TimeGrain(
        count: 1,
        unit: TimeUnit.hour,
        anchor: DateTime(2026, 1, 1),
      );
      expect(
        g.startOfBucket(DateTime(2026, 5, 15, 14, 22, 7)),
        DateTime(2026, 5, 15, 14),
      );
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // Instants before the anchor — floor-divides toward negative infinity
  // ────────────────────────────────────────────────────────────────────

  group('instants earlier than the anchor', () {
    test('truncates toward negative infinity, not toward zero', () {
      // 3-day grain anchored at 2026-01-01. The bucket containing
      // 2025-12-30 is the one starting at 2025-12-29 (3 days back).
      final g = TimeGrain(
        count: 3,
        unit: TimeUnit.day,
        anchor: DateTime(2026, 1, 1),
      );
      expect(g.startOfBucket(DateTime(2025, 12, 30)), DateTime(2025, 12, 29));
    });
  });
}
