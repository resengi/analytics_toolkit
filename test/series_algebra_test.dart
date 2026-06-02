import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:test/test.dart';

import '_fixtures.dart';

/// Behavioral tests for `SeriesAlgebra` and the `SeriesAlgebraX`
/// extension — the path that operates on a `SeriesResult` already in
/// hand. The arithmetic and type rules these exercise are the same ones
/// the in-query path uses, so these tests also pin that shared
/// behavior.
void main() {
  // ── Builders ──────────────────────────────────────────────────────────

  /// A categorical series of integers keyed by string. `entries` pairs a
  /// key with a value (null for an undefined bucket). `synthetic`, when
  /// given, sets the per-bucket synthetic flag positionally.
  SeriesResult intSeries(
    List<(String, int?)> entries, {
    List<bool>? synthetic,
    String measureLabel = 'm',
    String groupColumnLabel = 'g',
    String? semanticTag,
  }) {
    return SeriesResult(
      buckets: [
        for (var i = 0; i < entries.length; i++)
          SeriesBucket(
            key: StringBucketKey(entries[i].$1),
            value: entries[i].$2 == null ? null : IntValue(entries[i].$2!),
            isSynthetic: synthetic == null ? false : synthetic[i],
          ),
      ],
      groupKind: SeriesGroupKind.categorical,
      groupColumnLabel: groupColumnLabel,
      groupColumnFieldType: FieldType.string,
      measureLabel: measureLabel,
      measureFieldType: FieldType.integer,
      semanticTag: semanticTag,
    );
  }

  SeriesResult doubleSeries(List<(String, double?)> entries) {
    return SeriesResult(
      buckets: [
        for (final e in entries)
          SeriesBucket(
            key: StringBucketKey(e.$1),
            value: e.$2 == null ? null : DoubleValue(e.$2!),
          ),
      ],
      groupKind: SeriesGroupKind.categorical,
      groupColumnLabel: 'g',
      groupColumnFieldType: FieldType.string,
      measureLabel: 'm',
      measureFieldType: FieldType.double,
    );
  }

  SeriesResult durationSeries(List<(String, Duration?)> entries) {
    return SeriesResult(
      buckets: [
        for (final e in entries)
          SeriesBucket(
            key: StringBucketKey(e.$1),
            value: e.$2 == null ? null : DurationValue(e.$2!),
          ),
      ],
      groupKind: SeriesGroupKind.categorical,
      groupColumnLabel: 'g',
      groupColumnFieldType: FieldType.string,
      measureLabel: 'm',
      measureFieldType: FieldType.duration,
    );
  }

  /// A non-numeric (string-valued) series, for rejection tests.
  SeriesResult stringSeries(List<(String, String)> entries) {
    return SeriesResult(
      buckets: [
        for (final e in entries)
          SeriesBucket(key: StringBucketKey(e.$1), value: StringValue(e.$2)),
      ],
      groupKind: SeriesGroupKind.categorical,
      groupColumnLabel: 'g',
      groupColumnFieldType: FieldType.string,
      measureLabel: 'm',
      measureFieldType: FieldType.string,
    );
  }

  // ── Readers ───────────────────────────────────────────────────────────

  /// The ordered (stringKey, value) pairs of an integer series.
  List<(String, int?)> ints(SeriesResult s) => [
    for (final b in s.buckets)
      ((b.key as StringBucketKey).value, (b.value as IntValue?)?.value),
  ];

  List<(String, double?)> doubles(SeriesResult s) => [
    for (final b in s.buckets)
      ((b.key as StringBucketKey).value, (b.value as DoubleValue?)?.value),
  ];

  SeriesResult ok(Result<SeriesResult, AnalyticsError> r) {
    expect(r.isOk, isTrue, reason: r.errOrNull?.humanMessage);
    return r.okOrNull!;
  }

  void expectIncompatible(Result<SeriesResult, AnalyticsError> r) {
    expect(r.isErr, isTrue);
    expect(r.errOrNull!.kind, AnalyticsErrorKind.incompatibleSeriesCombination);
  }

  void expectInvalidParam(Result<SeriesResult, AnalyticsError> r) {
    expect(r.isErr, isTrue);
    expect(
      r.errOrNull!.kind,
      AnalyticsErrorKind.invalidDerivedOperationParameter,
    );
  }

  // ── apply ─────────────────────────────────────────────────────────────

  group('apply', () {
    test('cumulative sum accumulates left to right', () {
      final r = ok(
        SeriesAlgebra.apply(
          intSeries([('a', 1), ('b', 2), ('c', 3)]),
          const CumulativeSumOp(),
        ),
      );
      expect(ints(r), [('a', 1), ('b', 3), ('c', 6)]);
    });

    test('NoDerivedOp returns the series unchanged', () {
      final input = intSeries([('a', 1), ('b', 2)]);
      final r = ok(SeriesAlgebra.apply(input, const NoDerivedOp()));
      expect(identical(r, input), isTrue);
    });

    test('a non-numeric series is rejected', () {
      expectIncompatible(
        SeriesAlgebra.apply(
          stringSeries([('a', 'x')]),
          const CumulativeSumOp(),
        ),
      );
    });

    test('an empty series stays empty', () {
      final r = ok(SeriesAlgebra.apply(intSeries([]), const CumulativeSumOp()));
      expect(r.buckets, isEmpty);
    });

    test('a moving average with a zero window is rejected', () {
      expectInvalidParam(
        SeriesAlgebra.apply(
          intSeries([('a', 1), ('b', 2)]),
          const MovingAverageOp(window: 0),
        ),
      );
    });

    test('movingAverage(-1) via the extension is rejected', () {
      expectInvalidParam(intSeries([('a', 1)]).movingAverage(-1));
    });

    test('a window of 1 is accepted (the identity boundary)', () {
      final r = ok(intSeries([('a', 2), ('b', 4)]).movingAverage(1));
      expect(r.measureFieldType, FieldType.double);
      expect(doubles(r), [('a', 2.0), ('b', 4.0)]);
    });

    test('the parameter check precedes the numeric-series check', () {
      expectInvalidParam(
        SeriesAlgebra.apply(
          stringSeries([('a', 'x')]),
          const MovingAverageOp(window: 0),
        ),
      );
    });
  });

  test('validator and SeriesAlgebra.apply agree on an invalid window', () {
    // The whole design goal is that the in-query and result-level paths
    // share one rule (`derivedOperationParameterError`) and never
    // disagree. This asserts the pair directly: if someone later forks
    // the rule back into two local checks that drift, the per-path tests
    // above might both still pass, but this one fails.
    const op = MovingAverageOp(window: 0);

    // Result-level path. A NUMERIC series keeps the comparison
    // unambiguous: with the parameter check first, the window error is
    // what surfaces, not the numeric-series error.
    final resultLevel = SeriesAlgebra.apply(intSeries([('a', 1)]), op);

    // In-query path: a minimal valid query carrying the same op over a
    // temporal series (a moving average needs a single ordered group).
    final inQuery = QueryValidator.validateQuery(
      AnalyticsQuerySpec(
        source: 'events',
        measures: [
          FieldMeasure(
            fieldRef: ref('events', 'amount'),
            aggregation: const SumAgg(),
          ),
        ],
        groupBys: [
          TimeGroupBy(
            dateFieldRef: ref('events', 'occurredAt'),
            grain: TimeGrain.day,
          ),
        ],
        derivedOperation: op,
      ),
      sources: [eventsSource()],
    );

    expect(resultLevel.isErr, isTrue);
    expect(inQuery.isErr, isTrue);
    expect(
      resultLevel.errOrNull!.kind,
      AnalyticsErrorKind.invalidDerivedOperationParameter,
    );
    // The crux: both paths report the SAME kind.
    expect(inQuery.errOrNull!.kind, resultLevel.errOrNull!.kind);
  });

  // ── transform ───────────────────────────────────────────────────────────

  group('transform', () {
    test('negate flips sign and preserves null', () {
      final r = ok(
        SeriesAlgebra.transform(
          intSeries([('a', 1), ('b', -2), ('c', null)]),
          const NegateOp(),
        ),
      );
      expect(ints(r), [('a', -1), ('b', 2), ('c', null)]);
    });

    test('absolute value preserves null', () {
      final r = ok(
        SeriesAlgebra.transform(
          intSeries([('a', -5), ('b', null)]),
          const AbsOp(),
        ),
      );
      expect(ints(r), [('a', 5), ('b', null)]);
    });

    test('fill-null substitutes only the null buckets', () {
      final r = ok(
        SeriesAlgebra.transform(
          intSeries([('a', 1), ('b', null), ('c', 3)]),
          const FillNullOp(0),
        ),
      );
      expect(ints(r), [('a', 1), ('b', 0), ('c', 3)]);
    });

    test('keys, order, and synthetic flags are preserved', () {
      final input = intSeries([('a', 1), ('b', 2)], synthetic: [false, true]);
      final r = ok(SeriesAlgebra.transform(input, const NegateOp()));
      expect(r.buckets.map((b) => (b.key as StringBucketKey).value).toList(), [
        'a',
        'b',
      ]);
      expect(r.buckets.map((b) => b.isSynthetic).toList(), [false, true]);
    });

    test('a non-numeric series is rejected', () {
      expectIncompatible(
        SeriesAlgebra.transform(stringSeries([('a', 'x')]), const NegateOp()),
      );
    });

    test('scalar ops box duration results correctly', () {
      final negated = ok(
        SeriesAlgebra.transform(
          durationSeries([('a', const Duration(minutes: 10)), ('b', null)]),
          const NegateOp(),
        ),
      );
      expect(
        (negated.buckets[0].value as DurationValue).value,
        const Duration(minutes: -10),
      );
      expect(negated.buckets[1].value, isNull); // null propagates

      // FillNullOp(0) on a duration means 0 microseconds = Duration.zero.
      final filled = ok(
        SeriesAlgebra.transform(
          durationSeries([('a', null)]),
          const FillNullOp(0),
        ),
      );
      expect(
        (filled.buckets.single.value as DurationValue).value,
        Duration.zero,
      );
    });

    test('fill-null on a non-numeric series is rejected', () {
      expectIncompatible(
        SeriesAlgebra.transform(
          stringSeries([('a', 'x')]),
          const FillNullOp(0),
        ),
      );
    });
  });

  // ── combine: output type table ──────────────────────────────────────────

  group('combine output type', () {
    test('integer with integer sum yields integer', () {
      final r = ok(
        SeriesAlgebra.combine(
          intSeries([('a', 2)]),
          intSeries([('a', 3)]),
          op: const SumCombination(),
        ),
      );
      expect(r.measureFieldType, FieldType.integer);
      expect(ints(r), [('a', 5)]);
    });

    test('integer with double yields double', () {
      final r = ok(
        SeriesAlgebra.combine(
          intSeries([('a', 2)]),
          doubleSeries([('a', 0.5)]),
          op: const SumCombination(),
        ),
      );
      expect(r.measureFieldType, FieldType.double);
      expect(doubles(r), [('a', 2.5)]);
    });

    test('product is always a unitless double', () {
      final r = ok(
        SeriesAlgebra.combine(
          intSeries([('a', 4)]),
          intSeries([('a', 3)]),
          op: const ProductCombination(),
        ),
      );
      expect(r.measureFieldType, FieldType.double);
      expect(doubles(r), [('a', 12.0)]);
    });

    test('ratio is always a unitless double', () {
      final r = ok(
        SeriesAlgebra.combine(
          intSeries([('a', 3)]),
          intSeries([('a', 4)]),
          op: const RatioCombination(),
        ),
      );
      expect(r.measureFieldType, FieldType.double);
      expect(doubles(r), [('a', 0.75)]);
    });

    test('duration with duration difference yields duration', () {
      final r = ok(
        SeriesAlgebra.combine(
          durationSeries([('a', const Duration(minutes: 10))]),
          durationSeries([('a', const Duration(minutes: 4))]),
          op: const DifferenceCombination(),
        ),
      );
      expect(r.measureFieldType, FieldType.duration);
      expect(
        (r.buckets.single.value as DurationValue).value,
        const Duration(minutes: 6),
      );
    });

    test('a duration with a non-duration sum is rejected', () {
      expectIncompatible(
        SeriesAlgebra.combine(
          durationSeries([('a', const Duration(minutes: 1))]),
          intSeries([('a', 1)]),
          op: const SumCombination(),
        ),
      );
    });

    test('incompatible group dimensions are rejected', () {
      final temporal = SeriesResult(
        buckets: const [],
        groupKind: SeriesGroupKind.temporal,
        groupColumnLabel: 'g',
        groupColumnFieldType: FieldType.dateTime,
        measureLabel: 'm',
        measureFieldType: FieldType.integer,
      );
      expectIncompatible(
        SeriesAlgebra.combine(
          intSeries([('a', 1)]),
          temporal,
          op: const SumCombination(),
        ),
      );
    });

    test(
      'product with a duration operand yields the microsecond magnitude',
      () {
        // 2 minutes = 120_000_000 microseconds; × 3 (unitless) = 3.6e8.
        final r = ok(
          SeriesAlgebra.combine(
            durationSeries([('a', const Duration(minutes: 2))]),
            intSeries([('a', 3)]),
            op: const ProductCombination(),
          ),
        );
        expect(r.measureFieldType, FieldType.double);
        expect(
          doubles(r).single.$2,
          closeTo(const Duration(minutes: 2).inMicroseconds * 3, 1e-3),
        );
      },
    );
  });

  // ── combine: drop policy ─────────────────────────────────────────────────

  group('combine drop policy', () {
    test('keeps the intersection in x order', () {
      final r = ok(
        SeriesAlgebra.combine(
          intSeries([('a', 1), ('b', 2), ('c', 3)]),
          intSeries([('b', 10), ('c', 20), ('d', 30)]),
          op: const DifferenceCombination(),
        ),
      );
      expect(ints(r), [('b', -8), ('c', -17)]);
    });

    test('a present null value propagates and the key is kept', () {
      final r = ok(
        SeriesAlgebra.combine(
          intSeries([('a', null), ('b', 5)]),
          intSeries([('a', 7), ('b', 2)]),
          op: const DifferenceCombination(),
        ),
      );
      expect(ints(r), [('a', null), ('b', 3)]);
    });

    test('ratio with a zero denominator yields null at that key', () {
      final r = ok(
        SeriesAlgebra.combine(
          intSeries([('a', 5), ('b', 5)]),
          intSeries([('a', 0), ('b', 2)]),
          op: const RatioCombination(),
        ),
      );
      expect(doubles(r), [('a', null), ('b', 2.5)]);
    });

    test('a bucket is synthetic only when both inputs were synthetic', () {
      final r = ok(
        SeriesAlgebra.combine(
          intSeries([('a', 1), ('b', 2)], synthetic: [true, true]),
          intSeries([('a', 1), ('b', 2)], synthetic: [false, true]),
          op: const SumCombination(),
        ),
      );
      expect(r.buckets.map((b) => b.isSynthetic).toList(), [false, true]);
    });
  });

  // ── combine: fillIdentity policy ─────────────────────────────────────────

  group('combine fillIdentity policy', () {
    test('difference fills an absent side with zero (x − 0, 0 − y)', () {
      final r = ok(
        SeriesAlgebra.combine(
          intSeries([('a', 5)]),
          intSeries([('b', 7)]),
          op: const DifferenceCombination(),
          policy: UnmatchedBucketPolicy.fillIdentity,
        ),
      );
      expect(ints(r), [('a', 5), ('b', -7)]);
    });

    test('sum fills an absent side with zero', () {
      final r = ok(
        SeriesAlgebra.combine(
          intSeries([('a', 5)]),
          intSeries([('b', 7)]),
          op: const SumCombination(),
          policy: UnmatchedBucketPolicy.fillIdentity,
        ),
      );
      expect(ints(r), [('a', 5), ('b', 7)]);
    });

    test('product fills an absent side with one', () {
      final r = ok(
        SeriesAlgebra.combine(
          intSeries([('a', 5)]),
          intSeries([('b', 7)]),
          op: const ProductCombination(),
          policy: UnmatchedBucketPolicy.fillIdentity,
        ),
      );
      expect(doubles(r), [('a', 5.0), ('b', 7.0)]);
    });

    test('ratio omits a key absent on either side, having no identity', () {
      final r = ok(
        SeriesAlgebra.combine(
          intSeries([('a', 5)]),
          intSeries([('b', 7)]),
          op: const RatioCombination(),
          policy: UnmatchedBucketPolicy.fillIdentity,
        ),
      );
      expect(r.buckets, isEmpty);
    });

    test('a filled bucket takes its synthetic flag from the present side', () {
      final r = ok(
        SeriesAlgebra.combine(
          intSeries([('a', 5)], synthetic: [true]),
          intSeries([('b', 7)], synthetic: [false]),
          op: const SumCombination(),
          policy: UnmatchedBucketPolicy.fillIdentity,
        ),
      );
      final byKey = {
        for (final b in r.buckets)
          (b.key as StringBucketKey).value: b.isSynthetic,
      };
      expect(byKey['a'], isTrue);
      expect(byKey['b'], isFalse);
    });
  });

  // ── metadata, chaining, immutability ─────────────────────────────────────

  group('combine metadata', () {
    test('inherits x metadata by default', () {
      final r = ok(
        SeriesAlgebra.combine(
          intSeries(
            [('a', 1)],
            measureLabel: 'revenue',
            groupColumnLabel: 'month',
            semanticTag: 'currency',
          ),
          intSeries([('a', 1)]),
          op: const SumCombination(),
        ),
      );
      expect(r.measureLabel, 'revenue');
      expect(r.groupColumnLabel, 'month');
      expect(r.semanticTag, 'currency');
    });

    test('overrides apply when supplied', () {
      final r = ok(
        SeriesAlgebra.combine(
          intSeries(
            [('a', 1)],
            measureLabel: 'revenue',
            semanticTag: 'currency',
          ),
          intSeries([('a', 1)]),
          op: const SumCombination(),
          measureLabel: 'net',
          groupColumnLabel: 'period',
          semanticTag: 'delta',
        ),
      );
      expect(r.measureLabel, 'net');
      expect(r.groupColumnLabel, 'period');
      expect(r.semanticTag, 'delta');
    });
  });

  test('extension methods chain through andThen', () {
    final r = intSeries([
      ('a', 1),
      ('b', 2),
      ('c', 3),
    ]).cumulativeSum().andThen((s) => s.negated());
    expect(ints(ok(r)), [('a', -1), ('b', -3), ('c', -6)]);
  });

  test('combineWith on the extension matches the static form', () {
    final x = intSeries([('a', 4)]);
    final y = intSeries([('a', 1)]);
    final viaExtension = ok(x.combineWith(y, const DifferenceCombination()));
    expect(ints(viaExtension), [('a', 3)]);
  });

  test('inputs are not mutated by an operation', () {
    final x = intSeries([('a', 1), ('b', 2)]);
    final y = intSeries([('a', 10), ('b', 20)]);
    ok(SeriesAlgebra.combine(x, y, op: const SumCombination()));
    expect(ints(x), [('a', 1), ('b', 2)]);
    expect(ints(y), [('a', 10), ('b', 20)]);
  });

  test('combine carries displayLabel from x, falling back to y', () {
    SeriesResult labeled(List<(String, int, String?)> entries) => SeriesResult(
      buckets: [
        for (final e in entries)
          SeriesBucket(
            key: StringBucketKey(e.$1),
            value: IntValue(e.$2),
            displayLabel: e.$3,
          ),
      ],
      groupKind: SeriesGroupKind.categorical,
      groupColumnLabel: 'g',
      groupColumnFieldType: FieldType.string,
      measureLabel: 'm',
      measureFieldType: FieldType.integer,
    );

    String? labelAt(SeriesResult s, String key) => s.buckets
        .firstWhere((b) => (b.key as StringBucketKey).value == key)
        .displayLabel;

    // drop: 'a' has labels on both sides (x wins); 'b' only on y's side
    // (the present-bucket fallback applies since x also has 'b').
    final dropped = ok(
      SeriesAlgebra.combine(
        labeled([('a', 1, 'x-a'), ('b', 2, null)]),
        labeled([('a', 10, 'y-a'), ('b', 20, 'y-b')]),
        op: const SumCombination(),
      ),
    );
    expect(labelAt(dropped, 'a'), 'x-a'); // x preferred
    expect(labelAt(dropped, 'b'), 'y-b'); // x had none, fell back to y

    // fillIdentity: 'a' only in x, 'b' only in y. Each filled bucket
    // takes the present side's label.
    final filled = ok(
      SeriesAlgebra.combine(
        labeled([('a', 5, 'x-a')]),
        labeled([('b', 7, 'y-b')]),
        op: const SumCombination(),
        policy: UnmatchedBucketPolicy.fillIdentity,
      ),
    );
    expect(labelAt(filled, 'a'), 'x-a'); // present side is x
    expect(labelAt(filled, 'b'), 'y-b'); // present side is y
  });
}
