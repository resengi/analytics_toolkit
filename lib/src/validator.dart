import 'equality.dart';
import 'errors.dart';
import 'execution/series_numeric.dart';
import 'infer_result_shape.dart';
import 'query/measure.dart';
import 'query/query_components.dart';
import 'query/query_enums.dart';
import 'query/query_spec.dart';
import 'results.dart';
import 'schema/schema.dart';
import 'schema/source_lookup.dart';
import 'schema/typed_value.dart';
import 'time_series/date_range.dart';

/// Static validation of analytics queries and widget payloads.
///
/// The validator is pure: it returns typed `Result` values and never
/// throws for validation failures. The executor calls
/// `validateQuery` at the top of every pipeline; callers that
/// persist or accept user-built widgets should also call
/// `validateWidgetPayload` before save.
abstract class QueryValidator {
  /// Default ceiling on the nesting depth of an expression measure
  /// ([CalculatedMeasure] / [TransformedMeasure]). Depth counts the
  /// expression nodes on the longest root-to-leaf path; a leaf measure
  /// is depth 0. The bound keeps per-bucket evaluation cost on a
  /// pathological tree bounded. Override it via the `maxExpressionDepth`
  /// parameter on [validateQuery] / [validateWidgetPayload] (and on
  /// `AnalyticsExecutor.execute`).
  static const int defaultMaxExpressionDepth = 8;

  // ──────────────────────────────────────────────────────────────────────
  // Top-level entries
  // ──────────────────────────────────────────────────────────────────────

