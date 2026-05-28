import 'grain_arithmetic.dart';
import 'time_grain.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────────────

/// Closed set of date range presets.
///
/// Persistence: serialized by `.name`. Renaming a value is a breaking
/// change.
enum DateRangePreset {
  last7Days,
  last14Days,
  last30Days,
  last90Days,
  // Calendar-aligned presets. Resolution depends on the current
  // calendar position rather than a rolling N-day window.
  thisWeek,
  thisMonth,
  lastMonth,
  quarterToDate,
  allTime,
}

/// A date range value that is either a preset or an explicit
/// start/end pair.
///
/// Sealed shape with two cases:
/// - [PresetRange]  — a `DateRangePreset` to be resolved by `DatePresetResolver`
/// - [CustomRange]  — explicit start and end dates
sealed class WidgetDateRange {
  const WidgetDateRange();
}

class PresetRange extends WidgetDateRange {
  const PresetRange({required this.preset});
  final DateRangePreset preset;

  @override
  bool operator ==(Object other) =>
      other is PresetRange && other.preset == preset;

  @override
  int get hashCode => preset.hashCode;
}

/// An explicit date range with concrete start and end dates.
///
/// The constructor accepts a user-facing **inclusive** [end] (the last
/// day records should fall on) and converts to the package's internal
/// half-open form. After construction:
///
/// * [start] is the start-of-day instant for the user's start.
/// * [endExclusive] is the start-of-day instant for the day **after**
///   the user's end — records on the user's end day are included;
///   records at the start of the next day are excluded.
///
/// Throws [ArgumentError] when `start.isAfter(end)`. `start == end`
/// produces a one-day window after the inclusive-to-exclusive
/// conversion.
class CustomRange extends WidgetDateRange {
  CustomRange({required DateTime start, required DateTime end})
    : start = DateTime(start.year, start.month, start.day),
      endExclusive = DateTime(end.year, end.month, end.day + 1) {
    if (start.isAfter(end)) {
      throw ArgumentError.value(
        start,
        'start',
        'CustomRange: start must be on or before end '
            '(got start=$start, end=$end).',
      );
    }
  }

  /// Day-aligned start of the range, inclusive.
  final DateTime start;

  /// Day-aligned end of the range, exclusive. This is the start of the
  /// day **after** the user-facing end date.
  final DateTime endExclusive;

  @override
  bool operator ==(Object other) =>
      other is CustomRange &&
      other.start == start &&
      other.endExclusive == endExclusive;

  @override
  int get hashCode => Object.hash(start, endExclusive);
}

/// How a widget interprets a date range. Sealed shape with three cases:
///
/// - [UsePageRange]   — widget follows the page-level date range
/// - [FixedOverride]  — widget carries its own range, ignoring the page
/// - [NoDateRange]    — measure does not support a date range at all
///
/// Cross-rule (enforced by the validator):
/// - if `measure.supportsDateRange == false`, mode must be `NoDateRange`
/// - if `measure.supportsDateRange == true`, mode must not be `NoDateRange`
sealed class DateRangeMode {
  const DateRangeMode();
}

class UsePageRange extends DateRangeMode {
  const UsePageRange();

  @override
  bool operator ==(Object other) => other is UsePageRange;

  @override
  int get hashCode => runtimeType.hashCode;
}

class FixedOverride extends DateRangeMode {
  const FixedOverride({required this.range});
  final WidgetDateRange range;

  @override
  bool operator ==(Object other) =>
      other is FixedOverride && other.range == range;

  @override
  int get hashCode => range.hashCode;
}

class NoDateRange extends DateRangeMode {
  const NoDateRange();

  @override
  bool operator ==(Object other) => other is NoDateRange;

  @override
  int get hashCode => runtimeType.hashCode;
}

// ─────────────────────────────────────────────────────────────────────────────
// Resolver
// ─────────────────────────────────────────────────────────────────────────────

/// The centralized date-preset resolver.
///
/// Resolves a `WidgetDateRange` to a concrete
/// `(DateTime startInclusive, DateTime endExclusive)` tuple. Both
/// page-level and widget `FixedOverride` ranges go through the same
/// path.
///
/// All returned ranges follow the package's half-open convention:
/// the start is inclusive, the end is the start of the day **after**
/// the user-facing last day. For example, with `today = 2026-05-11`,
/// `thisMonth` returns `(2026-05-01, 2026-05-12)` — records on May 11
/// are included; records at midnight May 12 are not.
///
/// Pure function: `today` is injected for testability and
/// `earliestDataDate` is supplied by the caller.
///
/// ## Week and quarter alignment
///
/// `thisWeek` and `quarterToDate` are configurable via [weekStartDay]
/// and [quarterStartMonth]. Defaults are Sunday-start weeks (matching
/// US convention) and January-start quarters (Q1=Jan-Mar etc). Pass
/// [DateTime.monday] for ISO 8601 week-start; pass `4` for
/// April-start fiscal quarters (Q1=Apr-Jun).
abstract class DatePresetResolver {
  /// Resolves a `WidgetDateRange` to a half-open
  /// `(startInclusive, endExclusive)` tuple of day-aligned instants.
  static (DateTime startInclusive, DateTime endExclusive) resolve(
    WidgetDateRange range, {
    required DateTime today,
    DateTime? earliestDataDate,
    int weekStartDay = DateTime.sunday,
    int quarterStartMonth = 1,
  }) {
    final normalizedToday = TimeGrain.day.startOfBucket(today);

    switch (range) {
      case PresetRange(preset: final preset):
        return _resolvePreset(
          preset,
          normalizedToday: normalizedToday,
          earliestDataDate: earliestDataDate,
          weekStartDay: weekStartDay,
          quarterStartMonth: quarterStartMonth,
        );
      case CustomRange(start: final s, endExclusive: final e):
        // Already half-open and day-aligned by the constructor.
        return (s, e);
    }
  }

