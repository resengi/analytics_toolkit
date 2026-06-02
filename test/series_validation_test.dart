import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:test/test.dart';

import '_fixtures.dart';

/// Validation tests for expression measures. The validator rejects an
/// operand that isn't numeric, a sum or difference that mixes unit
/// families, a streak measure used as an operand, and an expression
/// nested past the configured depth; it accepts a well-formed
/// calculation, including one feeding a derived operation.
void main() {
  SourceDef source() => SourceDef(
    sourceId: 's',
    displayName: 'S',
    fields: const [
      FieldDef(
        sourceId: 's',
        fieldId: 'region',
        displayName: 'Region',
        fieldType: FieldType.enumeration,
        filterable: true,
        groupable: true,
        aggregatable: false,
        sortable: true,
      ),
      FieldDef(
        sourceId: 's',
        fieldId: 'revenue',
        displayName: 'Revenue',
        fieldType: FieldType.integer,
        filterable: true,
        groupable: false,
        aggregatable: true,
        sortable: true,
      ),
      FieldDef(
        sourceId: 's',
        fieldId: 'cost',
        displayName: 'Cost',
        fieldType: FieldType.integer,
        filterable: true,
        groupable: false,
        aggregatable: true,
        sortable: true,
      ),
      FieldDef(
        sourceId: 's',
        fieldId: 'span',
        displayName: 'Span',
        fieldType: FieldType.duration,
        filterable: true,
        groupable: false,
        aggregatable: true,
        sortable: true,
      ),
      FieldDef(
        sourceId: 's',
        fieldId: 'at',
        displayName: 'At',
        fieldType: FieldType.dateTime,
        filterable: true,
        groupable: true,
        aggregatable: true,
        sortable: true,
      ),
    ],
    primaryDateFieldId: 'at',
  );

  final src = source();

  Result<Unit, AnalyticsError> validate(
    List<Measure> measures, {
    List<GroupBy> groupBys = const [],
    DerivedOperation derived = const NoDerivedOp(),
    int maxExpressionDepth = QueryValidator.defaultMaxExpressionDepth,
  }) {
    return QueryValidator.validateQuery(
      AnalyticsQuerySpec(
        source: 's',
        measures: measures,
        groupBys: groupBys,
        derivedOperation: derived,
      ),
      sources: [src],
      maxExpressionDepth: maxExpressionDepth,
    );
  }

  FieldMeasure sum(String field) =>
      FieldMeasure(fieldRef: ref('s', field), aggregation: const SumAgg());

  void expectKind(Result<Unit, AnalyticsError> r, AnalyticsErrorKind kind) {
    expect(r.isErr, isTrue);
    expect(r.errOrNull!.kind, kind);
  }

  test('a per-value op on a non-numeric operand is rejected', () {
    // min over a dateTime field produces a DateTimeValue.
    final r = validate([
      TransformedMeasure(
        operand: FieldMeasure(
          fieldRef: ref('s', 'at'),
          aggregation: const MinAgg(),
        ),
        op: const NegateOp(),
      ),
    ]);
    expectKind(r, AnalyticsErrorKind.incompatibleSeriesCombination);
  });

  test('a calculation with a non-numeric operand is rejected', () {
    final r = validate([
      CalculatedMeasure(
        operandA: FieldMeasure(
          fieldRef: ref('s', 'at'),
          aggregation: const MinAgg(),
        ),
        operandB: sum('revenue'),
        combination: const SumCombination(),
      ),
    ]);
    expectKind(r, AnalyticsErrorKind.incompatibleSeriesCombination);
  });

  test('a sum mixing a duration with an integer is rejected', () {
    final r = validate([
      CalculatedMeasure(
        operandA: sum('revenue'),
        operandB: sum('span'),
        combination: const SumCombination(),
      ),
    ]);
    expectKind(r, AnalyticsErrorKind.incompatibleSeriesCombination);
  });

  test('a ratio of two durations is accepted (unitless, no mix rule)', () {
    final r = validate([
      CalculatedMeasure(
        operandA: sum('span'),
        operandB: sum('span'),
        combination: const RatioCombination(),
      ),
    ]);
    expect(r.isOk, isTrue, reason: r.errOrNull?.humanMessage);
  });

  test('a streak measure used as an operand is rejected', () {
    final streak = StreakMeasure(
      entityIdField: ref('s', 'region'),
      scheduledDateField: ref('s', 'at'),
      statusField: ref('s', 'region'),
      completedStatusValue: 'north',
    );
    final r = validate([
      TransformedMeasure(operand: streak, op: const NegateOp()),
    ]);
    expectKind(r, AnalyticsErrorKind.streakNotCombinable);
  });

  test('nesting past the configured depth is rejected', () {
    // Three transform nodes: depth 3.
    final depth3 = TransformedMeasure(
      operand: TransformedMeasure(
        operand: TransformedMeasure(
          operand: sum('revenue'),
          op: const NegateOp(),
        ),
        op: const NegateOp(),
      ),
      op: const NegateOp(),
    );
    expectKind(
      validate([depth3], maxExpressionDepth: 2),
      AnalyticsErrorKind.preconditionViolation,
    );
  });

  test('nesting exactly at the configured depth is accepted', () {
    // Two transform nodes: depth 2, which equals the bound and is
    // allowed (only strictly deeper is rejected).
    final depth2 = TransformedMeasure(
      operand: TransformedMeasure(
        operand: sum('revenue'),
        op: const NegateOp(),
      ),
      op: const NegateOp(),
    );
    final r = validate([depth2], maxExpressionDepth: 2);
    expect(r.isOk, isTrue, reason: r.errOrNull?.humanMessage);
  });

  test('a calculation feeding a cumulative sum validates', () {
    final r = validate(
      [
        CalculatedMeasure(
          operandA: sum('revenue'),
          operandB: sum('cost'),
          combination: const DifferenceCombination(),
        ),
      ],
      groupBys: [
        TimeGroupBy(dateFieldRef: ref('s', 'at'), grain: TimeGrain.day),
      ],
      derived: const CumulativeSumOp(),
    );
    expect(r.isOk, isTrue, reason: r.errOrNull?.humanMessage);
  });

  test('the measure cap counts top-level expression measures', () {
    CalculatedMeasure calc(String label) => CalculatedMeasure(
      operandA: sum('revenue'),
      operandB: sum('cost'),
      combination: const DifferenceCombination(),
      label: label,
    );
    final five = [for (var i = 0; i < 5; i++) calc('m$i')];
    final byRegion = [FieldGroupBy(fieldRef: ref('s', 'region'))];
    expect(validate(five, groupBys: byRegion).isOk, isTrue);
    final six = [for (var i = 0; i < 6; i++) calc('m$i')];
    expectKind(
      validate(six, groupBys: byRegion),
      AnalyticsErrorKind.tooManyMeasures,
    );
  });
}