  /// Validates a single [AnalyticsQuerySpec] against a [sources]
  /// catalog. Returns `Ok(Unit.value)` on success or `Err(AnalyticsError)`
  /// with the first violation encountered.
  ///
  /// [maxExpressionDepth] bounds the nesting depth of any expression
  /// measure; a top-level measure whose tree is deeper is rejected with
  /// `preconditionViolation`. Defaults to [defaultMaxExpressionDepth].
  static Result<Unit, AnalyticsError> validateQuery(
    AnalyticsQuerySpec query, {
    required List<SourceDef> sources,
    int maxExpressionDepth = defaultMaxExpressionDepth,
  }) {
    final source = findSourceById(sources, query.source);
    if (source == null) {
      return Err(
        AnalyticsError(
          kind: AnalyticsErrorKind.unknownSource,
          humanMessage: 'Unknown source: ${query.source}',
        ),
      );
    }

    // Measures list — bounds and per-measure validation.
    if (query.measures.isEmpty) {
      return const Err(
        AnalyticsError(
          kind: AnalyticsErrorKind.measuresEmpty,
          humanMessage:
              'AnalyticsQuerySpec.measures must contain at least one '
              'measure. The validator rejects empty measures lists.',
        ),
      );
    }
    if (query.measures.length > 5) {
      return Err(
        AnalyticsError(
          kind: AnalyticsErrorKind.tooManyMeasures,
          humanMessage:
              'A query may have at most 5 measures; got '
              '${query.measures.length}. Wider results should split into '
              'multiple queries or pre-aggregate upstream.',
        ),
      );
    }
    // Per-measure validation (CountMeasure: always valid; FieldMeasure:
    // field exists / aggregatable / aggregation compatible; StreakMeasure:
    // fields exist and have the right types / topN is sane; expression
    // measures: operands valid, numeric, and combinable). Expression
    // nesting depth is bounded first so a pathological tree is rejected
    // before it is walked.
    for (final m in query.measures) {
      if (_expressionDepth(m) > maxExpressionDepth) {
        return Err(
          AnalyticsError(
            kind: AnalyticsErrorKind.preconditionViolation,
            humanMessage:
                'Expression measure nesting exceeds the maximum depth of '
                '$maxExpressionDepth.',
          ),
        );
      }
      final r = _validateMeasure(m, source);
      if (r.isErr) return r;
    }
    // Streak combinability: streak has its own pipeline and produces a
    // fixed table shape, so it cannot be mixed with other measures.
    final streakIndices = <int>[];
    for (var i = 0; i < query.measures.length; i++) {
      if (query.measures[i] is StreakMeasure) streakIndices.add(i);
    }
    if (streakIndices.isNotEmpty && query.measures.length > 1) {
      return const Err(
        AnalyticsError(
          kind: AnalyticsErrorKind.streakNotCombinable,
          humanMessage:
              'StreakMeasure cannot be combined with other measures in '
              'the same query. Streak runs its own pipeline and produces '
              'a fixed table shape.',
        ),
      );
    }
    // Effective-label uniqueness. The label that HavingClause and
    // MeasureValueSort resolve against is `measure.label` if non-null,
    // otherwise the auto-generated `'measure_<index>'`. Mixing an
    // explicit label that happens to collide with another measure's
    // auto-label is also a duplicate.
    final effectiveLabels = Measure.effectiveLabelsFor(query.measures);
    final seenLabels = <String>{};
    for (var i = 0; i < effectiveLabels.length; i++) {
      if (!seenLabels.add(effectiveLabels[i])) {
        return Err(
          AnalyticsError(
            kind: AnalyticsErrorKind.duplicateMeasureLabel,
            humanMessage:
                'Measure effective label "${effectiveLabels[i]}" appears '
                'on more than one measure. Effective labels (explicit '
                '`Measure.label` or the auto-generated `measure_<index>`) '
                'must be unique within a query because HavingClause and '
                'MeasureValueSort resolve by label.',
          ),
        );
      }
    }

    // Streak-shape pre-checks. A streak query (single measure, the
    // streak) ignores generic sort/limit/HAVING clauses at execution;
    // reject them here so the validator never lets a "valid" streak
    // query carry a clause that will be silently dropped. The
    // streakNotCombinable check above already ensures that if streak
    // appears at all, it's the only measure.
    final isStreakQuery = streakIndices.length == 1;
    if (isStreakQuery) {
      if (query.sort != null) {
        return const Err(
          AnalyticsError(
            kind: AnalyticsErrorKind.preconditionViolation,
            humanMessage:
                'StreakMeasure does not support a sort clause. Streak rows '
                'are ordered by current streak descending.',
          ),
        );
      }
      if (query.limit != null) {
        return const Err(
          AnalyticsError(
            kind: AnalyticsErrorKind.preconditionViolation,
            humanMessage:
                'StreakMeasure uses StreakMeasure.topN instead of the '
                'query-level limit.',
          ),
        );
      }
      if (query.having != null) {
        return const Err(
          AnalyticsError(
            kind: AnalyticsErrorKind.preconditionViolation,
            humanMessage:
                'StreakMeasure does not support a HAVING clause. Streak '
                'rows are filtered via StreakMeasure.topN, not by '
                'thresholding aggregated bucket values.',
          ),
        );
      }
    }

    // Filters.
    for (final filter in query.filters) {
      final r = _validateFilter(filter, source);
      if (r.isErr) return r;
    }

    // GroupBys — validated as a list. Cardinality determines the
    // result shape; every entry is a `GroupBy` and follows the same
    // per-entry rules.
    if (query.groupBys.length > 3) {
      return Err(
        AnalyticsError(
          kind: AnalyticsErrorKind.tooManyGroupBys,
          humanMessage:
              'A query may have at most 3 group-by clauses; got '
              '${query.groupBys.length}. Higher-dimensional analyses '
              'should pre-aggregate upstream.',
        ),
      );
    }
    // At most one TimeGroupBy — densification can only meaningfully
    // apply along a single temporal axis.
    var temporalCount = 0;
    for (final g in query.groupBys) {
      if (g is TimeGroupBy) temporalCount++;
    }
    if (temporalCount > 1) {
      return const Err(
        AnalyticsError(
          kind: AnalyticsErrorKind.multipleTemporalGroupBys,
          humanMessage:
              'A query may have at most one TimeGroupBy in its groupBys '
              'list; densification operates along a single time axis.',
        ),
      );
    }
    // Streak query rejects any group-by entry — streak's grouping is
    // implicit (per entity ID). Top-level check, fires before the
    // per-entry validation loop.
    if (isStreakQuery && query.groupBys.isNotEmpty) {
      return const Err(
        AnalyticsError(
          kind: AnalyticsErrorKind.streakWithExplicitGrouping,
          humanMessage:
              'Streak measures cannot be combined with group-by '
              'clauses. Streak grouping is implicit (per entity).',
        ),
      );
    }
    // Per-entry validation.
    for (final g in query.groupBys) {
      final r = _validateGroupBy(g, source);
      if (r.isErr) return r;
    }
    // All entries must be distinct — no two equivalent group-bys (same
    // field at the same grain, or same field with no grain).
    for (var i = 0; i < query.groupBys.length; i++) {
      for (var j = i + 1; j < query.groupBys.length; j++) {
        if (_groupBysAreEquivalent(query.groupBys[i], query.groupBys[j])) {
          return Err(
            AnalyticsError(
              kind: AnalyticsErrorKind.preconditionViolation,
              humanMessage:
                  'groupBys must be distinct; entries at positions $i '
                  'and $j target the same dimension.',
            ),
          );
        }
      }
    }
    // Column-label uniqueness across the projected result. The union
    // of effective group-by labels (`GroupBy.label` when set, else the
    // underlying field id) and effective measure labels must be unique
    // because `TableColumn.label` is addressable and a collision would
    // make `TableResult.columnByLabel` ambiguous.
    final columnLabels = [
      for (final g in query.groupBys) g.effectiveLabel,
      ...effectiveLabels,
    ];
    final seenColumnLabels = <String>{};
    for (final columnLabel in columnLabels) {
      if (!seenColumnLabels.add(columnLabel)) {
        return Err(
          AnalyticsError(
            kind: AnalyticsErrorKind.duplicateColumnLabel,
            humanMessage:
                'Column label "$columnLabel" is used by more than one '
                'group-by or measure. Set an explicit `label` on the '
                'colliding `GroupBy` or `Measure` to disambiguate.',
          ),
        );
      }
    }

    // Derived operations are only valid for `SeriesResult`-shaped
    // queries — single groupBy with a single (numeric) measure. With
    // 2+ groupBys the result is `MultiSeriesResult` or `TableResult`,
    // and with 2+ measures the result is `MultiMeasureSeriesResult` or
    // `TableResult`; neither has a meaningful "moving average across
    // what dimension/measure?" answer.
    if (query.derivedOperation is! NoDerivedOp) {
      if (query.groupBys.length != 1) {
        return Err(
          AnalyticsError(
            kind: AnalyticsErrorKind.preconditionViolation,
            humanMessage:
                'Derived operations require exactly one group-by; got '
                '${query.groupBys.length}.',
          ),
        );
      }
      if (query.measures.length != 1) {
        return Err(
          AnalyticsError(
            kind: AnalyticsErrorKind.preconditionViolation,
            humanMessage:
                'Derived operations require exactly one measure; got '
                '${query.measures.length}.',
          ),
        );
      }
    }

    // Sort.
    if (query.sort != null) {
      final r = _validateSort(
        query.sort!,
        query.groupBys,
        query.measures,
        source,
      );
      if (r.isErr) return r;
    }

    // HAVING.
    if (query.having != null) {
      final r = _validateHaving(query.having!, query, source);
      if (r.isErr) return r;
    }

    // Derived operation. Validator above has already guaranteed
    // `query.measures.length == 1` when derivedOp is non-trivial, so
    // passing `measures.single` here is safe.
    final derivedCheck = _validateDerivedOperation(
      query.derivedOperation,
      query.measures.length == 1 ? query.measures.single : null,
      source,
    );
    if (derivedCheck.isErr) return derivedCheck;

    // Limit must be non-negative if specified.
    if (query.limit != null && query.limit! < 0) {
      return Err(
        AnalyticsError(
          kind: AnalyticsErrorKind.preconditionViolation,
          humanMessage:
              'AnalyticsQuerySpec.limit must be non-negative; got '
              '${query.limit}.',
        ),
      );
    }

    return const Ok(Unit.value);
  }

