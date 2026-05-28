/// Computes streak statistics from scheduled and completed date sets.
///
/// A "streak" is consecutive scheduled dates that have a matching
/// entry in [completedDates]. Only completion maintains the streak —
/// past scheduled dates without completion break it.
///
/// ## Input contract
///
/// Every `DateTime` passed in — `scheduledDates`, `completedDates`,
/// and `asOf` — must be day-truncated to local midnight (`hour = 0,
/// minute = 0, second = 0, millisecond = 0, microsecond = 0`).
/// `completedDates.contains(date)` is the membership check, and that
/// only returns `true` when the day-truncated key matches exactly.
/// `StreakExecutor` ensures this for callers that go through it.
///
/// Pure Dart — no Flutter dependency.
abstract class StreakCalculator {
  /// Computes the current streak and longest streak for a scheduled
  /// series.
  ///
  /// [scheduledDates] is the complete set of dates an event was
  /// expected (e.g., every Monday and Wednesday for a Mon/Wed habit).
  /// Non-scheduled days (e.g., Tuesday for a Mon/Wed habit) are NOT
  /// considered breaks.
  ///
  /// [completedDates] is the subset of [scheduledDates] that were
  /// actually completed.
  ///
  /// [asOf] is the reference date for determining "current" (typically
  /// today). If today is a scheduled day that hasn't been completed
  /// yet, the streak continues until end of day — it's not broken
  /// until the day passes without completion.
  ///
  /// Returns `(currentStreak, longestStreak)`.
  static (int current, int longest) computeStreak(
    Set<DateTime> scheduledDates,
    Set<DateTime> completedDates,
    DateTime asOf,
  ) {
    if (scheduledDates.isEmpty) return (0, 0);

    // `asOf` is assumed already day-truncated per the input contract.
    final today = asOf;

    final sorted = scheduledDates.toList()..sort((a, b) => a.compareTo(b));

    int longestStreak = 0;
    int currentRun = 0;

    for (final date in sorted) {
      // Skip future dates — they haven't happened yet.
      if (date.isAfter(today)) break;

      if (completedDates.contains(date)) {
        currentRun++;
        if (currentRun > longestStreak) longestStreak = currentRun;
      } else if (date.isAtSameMomentAs(today)) {
        // Today is scheduled but not yet completed — don't break the
        // streak yet, but don't increment either.
      } else {
        // Past scheduled date without completion — streak broken.
        currentRun = 0;
      }
    }

    return (currentRun, longestStreak);
  }
}
