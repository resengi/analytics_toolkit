/// The atomic unit used to compose a [TimeGrain].
///
/// Closed set persisted by [Enum.name]; renaming a value is a
/// breaking change for any persisted spec.
///
/// All units use Dart's [DateTime] arithmetic. DST is handled by
/// [DateTime] itself — if precise DST behavior matters, consumers
/// should normalize their records to UTC before passing them in.
enum TimeUnit {
  microsecond,
  millisecond,
  second,
  minute,
  hour,
  day,
  week,
  month,
  year,
}

/// Time-bucket grain — the size and alignment of one time bucket.
///
/// A [TimeGrain] is "N units of cadence, anchored at a reference
/// moment, optionally aligned to a specific weekday for week-grain."
/// Together with [TimeUnit], this gives consumers a single uniform
/// vocabulary for every periodic time grain from microseconds to
/// multi-year:
///
/// * Every day:                `TimeGrain.day`
/// * Every 15 minutes:         `TimeGrain(count: 15, unit: TimeUnit.minute, anchor: DateTime.utc(2000, 1, 1))`
/// * Every 2 weeks (Sundays):  `TimeGrain(count: 2, unit: TimeUnit.week, anchor: DateTime.utc(2000, 1, 2))`
/// * Calendar quarter:         `TimeGrain(count: 3, unit: TimeUnit.month, anchor: DateTime.utc(2000, 1, 1))`
/// * Fiscal quarter (Apr-start): `TimeGrain(count: 3, unit: TimeUnit.month, anchor: DateTime.utc(2024, 4, 1))`
/// * Decade:                   `TimeGrain(count: 10, unit: TimeUnit.year, anchor: DateTime.utc(2000, 1, 1))`
///
/// The time-bucketing math is exposed by the `TimeGrainArithmetic`
/// extension — `grain.startOfBucket(instant)` and
/// `grain.nextBucketStart(currentBucketStart)`.
///
/// Equality and hashCode are by all four fields ([count], [unit],
/// [anchor], [weekStartDay]) so two grains describing the same
/// bucketing scheme are interchangeable.
///
/// ## Anchor
///
/// [anchor] is the cadence origin: bucket boundaries lie at
/// `anchor + k * (count * unit)` for every integer `k`. Two grains
/// with the same [count] and [unit] but different anchors produce
/// the same bucket size with a different phase alignment.
///
/// The predefined constants use the following anchors:
///
/// | Constant                              | Anchor                              |
/// |---------------------------------------|-------------------------------------|
/// | `microsecond`..`day`, `month`, `year` | `DateTime.utc(2000, 1, 1)`          |
/// | `week`                                | `DateTime.utc(2000, 1, 2)` (Sunday) |
///
/// ## Week-start alignment
///
/// [weekStartDay] is optional and meaningful only when [unit] is
/// [TimeUnit.week]. When non-null, it expresses an alignment intent
/// without forcing the caller to pre-shift the anchor.
///
/// The bucketing math uses an **effective anchor**, derived as
/// follows:
///
/// * If [weekStartDay] is `null`, the effective anchor equals
///   [anchor]. Buckets start on whatever weekday [anchor] falls on.
/// * If [weekStartDay] is non-null and [anchor]'s weekday matches,
///   the effective anchor equals [anchor].
/// * If [weekStartDay] is non-null and [anchor]'s weekday differs,
///   the effective anchor is the first instant on or after [anchor]
///   whose weekday matches, preserving [anchor]'s time-of-day. For
///   example, an anchor of Monday 3:30 PM with
///   `weekStartDay = DateTime.sunday` produces an effective anchor of
///   the following Sunday at 3:30 PM. Subsequent bucket boundaries
///   inherit that time-of-day.
///
/// [weekStartDay] uses Dart's convention: `1 = Monday`, `7 = Sunday`.
class TimeGrain {
  /// Constructs a [TimeGrain].
  ///
  /// Throws [ArgumentError] if [count] is not positive, if
  /// [weekStartDay] is supplied for a non-week [unit], or if
  /// [weekStartDay] is supplied with a value outside `[1, 7]`.
  TimeGrain({
    required this.count,
    required this.unit,
    required this.anchor,
    this.weekStartDay,
  }) {
    if (count <= 0) {
      throw ArgumentError.value(count, 'count', 'Must be positive.');
    }
    final wsd = weekStartDay;
    if (wsd != null) {
      if (unit != TimeUnit.week) {
        throw ArgumentError.value(
          wsd,
          'weekStartDay',
          'Meaningful only for TimeUnit.week; got unit=${unit.name}.',
        );
      }
      if (wsd < DateTime.monday || wsd > DateTime.sunday) {
        throw ArgumentError.value(
          wsd,
          'weekStartDay',
          'Must be in [1, 7] (1=Monday..7=Sunday).',
        );
      }
    }
  }