  /// Validates a [QueryPayload] together with its date-range mode.
  ///
  /// Use this entry when persisting or accepting a user-built widget
  /// — it runs `validateQuery` on each inner query, checks paired
  /// alignability, and enforces the date-range cross rule (the
  /// widget's `DateRangeMode` must agree with the measure's
  /// `supportsDateRange`).
  static Result<Unit, AnalyticsError> validateWidgetPayload({
    required QueryPayload payload,
    required List<SourceDef> sources,
    required DateRangeMode dateRangeMode,
    int maxExpressionDepth = defaultMaxExpressionDepth,
  }) {
    switch (payload) {
      case SingleQuerySpec(query: final q):
        final inner = validateQuery(
          q,
          sources: sources,
          maxExpressionDepth: maxExpressionDepth,
        );
        if (inner.isErr) return inner;
        // Every measure in the query must individually satisfy the
        // date-range cross-rule. In practice the rule is uniform
        // across the list — `streakNotCombinable` (a streak measure
        // can't coexist with others) and the `supportsDateRange`
        // contract together mean every measure in a query agrees on
        // whether it supports a date range — but iterating is the
        // straightforward and future-proof formulation.
        for (final m in q.measures) {
          final r = _validateDateRangeCrossRule(m, dateRangeMode);
          if (r.isErr) return r;
        }
        return const Ok(Unit.value);

      case PairedQuerySpec(xQuery: final x, yQuery: final y):
        final xCheck = validateQuery(
          x,
          sources: sources,
          maxExpressionDepth: maxExpressionDepth,
        );
        if (xCheck.isErr) return xCheck;
        final yCheck = validateQuery(
          y,
          sources: sources,
          maxExpressionDepth: maxExpressionDepth,
        );
        if (yCheck.isErr) return yCheck;

        // Both halves must infer to series.
        if (InferResultShape.ofQuery(x) != ResultShape.series ||
            InferResultShape.ofQuery(y) != ResultShape.series) {
          return const Err(
            AnalyticsError(
              kind: AnalyticsErrorKind.incompatiblePairedQueryShapes,
              humanMessage: 'Paired queries must both produce series results.',
            ),
          );
        }

        // Alignability.
        final align = _validateAlignability(x, y, sources);
        if (align.isErr) return align;

        // Date-range cross rule must hold for both halves' measures.
        // The series-shape precondition above guarantees each half has
        // exactly one measure, so `.single` is safe.
        final xRule = _validateDateRangeCrossRule(
          x.measures.single,
          dateRangeMode,
        );
        if (xRule.isErr) return xRule;
        return _validateDateRangeCrossRule(y.measures.single, dateRangeMode);
    }
  }

  // ──────────────────────────────────────────────────────────────────────
  // Measure
  // ──────────────────────────────────────────────────────────────────────

  static Result<Unit, AnalyticsError> _validateMeasure(
    Measure measure,
    SourceDef source,
  ) {
    switch (measure) {
      case CountMeasure():
        return const Ok(Unit.value);

      case FieldMeasure(fieldRef: final ref, aggregation: final agg):
        return _resolveFieldRef(ref, source).andThen((field) {
          if (!field.aggregatable) {
            return Err(
              AnalyticsError(
                kind: AnalyticsErrorKind.fieldNotAggregatable,
                affectedField: ref,
                humanMessage: 'Field ${field.displayName} is not aggregatable.',
              ),
            );
          }
          if (!agg.compatibleWith(field.fieldType)) {
            return Err(
              AnalyticsError(
                kind: AnalyticsErrorKind.incompatibleAggregation,
                affectedField: ref,
                humanMessage:
                    'Aggregation ${_aggregationName(agg)} is not compatible '
                    'with field type ${field.fieldType.name}.',
              ),
            );
          }
          final paramCheck = _validateAggregationParameters(agg, ref);
          if (paramCheck.isErr) return paramCheck;
          return const Ok(Unit.value);
        });

      case StreakMeasure(
        entityIdField: final entityIdRef,
        scheduledDateField: final scheduledRef,
        statusField: final statusRef,
        entityLabelField: final labelRef,
        topN: final topN,
      ):
        return _resolveFieldRef(scheduledRef, source).andThen((scheduledField) {
          if (scheduledField.fieldType != FieldType.dateTime) {
            return Err(
              AnalyticsError(
                kind: AnalyticsErrorKind.timeGrainOnNonDateField,
                affectedField: scheduledRef,
                humanMessage:
                    'Streak measure requires a dateTime scheduled-date '
                    'field; ${scheduledField.displayName} is '
                    '${scheduledField.fieldType.name}.',
              ),
            );
          }

          // Validate the entity-id field. The status field is resolved
          // and additionally constrained to a string-comparable type:
          // the streak executor compares status values to
          // [StreakMeasure.completedStatusValue] as strings, so anything
          // that isn't FieldType.string or FieldType.enumeration would
          // silently fail to match at execution time.
          if (_resolveFieldRef(entityIdRef, source) case Err(error: final e)) {
            return Err(e);
          }
          final FieldDef statusField;
          switch (_resolveFieldRef(statusRef, source)) {
            case Err(error: final e):
              return Err(e);
            case Ok(value: final f):
              statusField = f;
          }
          if (statusField.fieldType != FieldType.string &&
              statusField.fieldType != FieldType.enumeration) {
            return Err(
              AnalyticsError(
                kind: AnalyticsErrorKind.preconditionViolation,
                affectedField: statusRef,
                humanMessage:
                    'Streak measure requires a string or enumeration '
                    'status field; ${statusField.displayName} is '
                    '${statusField.fieldType.name}.',
              ),
            );
          }

          // Optional label field — must exist on the source if set,
          // and must be a string field. The streak executor's
          // first-non-empty-label rule reads a [StringValue] per
          // record; declaring the label field as anything else means
          // the executor never picks up a label and silently falls
          // back to the entity id.
          if (labelRef != null) {
            final FieldDef labelField;
            switch (_resolveFieldRef(labelRef, source)) {
              case Err(error: final e):
                return Err(e);
              case Ok(value: final f):
                labelField = f;
            }
            if (labelField.fieldType != FieldType.string) {
              return Err(
                AnalyticsError(
                  kind: AnalyticsErrorKind.preconditionViolation,
                  affectedField: labelRef,
                  humanMessage:
                      'Streak measure requires a string entity-label '
                      'field; ${labelField.displayName} is '
                      '${labelField.fieldType.name}.',
                ),
              );
            }
          }

          // topN must be non-negative if set.
          if (topN != null && topN < 0) {
            return Err(
              AnalyticsError(
                kind: AnalyticsErrorKind.preconditionViolation,
                humanMessage:
                    'StreakMeasure.topN must be non-negative; got $topN.',
              ),
            );
          }

          return const Ok(Unit.value);
        });

      case TransformedMeasure(operand: final operand):
        if (operand is StreakMeasure) return _streakAsOperand();
        final operandCheck = _validateMeasure(operand, source);
        if (operandCheck.isErr) return operandCheck;
        // Operands are validated above, so outputFieldType resolves
        // without throwing. A per-value op preserves type and so
        // requires a numeric operand.
        final operandType = operand.outputFieldType(source);
        if (operandType == null || !isNumericFieldType(operandType)) {
          return _incompatibleCombination(
            'A per-value operation requires a numeric operand; the '
            'operand produces a non-numeric value.',
          );
        }
        return const Ok(Unit.value);

      case CalculatedMeasure(
        operandA: final a,
        operandB: final b,
        combination: final combination,
      ):
        if (a is StreakMeasure || b is StreakMeasure) {
          return _streakAsOperand();
        }
        final aCheck = _validateMeasure(a, source);
        if (aCheck.isErr) return aCheck;
        final bCheck = _validateMeasure(b, source);
        if (bCheck.isErr) return bCheck;
        final aType = a.outputFieldType(source);
        final bType = b.outputFieldType(source);
        if (aType == null ||
            !isNumericFieldType(aType) ||
            bType == null ||
            !isNumericFieldType(bType)) {
          return _incompatibleCombination(
            'Both operands of a calculated measure must be numeric; an '
            'operand produces a non-numeric value.',
          );
        }
        if (combineOutputType(aType, bType, combination) == null) {
          return _incompatibleCombination(
            'These operand types cannot be combined under this '
            'operation; a sum or difference cannot mix a duration with a '
            'non-duration.',
          );
        }
        return const Ok(Unit.value);
    }
  }

