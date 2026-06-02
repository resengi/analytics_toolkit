import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:test/test.dart';

import '_fixtures.dart';

/// Round-trip tests for the expression-measure encodings:
/// `CalculatedMeasure`, `TransformedMeasure`, and the `SeriesCombination`
/// / `ScalarOp` tags they embed. A payload that encodes and decodes back
/// to an equal value confirms the wire format is complete and stable.
void main() {
  void expectRoundTrip(Measure measure) {
    final payload = SingleQuerySpec(
      query: AnalyticsQuerySpec(source: 'tasks', measures: [measure]),
    );
    final decoded = WidgetPayloadCodec.decodeQueryPayload(
      WidgetPayloadCodec.encodeQueryPayload(payload),
    );
    expect(decoded, payload);
  }

  FieldMeasure priority() => FieldMeasure(
    fieldRef: ref('tasks', 'priority'),
    aggregation: const SumAgg(),
  );

  test('CalculatedMeasure round-trips for every combination', () {
    const combinations = <SeriesCombination>[
      SumCombination(),
      DifferenceCombination(),
      ProductCombination(),
      RatioCombination(),
    ];
    for (final combination in combinations) {
      expectRoundTrip(
        CalculatedMeasure(
          operandA: priority(),
          operandB: priority(),
          combination: combination,
        ),
      );
    }
  });

  test('TransformedMeasure round-trips for every scalar op', () {
    const ops = <ScalarOp>[NegateOp(), AbsOp(), FillNullOp(0), FillNullOp(1.5)];
    for (final op in ops) {
      expectRoundTrip(TransformedMeasure(operand: priority(), op: op));
    }
  });

  test('fill-null preserves an integer fill distinctly from a double', () {
    // `==` alone cannot tell these apart — Dart treats `2 == 2.0` as
    // true — so round-trip each fill and assert the decoded value's
    // runtime type directly.
    num decodedFill(num fill) {
      final payload = SingleQuerySpec(
        query: AnalyticsQuerySpec(
          source: 'tasks',
          measures: [
            TransformedMeasure(operand: priority(), op: FillNullOp(fill)),
          ],
        ),
      );
      final decoded = WidgetPayloadCodec.decodeQueryPayload(
        WidgetPayloadCodec.encodeQueryPayload(payload),
      );
      final measure =
          (decoded as SingleQuerySpec).query.measures.single
              as TransformedMeasure;
      return (measure.op as FillNullOp).fill;
    }

    expect(decodedFill(2), isA<int>());
    expect(decodedFill(2.5), isA<double>());
  });

  test('a nested calculation round-trips', () {
    // (a − b) / a
    expectRoundTrip(
      CalculatedMeasure(
        operandA: CalculatedMeasure(
          operandA: priority(),
          operandB: priority(),
          combination: const DifferenceCombination(),
        ),
        operandB: priority(),
        combination: const RatioCombination(),
      ),
    );
  });

  test('a transformed measure as a calculation operand round-trips', () {
    expectRoundTrip(
      CalculatedMeasure(
        operandA: TransformedMeasure(operand: priority(), op: const NegateOp()),
        operandB: priority(),
        combination: const SumCombination(),
      ),
    );
  });

  test('labels on the node and its operands round-trip', () {
    expectRoundTrip(
      CalculatedMeasure(
        operandA: FieldMeasure(
          fieldRef: ref('tasks', 'priority'),
          aggregation: const SumAgg(),
          label: 'a',
        ),
        operandB: FieldMeasure(
          fieldRef: ref('tasks', 'priority'),
          aggregation: const SumAgg(),
          label: 'b',
        ),
        combination: const DifferenceCombination(),
        label: 'profit',
      ),
    );
  });
}
