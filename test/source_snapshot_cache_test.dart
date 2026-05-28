import 'dart:async';

import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:test/test.dart';

/// `SourceSnapshotCache` behavior.
///
/// The cache deduplicates in-flight fetches for the same
/// `(sourceId, dateBound)` key; a second `getOrFetch` for an
/// in-flight key returns the same `Future`. Scoped `invalidate`
/// drops entries for the listed sources only — in-flight fetches
/// outside the scope still commit, those inside the scope return
/// their value to awaiters but do NOT commit to the cache.
void main() {
  // ────────────────────────────────────────────────────────────────────
  // In-flight dedup
  // ────────────────────────────────────────────────────────────────────

  group('in-flight dedup', () {
    test(
      'two concurrent getOrFetch calls share one underlying fetch',
      () async {
        var fetcherCalls = 0;
        final completers = <Completer<List<SourceRecord>>>[];
        final cache = SourceSnapshotCache(
          fetcher: (sourceId, {dateBound}) {
            fetcherCalls++;
            final c = Completer<List<SourceRecord>>();
            completers.add(c);
            return c.future;
          },
        );

        final f1 = cache.getOrFetch('A');
        final f2 = cache.getOrFetch('A');

        expect(fetcherCalls, 1);
        // Both callers should see the same value.
        completers.single.complete([SourceRecord(fields: const {})]);
        final r1 = await f1;
        final r2 = await f2;
        expect(r1, r2);
      },
    );
  });

  // ────────────────────────────────────────────────────────────────────
  // Scoped invalidate — in-flight commit
  // ────────────────────────────────────────────────────────────────────

  group('scoped invalidate — in-flight commit semantics', () {
    test(
      'invalidating a different source does NOT discard A\'s in-flight result',
      () async {
        final completers = <String, Completer<List<SourceRecord>>>{};
        final cache = SourceSnapshotCache(
          fetcher: (sourceId, {dateBound}) {
            final c = Completer<List<SourceRecord>>();
            completers[sourceId] = c;
            return c.future;
          },
        );

        // Kick off a fetch for A.
        final fA = cache.getOrFetch('A');

        // Invalidate only B (a different source).
        cache.invalidate(sourceIds: {'B'});

        // Complete A. It should commit to the cache.
        completers['A']!.complete([SourceRecord(fields: const {})]);
        await fA;

        // Subsequent fetch for A should hit the cache (no new fetcher call).
        final preCalls = completers.length;
        await cache.getOrFetch('A');
        expect(
          completers.length,
          preCalls,
          reason: 'Expected cache hit on A; saw a re-fetch instead',
        );
      },
    );

    test(
      'invalidating A while A is in-flight discards the result on completion',
      () async {
        final completers = <Completer<List<SourceRecord>>>[];
        final cache = SourceSnapshotCache(
          fetcher: (sourceId, {dateBound}) {
            final c = Completer<List<SourceRecord>>();
            completers.add(c);
            return c.future;
          },
        );

        // Kick off a fetch for A.
        final fA = cache.getOrFetch('A');

        // Invalidate A while in-flight.
        cache.invalidate(sourceIds: {'A'});

        // Complete A. The awaiter gets the value, but it must NOT commit.
        completers.single.complete([SourceRecord(fields: const {})]);
        await fA;

        // A subsequent getOrFetch must trigger a new fetcher invocation.
        cache.getOrFetch('A');
        expect(
          completers.length,
          2,
          reason: 'Expected a fresh fetch after invalidation; saw a cache hit',
        );
      },
    );
  });

  // ────────────────────────────────────────────────────────────────────
  // Unscoped invalidate
  // ────────────────────────────────────────────────────────────────────

  group('unscoped invalidate (sourceIds: null)', () {
    test('clears every cached entry', () async {
      var fetcherCalls = 0;
      final cache = SourceSnapshotCache(
        fetcher: (sourceId, {dateBound}) async {
          fetcherCalls++;
          return const [];
        },
      );

      await cache.getOrFetch('A');
      await cache.getOrFetch('B');
      expect(fetcherCalls, 2);

      cache.invalidate(); // unscoped

      // Both should refetch.
      await cache.getOrFetch('A');
      await cache.getOrFetch('B');
      expect(fetcherCalls, 4);
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // dateBound is part of the cache key
  // ────────────────────────────────────────────────────────────────────

  group('dateBound is part of the cache key', () {
    test('different dateBound values produce separate cache entries', () async {
      var fetcherCalls = 0;
      final cache = SourceSnapshotCache(
        fetcher: (sourceId, {dateBound}) async {
          fetcherCalls++;
          return const [];
        },
      );

      final bound1 = (DateTime(2026, 5, 1), DateTime(2026, 5, 10));
      final bound2 = (DateTime(2026, 5, 1), DateTime(2026, 5, 20));

      await cache.getOrFetch('A', dateBound: bound1);
      await cache.getOrFetch('A', dateBound: bound2);

      // Distinct keys → two fetcher calls.
      expect(fetcherCalls, 2);

      // Same key as the first call → cache hit.
      await cache.getOrFetch('A', dateBound: bound1);
      expect(fetcherCalls, 2);
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // Errors don't poison the cache
  // ────────────────────────────────────────────────────────────────────

  group('failed fetches do not commit', () {
    test('a fetch that throws is not cached; the next call retries', () async {
      var fetcherCalls = 0;
      var shouldFail = true;
      final cache = SourceSnapshotCache(
        fetcher: (sourceId, {dateBound}) async {
          fetcherCalls++;
          if (shouldFail) {
            throw StateError('boom');
          }
          return const [];
        },
      );

      // First fetch throws.
      await expectLater(cache.getOrFetch('A'), throwsStateError);
      expect(fetcherCalls, 1);

      // Next fetch must re-invoke the fetcher (no cached value to return).
      shouldFail = false;
      await cache.getOrFetch('A');
      expect(fetcherCalls, 2);
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // Freeze on store
  // ────────────────────────────────────────────────────────────────────

  group('freeze on store', () {
    test(
      'cached lists reject mutation; callers cannot poison the cache',
      () async {
        // The fetcher returns a mutable list; the cache must freeze it
        // before handing it to the caller.
        final cache = SourceSnapshotCache(
          fetcher: (sourceId, {dateBound}) async => [
            SourceRecord(fields: const {}),
          ],
        );

        final fetched = await cache.getOrFetch('A');
        expect(
          () => fetched.add(SourceRecord(fields: const {})),
          throwsUnsupportedError,
        );

        // The cached value is still a single record — the failed
        // mutation didn't sneak in.
        final reread = await cache.getOrFetch('A');
        expect(reread, hasLength(1));
      },
    );
  });
}