  /// Longest root-to-leaf count of expression nodes
  /// ([CalculatedMeasure] / [TransformedMeasure]); a leaf measure is
  /// depth 0.
  static int _expressionDepth(Measure measure) {
    switch (measure) {
      case CountMeasure():
      case FieldMeasure():
      case StreakMeasure():
        return 0;
      case TransformedMeasure(operand: final operand):
        return 1 + _expressionDepth(operand);
      case CalculatedMeasure(operandA: final a, operandB: final b):
        final da = _expressionDepth(a);
        final db = _expressionDepth(b);
        return 1 + (da > db ? da : db);
    }
  }

  static Err<Unit, AnalyticsError> _incompatibleCombination(String message) =>
      Err(
        AnalyticsError(
          kind: AnalyticsErrorKind.incompatibleSeriesCombination,
          humanMessage: message,
        ),
      );

  static Err<Unit, AnalyticsError> _streakAsOperand() => const Err(
    AnalyticsError(
      kind: AnalyticsErrorKind.streakNotCombinable,
      humanMessage:
          'StreakMeasure cannot be an operand of an expression measure. '
          'Streak runs its own pipeline and produces a fixed table shape.',
    ),
  );

  // ──────────────────────────────────────────────────────────────────────
  // Filter
  // ──────────────────────────────────────────────────────────────────────

  static Result<Unit, AnalyticsError> _validateFilter(
    Filter filter,
    SourceDef source,
  ) {
    return _resolveFieldRef(
      filter.fieldRef,
      source,
      refLabel: 'Filter field',
    ).andThen((field) {
      if (!field.filterable) {
        return Err(
          AnalyticsError(
            kind: AnalyticsErrorKind.fieldNotFilterable,
            affectedField: filter.fieldRef,
            humanMessage: 'Field ${field.displayName} is not filterable.',
          ),
        );
      }
      if (!_operatorCompatible(filter.operator, field.fieldType)) {
        return Err(
          AnalyticsError(
            kind: AnalyticsErrorKind.incompatibleOperator,
            affectedField: filter.fieldRef,
            humanMessage:
                'Operator ${filter.operator.name} is not compatible with '
                'field type ${field.fieldType.name}.',
          ),
        );
      }
      return _validateFilterValue(filter, field);
    });
  }

