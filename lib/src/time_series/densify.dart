import 'grain_arithmetic.dart';
import 'time_grain.dart';

/// Densifies a list of items keyed by time-bucket instants.
///
/// Walks the half-open `[startInclusive, endExclusive)` range bucket
/// by bucket. For each grain-aligned position, emits either the
/// existing item (matched via [instantOf]) or a newly-synthesized one
/// (produced by [synthesize]). Items whose [instantOf] returns `null`
/// — e.g. `NullBucketKey` entries that don't belong to the temporal
/// axis — are preserved at the end of the output in their original
/// order.
///
/// Single source of truth for time-bucket densification. The executor
/// densifies `SeriesBucket` lists; the grouping engine densifies bare
/// `BucketKey` lists. Both call here with a matching `synthesize`
/// callback.
List<T> densifyTimeBuckets<T>({
  required List<T> input,
  required TimeGrain grain,
  required (DateTime, DateTime) dateRange,
  required DateTime? Function(T item) instantOf,
  required T Function(DateTime instant) synthesize,
}) {
  final byInstant = <DateTime, T>{};
  final passthrough = <T>[];
  for (final item in input) {
    final inst = instantOf(item);
    if (inst != null) {
      byInstant[inst] = item;
    } else {
      passthrough.add(item);
    }
  }

  final endExclusive = dateRange.$2;
  var current = grain.startOfBucket(dateRange.$1);
  final densified = <T>[];
  while (current.isBefore(endExclusive)) {
    densified.add(byInstant[current] ?? synthesize(current));
    current = grain.nextBucketStart(current);
  }
  return [...densified, ...passthrough];
}
