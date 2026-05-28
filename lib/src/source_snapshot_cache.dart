import 'execution/source_record.dart';
import 'time_series/grain_arithmetic.dart';
import 'time_series/time_grain.dart';

/// A short-lived cache for normalized source records, keyed by
/// `(sourceId, dateBound)`.
///
/// Without this cache, every analytics widget on a dashboard runs the
/// full "list sources → project date range → fetch records → execute"
/// pipeline in isolation, so M widgets reading from N sources do up
/// to `M × N` record materializations against the underlying data
/// layer for every reload. The expensive step in that pipeline is
/// `fetcher` (it crosses the data layer); analytics execution itself
/// is cheap. Caching at the records boundary collapses `M × N` into
/// at most `N` per cache lifetime while keeping invalidation simple.
///
/// **What is cached:** the normalized `List<SourceRecord>` returned
/// by [fetcher] for a given source and effective date range. The list
/// is wrapped in `List.unmodifiable` before storage, so consumers
/// receive an unmodifiable view on every cache hit and concurrent
/// readers cannot mutate one another's data through the cache. The
/// fetcher is free to return a mutable list — the cache freezes on
/// store.
///
/// **What is NOT cached:**
/// - Source-catalog listing — already cheap.
/// - Analytics execution results — caching those would require
///   invalidation on filter / measure / grouping changes too, which
///   is a much bigger surface. Records-layer caching is the smaller
///   and more useful collapse.
///
/// **Cache key:** `(sourceId, normalizedRange)`. The range is
/// normalized to the start of each bound's day via
/// `TimeGrain.day.startOfBucket` (local-time day boundary), so sub-day
/// timestamp drift and inclusive/exclusive boundary mismatches at call
/// sites can't cause spurious misses. Keys computed from `00:00:00.000`
/// and `23:59:59.999` on the same local day compare equal regardless
/// of system timezone. Normalization lives at the cache boundary
/// only — callers can keep expressing ranges however they already do.
///
/// **Invalidation:** [invalidate] is called by the host when the
/// underlying data has changed. Scoped invalidations
/// (`sourceIds != null`) drop matching entries; unscoped
/// invalidations clear everything. In-flight fetches whose key is
/// covered by the invalidation are marked for discard on completion,
/// so their stale results don't commit back to the cache; in-flight
/// fetches for unaffected keys still commit as normal.
///
/// **In-flight dedup:** if two callers request the same key
/// concurrently (e.g. two widgets reading the same source at the same
/// range), they share one underlying fetch via `_pending`. This is
/// what makes paired queries against a single source cost one fetch,
/// not two.
///
/// **Fetch failure:** if the underlying `fetcher` future completes
/// with an error, every in-flight caller awaiting the same key sees
/// the same error. Failed fetches are not cached — subsequent calls
/// retry against the fetcher.
///
/// **Timing nuance:** cache hits return synchronously-in-microtask via
/// `Future.value`; cache misses return a true async future that
/// completes when the fetcher resolves. This difference rarely
/// matters in production but can surface in unit tests that depend on
/// microtask ordering — beware of `expect(future, completes)` against
/// a cache-hit future, since it may already have a value by the time
/// you await it.
///
/// **Lifetime:** owned by the host (typically the analytics page).
/// Per-page rather than global keeps memory bounded and avoids
/// cross-page invalidation concerns.
class SourceSnapshotCache {
  SourceSnapshotCache({required this.fetcher});

  /// Underlying fetcher injected by the host.
  ///
  /// A function reference rather than a typed provider so the cache
  /// stays testable without any host dependency. Typical binding:
  /// `cache = SourceSnapshotCache(fetcher: myProvider.fetchRecords)`.
  final Future<List<SourceRecord>> Function(
    String sourceId, {
    (DateTime, DateTime)? dateBound,
  })
  fetcher;

  final Map<_CacheKey, List<SourceRecord>> _entries = {};
  final Map<_CacheKey, Future<List<SourceRecord>>> _pending = {};

  /// Keys whose in-flight fetch must NOT commit on completion because
  /// an invalidation that overlapped them fired while they were still
  /// in flight. The flag is consumed (removed) by the fetch's
  /// completion handler so subsequent fetches for the same key are
  /// unaffected.
  final Set<_CacheKey> _discardOnComplete = {};