  /// Verifies that `filter.value`'s shape and type agree with the field
  /// type and operator. After this check, the runtime FilterEngine can
  /// dispatch without further type sniffing.
  static Result<Unit, AnalyticsError> _validateFilterValue(
    Filter filter,
    FieldDef field,
  ) {
    final value = filter.value;
    final isList =
        value is StringListValue ||
        value is EnumListValue ||
        value is IntListValue;
    if (filter.operator == FilterOperator.inList) {
      if (!isList) {
        return Err(
          AnalyticsError(
            kind: AnalyticsErrorKind.incompatibleOperator,
            affectedField: filter.fieldRef,
            humanMessage:
                'Operator inList takes a list value; got '
                '${value.runtimeType}.',
          ),
        );
      }
      if (value.fieldType != field.fieldType) {
        return Err(
          AnalyticsError(
            kind: AnalyticsErrorKind.incompatibleOperator,
            affectedField: filter.fieldRef,
            humanMessage:
                'Operator inList element type ${value.fieldType.name} '
                'does not match field type ${field.fieldType.name}.',
          ),
        );
      }
      return const Ok(Unit.value);
    }
    if (isList) {
      return Err(
        AnalyticsError(
          kind: AnalyticsErrorKind.incompatibleOperator,
          affectedField: filter.fieldRef,
          humanMessage:
              'Operator ${filter.operator.name} takes a scalar value; '
              'got a list value. Use `inList` for list-valued filters.',
        ),
      );
    }
    // NullValue is permitted with equals/notEquals (a meaningful
    // "is this field null" check) but not with ordered operators
    // (less-than-null and friends are never meaningful and almost
    // always reflect a builder bug).
    if (value is NullValue) {
      switch (filter.operator) {
        case FilterOperator.lessThan:
        case FilterOperator.lessThanOrEqual:
        case FilterOperator.greaterThan:
        case FilterOperator.greaterThanOrEqual:
          return Err(
            AnalyticsError(
              kind: AnalyticsErrorKind.incompatibleOperator,
              affectedField: filter.fieldRef,
              humanMessage:
                  'Operator ${filter.operator.name} against NullValue is '
                  'never meaningful; use equals/notEquals to test for null.',
            ),
          );
        case FilterOperator.equals:
        case FilterOperator.notEquals:
        case FilterOperator.inList:
          // equals/notEquals: legitimate "is this field null" filter.
          // inList: rejected earlier (NullValue isn't a list-typed value).
          break;
      }
      return const Ok(Unit.value);
    }
    // For non-null scalar values, require the TypedValue subtype to
    // match the field type.
    if (value.fieldType != field.fieldType) {
      return Err(
        AnalyticsError(
          kind: AnalyticsErrorKind.incompatibleOperator,
          affectedField: filter.fieldRef,
          humanMessage:
              'Filter value type ${value.fieldType.name} does not match '
              'field type ${field.fieldType.name}.',
        ),
      );
    }
    return const Ok(Unit.value);
  }

  // ──────────────────────────────────────────────────────────────────────
  // GroupBy
  // ──────────────────────────────────────────────────────────────────────

  static Result<Unit, AnalyticsError> _validateGroupBy(
    GroupBy groupBy,
    SourceDef source,
  ) {
    // Streak+groupBys rejection (with `streakWithExplicitGrouping`)
    // happens at the top of `validateQuery`: streak measures are
    // identified at the measures-list level, not per-call. By the
    // time this helper runs, no streak measure remains in the query.
    switch (groupBy) {
      case FieldGroupBy(fieldRef: final ref):
        return _resolveFieldRef(
          ref,
          source,
          refLabel: 'Group-by field',
        ).andThen((field) {
          if (!field.groupable) {
            return Err(
              AnalyticsError(
                kind: AnalyticsErrorKind.fieldNotGroupable,
                affectedField: ref,
                humanMessage: 'Field ${field.displayName} is not groupable.',
              ),
            );
          }
          // dateTime fields require explicit temporal grouping. Allowing
          // FieldGroupBy here silently bucketizes by day, which is a
          // hidden behavior; force callers to use TimeGroupBy.
          if (field.fieldType == FieldType.dateTime) {
            return Err(
              AnalyticsError(
                kind: AnalyticsErrorKind.preconditionViolation,
                affectedField: ref,
                humanMessage:
                    'FieldGroupBy on a dateTime field is not supported. '
                    'Use TimeGroupBy(grain: TimeGrain.day) for explicit '
                    'day-bucket grouping (or another grain).',
              ),
            );
          }
          return const Ok(Unit.value);
        });

      case TimeGroupBy(dateFieldRef: final ref, grain: final _):
        return _resolveFieldRef(
          ref,
          source,
          refLabel: 'TimeGroupBy field',
        ).andThen((field) {
          if (field.fieldType != FieldType.dateTime) {
            return Err(
              AnalyticsError(
                kind: AnalyticsErrorKind.timeGrainOnNonDateField,
                affectedField: ref,
                humanMessage:
                    'TimeGroupBy requires a dateTime field; '
                    '${field.displayName} is ${field.fieldType.name}.',
              ),
            );
          }
          return const Ok(Unit.value);
        });
    }
  }

  // ──────────────────────────────────────────────────────────────────────
  // Sort
  // ──────────────────────────────────────────────────────────────────────

  static Result<Unit, AnalyticsError> _validateSort(
    Sort sort,
    List<GroupBy> groupBys,
    List<Measure> measures,
    SourceDef source,
  ) {
    switch (sort.target) {
      case GroupFieldSort(fieldRef: final ref):
        if (groupBys.isEmpty) {
          return const Err(
            AnalyticsError(
              kind: AnalyticsErrorKind.incompatibleSortTarget,
              humanMessage:
                  'GroupFieldSort is only valid when at least one group-by '
                  'is set.',
            ),
          );
        }
        return _resolveFieldRef(
          ref,
          source,
          mismatchKind: AnalyticsErrorKind.incompatibleSortTarget,
          refLabel: 'Sort field',
        ).andThen((field) {
          if (!field.sortable) {
            return Err(
              AnalyticsError(
                kind: AnalyticsErrorKind.incompatibleSortTarget,
                affectedField: ref,
                humanMessage: 'Field ${field.displayName} is not sortable.',
              ),
            );
          }
          // The sort must target one of the group-by fields.
          final matches = groupBys.any(
            (g) => switch (g) {
              FieldGroupBy(fieldRef: final gRef) => gRef == ref,
              TimeGroupBy(dateFieldRef: final gRef) => gRef == ref,
            },
          );
          if (!matches) {
            return Err(
              AnalyticsError(
                kind: AnalyticsErrorKind.incompatibleSortTarget,
                affectedField: ref,
                humanMessage:
                    'Group-field sort must target one of the group-by '
                    'fields. Sort field is ${ref.fieldId}; group-by '
                    'fields do not include it.',
              ),
            );
          }
          return const Ok(Unit.value);
        });

      case MeasureValueSort(measureLabel: final label):
        if (groupBys.isEmpty) {
          return const Err(
            AnalyticsError(
              kind: AnalyticsErrorKind.incompatibleSortTarget,
              humanMessage:
                  'MeasureValueSort is only valid when at least one '
                  'group-by is set.',
            ),
          );
        }
        // Multi-measure queries require an explicit `measureLabel` to
        // pick which measure to sort by. Single-measure queries can
        // leave it null — the sort targets the only measure.
        if (measures.length > 1 && label == null) {
          return const Err(
            AnalyticsError(
              kind: AnalyticsErrorKind.preconditionViolation,
              humanMessage:
                  'MeasureValueSort.measureLabel is required for '
                  'multi-measure queries. Set it to the effective label '
                  '(explicit `Measure.label` or auto-generated '
                  '`measure_<index>`) of the measure to sort by.',
            ),
          );
        }
        // Non-null labels must resolve to one of the measures'
        // effective labels.
        if (label != null) {
          final effective = Measure.effectiveLabelsFor(measures);
          if (!effective.contains(label)) {
            return Err(
              AnalyticsError(
                kind: AnalyticsErrorKind.unknownMeasureLabel,
                humanMessage:
                    'MeasureValueSort.measureLabel "$label" does not '
                    'match any measure on this query. Effective labels: '
                    '${effective.join(", ")}.',
              ),
            );
          }
        }
        return const Ok(Unit.value);
    }
  }

