import 'time_grain.dart';

/// Time-bucket arithmetic for [TimeGrain].
///
/// Exposes the two operations that consumers and the executor need
/// for time-bucketing:
///
/// * [startOfBucket] — truncate an instant to the start of its
///   containing bucket.
/// * [nextBucketStart] — advance one bucket forward from a bucket
///   start.
///
/// Together these are enough to walk a date range bucket-by-bucket
/// (densify time series), assign records to buckets (group), and
/// align two queries to the same time grain (paired queries).
///
/// All math uses Dart's [DateTime] arithmetic. DST behavior follows
/// [DateTime] — if precise DST handling matters, consumers should
/// normalize records and anchors to UTC.
extension TimeGrainArithmetic on TimeGrain {
  /// Returns the start of the bucket containing [instant].
  ///
  /// "Bucket start" means the largest `DateTime b` such that
  /// `b <= instant` and `b` is reachable from the grain's effective
  /// anchor via `b = effectiveAnchor + k * (count * unit)` for some
  /// integer `k`. The effective anchor is the grain's [TimeGrain.anchor]
  /// shifted forward to the next [TimeGrain.weekStartDay] when one is
  /// supplied; see the [TimeGrain] class doc.
  DateTime startOfBucket(DateTime instant) {
    final effective = _effectiveAnchor();
    final unitsSinceAnchor = _unitsBetween(effective, instant);
    final truncated = _floorDiv(unitsSinceAnchor, count) * count;
    return _advance(effective, truncated);
  }

  /// Returns the start of the bucket immediately after
  /// [currentBucketStart].
  ///
  /// Equivalent to advancing by `count * unit`. [currentBucketStart]
  /// should be a value previously returned by [startOfBucket]; for
  /// arbitrary inputs the result is still well-defined but may not
  /// align with the grain's anchor.
  DateTime nextBucketStart(DateTime currentBucketStart) {
    return _advance(currentBucketStart, count);
  }

  // ── Effective anchor ───────────────────────────────────────────────────

  /// Returns the anchor used for bucket alignment.
  ///
  /// When [TimeGrain.weekStartDay] is non-null and differs from
  /// [TimeGrain.anchor]'s weekday, the anchor is shifted forward by
  /// 1..6 days to land on the requested weekday; the time-of-day is
  /// preserved.
  DateTime _effectiveAnchor() {
    final wsd = weekStartDay;
    if (wsd == null) return anchor;
    if (anchor.weekday == wsd) return anchor;
    final daysForward = (wsd - anchor.weekday) % 7;
    return DateTime(
      anchor.year,
      anchor.month,
      anchor.day + daysForward,
      anchor.hour,
      anchor.minute,
      anchor.second,
      anchor.millisecond,
      anchor.microsecond,
    );
  }

  // ── Unit arithmetic ────────────────────────────────────────────────────

  /// Returns the number of completed [unit]-steps from [from] to [to].
  /// Sign matches the direction: negative when `to < from`.
  ///
  /// Semantics: "completed" means the largest integer `n` such that
  /// `from + n * unit ≤ to`. This is floor-division on the elapsed
  /// duration — partial units don't count.
  int _unitsBetween(DateTime from, DateTime to) {
    switch (unit) {
      case TimeUnit.microsecond:
        return to.microsecondsSinceEpoch - from.microsecondsSinceEpoch;
      case TimeUnit.millisecond:
        return _floorDiv(
          to.microsecondsSinceEpoch - from.microsecondsSinceEpoch,
          1000,
        );
      case TimeUnit.second:
        return _floorDiv(
          to.microsecondsSinceEpoch - from.microsecondsSinceEpoch,
          1000000,
        );
      case TimeUnit.minute:
        return _floorDiv(
          to.microsecondsSinceEpoch - from.microsecondsSinceEpoch,
          60 * 1000000,
        );
      case TimeUnit.hour:
        return _floorDiv(
          to.microsecondsSinceEpoch - from.microsecondsSinceEpoch,
          3600 * 1000000,
        );
      case TimeUnit.day:
        return _completedDays(from, to);
      case TimeUnit.week:
        return _floorDiv(_completedDays(from, to), 7);
      case TimeUnit.month:
        return _completedMonths(from, to);
      case TimeUnit.year:
        return _completedYears(from, to);
    }
  }