  /// Returns cached records for `(sourceId, dateBound)` if present;
  /// otherwise calls [fetcher] and caches the result.
  ///
  /// If a fetch for the same key is already in flight, the existing
  /// future is returned — both callers share the one underlying fetch.
  ///
  /// If [invalidate] is called while a fetch is in flight, the result
  /// of that fetch is returned to the caller (so it doesn't see an
  /// error) but it is NOT committed to the cache, so the next call
  /// will trigger a fresh fetch.
  Future<List<SourceRecord>> getOrFetch(
    String sourceId, {
    (DateTime, DateTime)? dateBound,
  }) {
    final key = _makeCacheKey(sourceId, dateBound);

    final cached = _entries[key];
    if (cached != null) {
      return Future.value(cached);
    }

    final pending = _pending[key];
    if (pending != null) {
      return pending;
    }

    // The future references itself inside its `.then` / `.catchError`
    // closures so it can identity-check the entry in `_pending` before
    // removing it. Without that check, a stale future completing after
    // `clear()` would remove a newer entry that happened to be stored
    // under the same key, breaking in-flight dedup. The `late final`
    // pattern satisfies Dart's definite-assignment analysis.
    late final Future<List<SourceRecord>> future;
    future = fetcher(sourceId, dateBound: dateBound)
        .then((records) {
          if (identical(_pending[key], future)) {
            _pending.remove(key);
          }
          if (_discardOnComplete.remove(key)) {
            return records;
          }
          final frozen = List<SourceRecord>.unmodifiable(records);
          _entries[key] = frozen;
          return frozen;
        })
        .catchError((Object e, StackTrace st) {
          if (identical(_pending[key], future)) {
            _pending.remove(key);
          }
          _discardOnComplete.remove(key);
          Error.throwWithStackTrace(e, st);
        });

    _pending[key] = future;
    return future;
  }

  /// Drops cached entries.
  ///
  /// `sourceIds == null` clears everything (the conservative "all
  /// sources" scope when the change is unscoped). Otherwise, only
  /// entries for the listed sources are dropped.
  ///
  /// In-flight fetches are NOT cancelled — Dart futures aren't
  /// cancellable — but each in-flight fetch whose key is covered by
  /// the invalidation is marked for discard on completion. In-flight
  /// fetches for keys outside the invalidation scope are unaffected
  /// and still commit their results when they complete.
  void invalidate({Set<String>? sourceIds}) {
    if (sourceIds == null) {
      _discardOnComplete.addAll(_pending.keys);
      _entries.clear();
    } else {
      for (final k in _pending.keys) {
        if (sourceIds.contains(k.sourceId)) {
          _discardOnComplete.add(k);
        }
      }
      _entries.removeWhere((k, _) => sourceIds.contains(k.sourceId));
    }
  }

  /// Drops all state, including the in-flight fetch tracking map.
  /// In-flight fetches that were started before `clear()` still
  /// complete (Dart futures aren't cancellable) but their results
  /// are discarded rather than cached. Call on host disposal — not
  /// strictly required since the cache is GC'd with its host, but
  /// explicit for clarity.
  ///
  /// Differs from [invalidate] in that `clear()` also empties the
  /// in-flight tracking map, so a new `getOrFetch` for the same key
  /// issued after `clear()` starts a fresh fetch rather than sharing
  /// the in-flight one.
  void clear() {
    _discardOnComplete.addAll(_pending.keys);
    _entries.clear();
    _pending.clear();
  }

  // ── Key construction ───────────────────────────────────────────────

  _CacheKey _makeCacheKey(String sourceId, (DateTime, DateTime)? bound) {
    if (bound == null) return _CacheKey(sourceId, null, null);
    return _CacheKey(
      sourceId,
      TimeGrain.day.startOfBucket(bound.$1),
      TimeGrain.day.startOfBucket(bound.$2),
    );
  }
}

/// Compound cache key. Equality is by all three fields. Both
/// boundaries are normalized to the start of the local day before
/// being stored — that's what collapses sub-day timestamp drift and
/// inclusive/exclusive-boundary differences in caller code into the
/// same key.
class _CacheKey {
  const _CacheKey(this.sourceId, this.startDayKey, this.endDayKey);

  final String sourceId;

  /// Local-day-start of the range's lower bound (`null` when the call
  /// site supplied no date bound at all).
  final DateTime? startDayKey;

  /// Local-day-start of the range's upper bound (`null` when the call
  /// site supplied no date bound at all). Two upper bounds that fall
  /// on the same local day collapse to the same key regardless of
  /// whether the caller treats the boundary as inclusive or
  /// exclusive.
  final DateTime? endDayKey;

  @override
  bool operator ==(Object other) =>
      other is _CacheKey &&
      other.sourceId == sourceId &&
      other.startDayKey == startDayKey &&
      other.endDayKey == endDayKey;

  @override
  int get hashCode => Object.hash(sourceId, startDayKey, endDayKey);
}