  // ──────────────────────────────────────────────────────────────────────
  // HAVING clause
  // ──────────────────────────────────────────────────────────────────────

  /// Validates a `HavingClause` in the context of the enclosing
  /// query. Three rules apply:
  ///
  /// 1. The enclosing query must have a group-by (a scalar query has
  ///    no buckets to filter — fires `havingRequiresGrouping`).
  /// 2. The threshold's [FieldType] must match the measure's
  ///    inferred output type — fires `incompatibleOperator` on
  ///    mismatch, matching how filter-value type mismatches are
  ///    signaled.
  /// 3. If [HavingClause.measureLabel] is non-null, it must resolve
  ///    to one of the query's measures by effective label
  ///    (`Measure.label` if non-null, otherwise the auto-generated
  ///    `'measure_<index>'`). A null label is allowed on
  ///    single-measure queries (it implicitly targets the sole
  ///    measure); on multi-measure queries the validator separately
  ///    rejects null labels as ambiguous.
  static Result<Unit, AnalyticsError> _validateHaving(
    HavingClause having,
    AnalyticsQuerySpec query,
    SourceDef source,
  ) {
    // Rule 1: HAVING requires at least one group-by.
    if (query.groupBys.isEmpty) {
      return const Err(
        AnalyticsError(
          kind: AnalyticsErrorKind.havingRequiresGrouping,
          humanMessage:
              'HAVING requires at least one group-by clause; a scalar '
              'query has no buckets for HAVING to filter.',
        ),
      );
    }

    // Rule 3 (placed before rule 2 because if the label doesn't
    // resolve there's nothing to type-check against): resolve the
    // measure HAVING targets.
    final Measure targetMeasure;
    if (having.measureLabel == null) {
      // Null label: only valid in single-measure queries. Multi-
      // measure queries require an explicit label.
      if (query.measures.length > 1) {
        return const Err(
          AnalyticsError(
            kind: AnalyticsErrorKind.preconditionViolation,
            humanMessage:
                'HavingClause.measureLabel is required for multi-measure '
                'queries. Set it to the effective label (explicit '
                '`Measure.label` or auto-generated `measure_<index>`) '
                'of the measure to filter by.',
          ),
        );
      }
      targetMeasure = query.measures.single;
    } else {
      // Non-null label: resolve against effective labels.
      final effective = Measure.effectiveLabelsFor(query.measures);
      final idx = effective.indexOf(having.measureLabel!);
      if (idx < 0) {
        return Err(
          AnalyticsError(
            kind: AnalyticsErrorKind.unknownMeasureLabel,
            humanMessage:
                'HavingClause.measureLabel "${having.measureLabel}" does '
                'not match any measure on this query. Effective labels: '
                '${effective.join(", ")}.',
          ),
        );
      }
      targetMeasure = query.measures[idx];
    }

    // Rule 2: threshold type must match the target measure's output type.
    final outputType = targetMeasure.outputFieldType(source);
    if (outputType == null) {
      // The measure is `StreakMeasure`, which doesn't produce a
      // single TypedValue per bucket. The validator's streak
      // pre-checks (at the top of validateQuery) already reject
      // HAVING on streak queries with a clearer message, so this
      // branch is unreachable in practice. Defensive throw for
      // future-proofing.
      throw StateError(
        'QueryValidator._validateHaving: measure has no scalar output '
        'type (StreakMeasure?); the streak pre-checks should have '
        'rejected this query upstream.',
      );
    }
    if (having.threshold is NullValue) {
      // NullValue thresholds against ordered operators are not
      // meaningful — `value > null` is always false. The user almost
      // certainly meant something else. Mirrors the corresponding
      // rule in `_validateFilterValue` for ordered filter operators
      // against NullValue.
      return const Err(
        AnalyticsError(
          kind: AnalyticsErrorKind.incompatibleOperator,
          humanMessage:
              'HAVING threshold must be a non-null typed value. Use a '
              'specific threshold; null is never meaningful as a '
              'threshold.',
        ),
      );
    }
    if (having.threshold.fieldType != outputType) {
      return Err(
        AnalyticsError(
          kind: AnalyticsErrorKind.incompatibleOperator,
          humanMessage:
              'HAVING threshold type ${having.threshold.fieldType.name} '
              'does not match the measure\'s output type ${outputType.name}.',
        ),
      );
    }

    return const Ok(Unit.value);
  }

  // ──────────────────────────────────────────────────────────────────────
  // Derived operation
  // ──────────────────────────────────────────────────────────────────────