  /// Convenience overload that resolves a [DateRangeMode] directly.
  ///
  /// - `UsePageRange` cannot be resolved here because it depends on
  ///   the page-level range; the caller must resolve the page range
  ///   first and pass it as [pageRange]. The supplied [pageRange] is
  ///   assumed to already be in half-open form (as returned by
  ///   [resolve]).
  /// - `FixedOverride` resolves its inner [WidgetDateRange].
  /// - `NoDateRange` returns null — there is no date range to apply.
  ///
  /// Throws `StateError` for `UsePageRange` when [pageRange] is null.
  static (DateTime startInclusive, DateTime endExclusive)? resolveMode(
    DateRangeMode mode, {
    required DateTime today,
    DateTime? earliestDataDate,
    (DateTime, DateTime)? pageRange,
    int weekStartDay = DateTime.sunday,
    int quarterStartMonth = 1,
  }) {
    switch (mode) {
      case UsePageRange():
        if (pageRange == null) {
          throw StateError(
            'DatePresetResolver.resolveMode: UsePageRange requires '
            'pageRange to be supplied by the caller.',
          );
        }
        return pageRange;
      case FixedOverride(range: final range):
        return resolve(
          range,
          today: today,
          earliestDataDate: earliestDataDate,
          weekStartDay: weekStartDay,
          quarterStartMonth: quarterStartMonth,
        );
      case NoDateRange():
        return null;
    }
  }

  // ── Internals ─────────────────────────────────────────────────────────

  /// The exclusive end-of-day for [day]: midnight of the next calendar
  /// day, computed by calendar arithmetic (DST-safe under local time).
  static DateTime _nextDay(DateTime day) =>
      DateTime(day.year, day.month, day.day + 1);

  static (DateTime, DateTime) _resolvePreset(
    DateRangePreset preset, {
    required DateTime normalizedToday,
    required int weekStartDay,
    required int quarterStartMonth,
    DateTime? earliestDataDate,
  }) {
    final endExclusive = _nextDay(normalizedToday);

    // Start-of-day n days before `normalizedToday`. The presets below
    // use `daysAgo(n - 1)` because the window is inclusive of today
    // (so `last7Days` spans today and the six preceding days).
    DateTime daysAgo(int n) => DateTime(
      normalizedToday.year,
      normalizedToday.month,
      normalizedToday.day - n,
    );

    switch (preset) {
      case DateRangePreset.last7Days:
        return (daysAgo(6), endExclusive);
      case DateRangePreset.last14Days:
        return (daysAgo(13), endExclusive);
      case DateRangePreset.last30Days:
        return (daysAgo(29), endExclusive);
      case DateRangePreset.last90Days:
        return (daysAgo(89), endExclusive);
      case DateRangePreset.thisWeek:
        // Start of the week containing today, per weekStartDay.
        // Dart's weekday is 1=Mon..7=Sun.
        final daysBack = (normalizedToday.weekday - weekStartDay) % 7;
        return (daysAgo(daysBack), endExclusive);
      case DateRangePreset.thisMonth:
        return (
          DateTime(normalizedToday.year, normalizedToday.month, 1),
          endExclusive,
        );
      case DateRangePreset.lastMonth:
        // First of last month → first of this month (exclusive).
        return (
          DateTime(normalizedToday.year, normalizedToday.month - 1, 1),
          DateTime(normalizedToday.year, normalizedToday.month, 1),
        );
      case DateRangePreset.quarterToDate:
        // Quarter boundaries are computed relative to quarterStartMonth.
        // For quarterStartMonth=1 (default): Q1=Jan, Q2=Apr, Q3=Jul,
        // Q4=Oct. For quarterStartMonth=4 (Apr-start fiscal): Q1=Apr,
        // Q2=Jul, Q3=Oct, Q4=Jan-of-next-year.
        final monthsSinceQuarterStart =
            (normalizedToday.month - quarterStartMonth) % 12;
        final firstMonthOfQuarter =
            normalizedToday.month - (monthsSinceQuarterStart % 3);
        return (
          DateTime(normalizedToday.year, firstMonthOfQuarter, 1),
          endExclusive,
        );
      case DateRangePreset.allTime:
        if (earliestDataDate != null) {
          return (TimeGrain.day.startOfBucket(earliestDataDate), endExclusive);
        }
        // Safe fallback when the caller has no earliest-data signal.
        return (
          DateTime(
            normalizedToday.year,
            normalizedToday.month,
            normalizedToday.day - 365,
          ),
          endExclusive,
        );
    }
  }
}