  /// Advances [from] by [n] [unit]-steps. Signed.
  DateTime _advance(DateTime from, int n) {
    switch (unit) {
      case TimeUnit.microsecond:
        return from.add(Duration(microseconds: n));
      case TimeUnit.millisecond:
        return from.add(Duration(milliseconds: n));
      case TimeUnit.second:
        return from.add(Duration(seconds: n));
      case TimeUnit.minute:
        return from.add(Duration(minutes: n));
      case TimeUnit.hour:
        return from.add(Duration(hours: n));
      case TimeUnit.day:
        return DateTime(
          from.year,
          from.month,
          from.day + n,
          from.hour,
          from.minute,
          from.second,
          from.millisecond,
          from.microsecond,
        );
      case TimeUnit.week:
        return DateTime(
          from.year,
          from.month,
          from.day + 7 * n,
          from.hour,
          from.minute,
          from.second,
          from.millisecond,
          from.microsecond,
        );
      case TimeUnit.month:
        return DateTime(
          from.year,
          from.month + n,
          from.day,
          from.hour,
          from.minute,
          from.second,
          from.millisecond,
          from.microsecond,
        );
      case TimeUnit.year:
        return DateTime(
          from.year + n,
          from.month,
          from.day,
          from.hour,
          from.minute,
          from.second,
          from.millisecond,
          from.microsecond,
        );
    }
  }
}

// ── Calendar-aware completion helpers ─────────────────────────────────────

int _completedDays(DateTime from, DateTime to) {
  // Calendar days between dates, then adjust for time-of-day.
  //
  // We pin the day boundaries through UTC before differencing. Local
  // `DateTime.difference().inDays` is Duration-based and loses (or
  // gains) an hour across a DST transition, which floor-divides into
  // an off-by-one calendar-day count for spans that cross one. UTC
  // is DST-free, so its day count matches the calendar exactly.
  final fromDate = DateTime.utc(from.year, from.month, from.day);
  final toDate = DateTime.utc(to.year, to.month, to.day);
  var days = toDate.difference(fromDate).inDays;
  // If `to`'s time-of-day is before `from`'s, one less day completed.
  if (_timeOfDayMicros(to) < _timeOfDayMicros(from)) {
    days -= 1;
  }
  return days;
}

int _completedMonths(DateTime from, DateTime to) {
  var months = (to.year - from.year) * 12 + (to.month - from.month);
  if (to.day < from.day ||
      (to.day == from.day && _timeOfDayMicros(to) < _timeOfDayMicros(from))) {
    months -= 1;
  }
  return months;
}

int _completedYears(DateTime from, DateTime to) {
  final years = to.year - from.year;
  // A full calendar year has elapsed iff `to`'s (month, day,
  // time-of-day) is at or after `from`'s within its calendar year.
  // Walk the components in order and short-circuit on the first
  // differing one.
  final monthDiff = to.month - from.month;
  if (monthDiff < 0) return years - 1;
  if (monthDiff > 0) return years;
  final dayDiff = to.day - from.day;
  if (dayDiff < 0) return years - 1;
  if (dayDiff > 0) return years;
  if (_timeOfDayMicros(to) < _timeOfDayMicros(from)) return years - 1;
  return years;
}

int _timeOfDayMicros(DateTime dt) {
  return (dt.hour * 3600 + dt.minute * 60 + dt.second) * 1000000 +
      dt.millisecond * 1000 +
      dt.microsecond;
}

/// Floor division: rounds toward negative infinity.
///
/// Required because Dart's `~/` truncates toward zero, which is
/// wrong for bucket alignment when the dividend is negative.
int _floorDiv(int a, int b) {
  assert(b > 0, '_floorDiv requires a positive divisor');
  final q = a ~/ b;
  // Dart's `%` is always non-negative for positive divisor, so
  // `a % b == 0` correctly identifies "exactly divisible."
  if (a % b == 0 || a >= 0) return q;
  return q - 1;
}