  static Result<Unit, AnalyticsError> _validateDerivedOperation(
    DerivedOperation op,
    Measure? measure,
    SourceDef source,
  ) {
    // Parameter checks first.
    switch (op) {
      case NoDerivedOp():
        return const Ok(Unit.value);
      case MovingAverageOp(window: final window):
        if (window <= 0) {
          return Err(
            AnalyticsError(
              kind: AnalyticsErrorKind.invalidDerivedOperationParameter,
              humanMessage: 'MovingAverageOp.window must be > 0; got $window.',
            ),
          );
        }
        break;
      case CumulativeSumOp():
      case DeltaOp():
        break;
    }

    // Numeric-measure requirement: derived ops are only meaningful
    // over measures whose output is numeric. When [measure] is null,
    // the caller has already determined the query is multi-measure
    // and rejected derivedOp upstream — reaching here would be a bug,
    // but defensively skip the numeric check.
    if (measure == null) {
      // Unreachable: caller guarantees a non-null measure for any
      // non-NoDerivedOp op, but defensively skip rather than crash.
      return const Ok(Unit.value);
    }
    if (!_measureProducesNumericOutput(measure, source)) {
      return const Err(
        AnalyticsError(
          kind: AnalyticsErrorKind.derivedOpRequiresNumericMeasure,
          humanMessage:
              'Derived operations require a measure whose output is '
              'numeric. min/max on a dateTime field produces a '
              'DateTimeValue, which is not numeric.',
        ),
      );
    }
    return const Ok(Unit.value);
  }

  /// Whether [measure]'s output `TypedValue` subtype is numeric- or
  /// duration-shaped — the precondition for derived operations
  /// (cumulative sum, delta, moving average), which all do
  /// arithmetic on the bucket values.
  ///
  /// Output by subtype:
  ///
  /// - `CountMeasure` → always numeric (`IntValue`).
  /// - `FieldMeasure` → numeric except when it's `min`/`max` on a
  ///   `dateTime` field (returns `DateTimeValue`).
  /// - `StreakMeasure` → false. The executor never applies derived
  ///   ops to streak results anyway (validator rejects `groupBys`
  ///   with streak elsewhere).
  ///
  /// Delegates to [Measure.outputFieldType] for the per-measure
  /// output-type table — keeping that table in one place (the
  /// `Measure` family) ensures this check and the HAVING-threshold
  /// type check don't drift apart.
  static bool _measureProducesNumericOutput(Measure measure, SourceDef source) {
    final outputType = measure.outputFieldType(source);
    if (outputType == null) return false; // StreakMeasure
    return outputType == FieldType.integer ||
        outputType == FieldType.double ||
        outputType == FieldType.duration;
  }

  // ──────────────────────────────────────────────────────────────────────
  // Date-range cross rule
  // ──────────────────────────────────────────────────────────────────────

  static Result<Unit, AnalyticsError> _validateDateRangeCrossRule(
    Measure measure,
    DateRangeMode mode,
  ) {
    final measureSupports = measure.supportsDateRange;
    final modeIsNo = mode is NoDateRange;

    if (measureSupports && modeIsNo) {
      return const Err(
        AnalyticsError(
          kind: AnalyticsErrorKind.dateRangeRequiredForMeasure,
          humanMessage:
              'This measure supports a date range, but the widget '
              'mode is NoDateRange.',
        ),
      );
    }
    if (!measureSupports && !modeIsNo) {
      return const Err(
        AnalyticsError(
          kind: AnalyticsErrorKind.dateRangeNotSupportedForMeasure,
          humanMessage:
              'This measure does not support a date range, but the '
              'widget mode applies one.',
        ),
      );
    }
    return const Ok(Unit.value);
  }

  // ──────────────────────────────────────────────────────────────────────
  // Paired query alignability
  // ──────────────────────────────────────────────────────────────────────

  static Result<Unit, AnalyticsError> _validateAlignability(
    AnalyticsQuerySpec x,
    AnalyticsQuerySpec y,
    List<SourceDef> sources,
  ) {
    // Same-source paired queries are alignable iff their `groupBys`
    // shape produces the same bucket-key space. `GroupBy` subclasses
    // have value equality defined, so a single element-wise comparison
    // covers every case. (At this point both halves have already been
    // proven to infer to `series`, which means exactly one group-by
    // per half.)
    if (x.source == y.source) {
      if (listEqualsByValue(x.groupBys, y.groupBys)) {
        return const Ok(Unit.value);
      }
      return const Err(
        AnalyticsError(
          kind: AnalyticsErrorKind.incompatiblePairedQueryShapes,
          humanMessage:
              'Same-source paired queries must use the same groupBys '
              'shape so their results share an x-axis.',
        ),
      );
    }

    // Cross-source: both must use TimeGroupBy with matching grain, and
    // both sources must declare a primary date field. The series-shape
    // precondition guarantees groupBys is length 1 on both halves.
    final xGroup = x.groupBys.first;
    final yGroup = y.groupBys.first;
    if (xGroup is! TimeGroupBy || yGroup is! TimeGroupBy) {
      return const Err(
        AnalyticsError(
          kind: AnalyticsErrorKind.incompatiblePairedQueryShapes,
          humanMessage:
              'Cross-source paired queries must both use TimeGroupBy.',
        ),
      );
    }
    if (xGroup.grain != yGroup.grain) {
      return Err(
        AnalyticsError(
          kind: AnalyticsErrorKind.incompatiblePairedQueryShapes,
          humanMessage:
              'Cross-source paired queries must use the same TimeGrain. '
              'X uses ${xGroup.grain}; Y uses ${yGroup.grain}.',
        ),
      );
    }

    final xSource = findSourceById(sources, x.source);
    final ySource = findSourceById(sources, y.source);
    if (xSource == null || ySource == null) {
      // Unreachable: `validateQuery` ran for both halves already and
      // would have caught any unknown source. Surface this branch
      // loudly rather than returning the catch-all `unexpected` kind
      // (which `errors.dart` documents the validator as never
      // producing).
      throw StateError(
        'QueryValidator._validateAlignability: cross-source paired '
        'query reached alignability checks with an unknown source — '
        'the per-query validateQuery step should have caught this.',
      );
    }

    final xPrimary = xSource.primaryDateField;
    final yPrimary = ySource.primaryDateField;
    if (xPrimary == null ||
        yPrimary == null ||
        xPrimary.fieldType != FieldType.dateTime ||
        yPrimary.fieldType != FieldType.dateTime) {
      return const Err(
        AnalyticsError(
          kind: AnalyticsErrorKind.primaryDateFieldRequiredForOperation,
          humanMessage:
              'Cross-source paired queries require both sources to '
              'declare a dateTime primary date field.',
        ),
      );
    }
    return const Ok(Unit.value);
  }