  /// Private constructor that skips runtime validation. Used only for
  /// the predefined constants below, whose arguments are statically
  /// known to satisfy every invariant. The constants do not use
  /// `weekStartDay`, so it is fixed to `null` here.
  TimeGrain._trusted({
    required this.count,
    required this.unit,
    required this.anchor,
  }) : weekStartDay = null;

  /// How many [unit]s span one bucket.
  final int count;

  /// The atomic time unit.
  final TimeUnit unit;

  /// Cadence origin. Bucket boundaries lie at
  /// `anchor + k * (count * unit)` for every integer `k`.
  final DateTime anchor;

  /// Week-start alignment hint. Non-null only for [TimeUnit.week].
  /// See the class doc for the effective-anchor rule.
  final int? weekStartDay;

  // ── Convenience constants for common grains ──────────────────────────

  static final TimeGrain microsecond = TimeGrain._trusted(
    count: 1,
    unit: TimeUnit.microsecond,
    anchor: DateTime.utc(2000, 1, 1),
  );
  static final TimeGrain millisecond = TimeGrain._trusted(
    count: 1,
    unit: TimeUnit.millisecond,
    anchor: DateTime.utc(2000, 1, 1),
  );
  static final TimeGrain second = TimeGrain._trusted(
    count: 1,
    unit: TimeUnit.second,
    anchor: DateTime.utc(2000, 1, 1),
  );
  static final TimeGrain minute = TimeGrain._trusted(
    count: 1,
    unit: TimeUnit.minute,
    anchor: DateTime.utc(2000, 1, 1),
  );
  static final TimeGrain hour = TimeGrain._trusted(
    count: 1,
    unit: TimeUnit.hour,
    anchor: DateTime.utc(2000, 1, 1),
  );
  static final TimeGrain day = TimeGrain._trusted(
    count: 1,
    unit: TimeUnit.day,
    anchor: DateTime.utc(2000, 1, 1),
  );

  /// Weeks bucket Sunday → Saturday. The boundaries extend forward
  /// and backward from the anchor (`DateTime.utc(2000, 1, 2)`, a
  /// Sunday) at one-week intervals, so data from any era buckets at
  /// the same alignment.
  ///
  /// For other regional conventions, construct a `TimeGrain` directly
  /// with the `weekStartDay` parameter — for example,
  /// `TimeGrain(count: 1, unit: TimeUnit.week, anchor: ...,
  /// weekStartDay: DateTime.monday)` produces ISO 8601 /
  /// European-style weeks.
  static final TimeGrain week = TimeGrain._trusted(
    count: 1,
    unit: TimeUnit.week,
    anchor: DateTime.utc(2000, 1, 2),
  );
  static final TimeGrain month = TimeGrain._trusted(
    count: 1,
    unit: TimeUnit.month,
    anchor: DateTime.utc(2000, 1, 1),
  );
  static final TimeGrain year = TimeGrain._trusted(
    count: 1,
    unit: TimeUnit.year,
    anchor: DateTime.utc(2000, 1, 1),
  );

  @override
  bool operator ==(Object other) =>
      other is TimeGrain &&
      count == other.count &&
      unit == other.unit &&
      anchor == other.anchor &&
      weekStartDay == other.weekStartDay;

  @override
  int get hashCode => Object.hash(count, unit, anchor, weekStartDay);

  @override
  String toString() {
    final base = count == 1 ? unit.name : '$count ${unit.name}s';
    final parts = <String>[base, 'anchor=$anchor'];
    if (weekStartDay != null) {
      parts.add('weekStartDay=$weekStartDay');
    }
    return 'TimeGrain(${parts.join(', ')})';
  }
}