  // ──────────────────────────────────────────────────────────────────────
  // FieldAggregation parameter validation
  // ──────────────────────────────────────────────────────────────────────

  /// Validates per-variant parameters carried by [FieldAggregation]
  /// members. Parameterless members return `Ok` immediately;
  /// parameterized members range-check their parameter and return an
  /// `Err(invalidAggregationParameter)` on violation. Mirrors the way
  /// `MovingAverageOp`'s `window` is range-checked at validation
  /// time rather than at construction.
  static Result<Unit, AnalyticsError> _validateAggregationParameters(
    FieldAggregation agg,
    FieldRef ref,
  ) {
    switch (agg) {
      case SumAgg():
      case AverageAgg():
      case MinAgg():
      case MaxAgg():
      case DistinctCountAgg():
        return const Ok(Unit.value);
      case PercentileAgg(p: final p):
        if (p < 0 || p > 1 || p.isNaN) {
          return Err(
            AnalyticsError(
              kind: AnalyticsErrorKind.invalidAggregationParameter,
              affectedField: ref,
              humanMessage: 'PercentileAgg.p must be in [0, 1]; got $p.',
            ),
          );
        }
        return const Ok(Unit.value);
    }
  }

  /// Stable user-facing name for an aggregation. Used by validator
  /// error messages so we don't depend on `runtimeType.toString()`
  /// (which can produce mangled names under tree-shaking).
  static String _aggregationName(FieldAggregation agg) {
    switch (agg) {
      case SumAgg():
        return 'sum';
      case AverageAgg():
        return 'average';
      case MinAgg():
        return 'min';
      case MaxAgg():
        return 'max';
      case DistinctCountAgg():
        return 'distinctCount';
      case PercentileAgg(p: final p):
        return 'percentile(p: $p)';
    }
  }

  // ──────────────────────────────────────────────────────────────────────
  // Operator × FieldType compatibility table
  // ──────────────────────────────────────────────────────────────────────

  static bool _operatorCompatible(FilterOperator op, FieldType type) {
    switch (op) {
      case FilterOperator.equals:
      case FilterOperator.notEquals:
        // All field types support equality.
        return true;
      case FilterOperator.lessThan:
      case FilterOperator.lessThanOrEqual:
      case FilterOperator.greaterThan:
      case FilterOperator.greaterThanOrEqual:
        return type == FieldType.integer ||
            type == FieldType.double ||
            type == FieldType.duration ||
            type == FieldType.dateTime;
      case FilterOperator.inList:
        // Restricted to types with a typed list shape in TypedValue.
        return type == FieldType.string ||
            type == FieldType.enumeration ||
            type == FieldType.integer;
    }
  }

  // ──────────────────────────────────────────────────────────────────────
  // Helpers
  // ──────────────────────────────────────────────────────────────────────

  /// Looks up a `FieldRef`'s `FieldDef` on a source, asserting that
  /// the ref points to this source. Returns `Err` for either:
  ///
  /// * Wrong source — `ref.sourceId != source.sourceId`. The error
  ///   uses [mismatchKind] (default: `unknownField`; the sort path
  ///   uses `incompatibleSortTarget`).
  /// * Missing field — the source has no `FieldDef` with this id.
  ///   Always reported as `unknownField`.
  ///
  /// The optional [refLabel] customizes the human message for sites
  /// where calling it "Field" would be misleading (e.g. group-by /
  /// sort / filter fields).
  static Result<FieldDef, AnalyticsError> _resolveFieldRef(
    FieldRef ref,
    SourceDef source, {
    AnalyticsErrorKind mismatchKind = AnalyticsErrorKind.unknownField,
    String refLabel = 'Field',
  }) {
    if (ref.sourceId != source.sourceId) {
      return Err(
        AnalyticsError(
          kind: mismatchKind,
          affectedField: ref,
          humanMessage:
              '$refLabel ${ref.fieldId} references source ${ref.sourceId} '
              'but the query is on source ${source.sourceId}.',
        ),
      );
    }
    final field = source.fieldById(ref.fieldId);
    if (field == null) {
      return Err(
        AnalyticsError(
          kind: AnalyticsErrorKind.unknownField,
          affectedField: ref,
          humanMessage: 'Unknown field: ${ref.fieldId} on ${ref.sourceId}.',
        ),
      );
    }
    return Ok(field);
  }

  /// Returns true iff [a] and [b] describe the exact same bucketing —
  /// same field and (for time groupings) same grain. Used by the
  /// groupBy-distinctness check that walks every pair of entries in
  /// `query.groupBys` and rejects any two that target the same
  /// dimension.
  ///
  /// Same-field-different-grain (e.g. day vs. month over the same
  /// date field) returns false — that pairing is legitimate.
  static bool _groupBysAreEquivalent(GroupBy a, GroupBy b) {
    return switch ((a, b)) {
      (FieldGroupBy(fieldRef: final ar), FieldGroupBy(fieldRef: final br)) =>
        ar == br,
      (
        TimeGroupBy(dateFieldRef: final ar, grain: final ag),
        TimeGroupBy(dateFieldRef: final br, grain: final bg),
      ) =>
        ar == br && ag == bg,
      _ => false,
    };
  }
}
