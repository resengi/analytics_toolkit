import 'dart:convert';

import 'display_spec.dart';
import 'query/measure.dart';
import 'query/query_components.dart';
import 'query/query_enums.dart';
import 'query/query_spec.dart';
import 'schema/schema.dart';
import 'schema/typed_value.dart';
import 'time_series/date_range.dart';
import 'time_series/time_grain.dart';
import 'widget_spec.dart';

/// Reader and writer for the persisted JSON payloads on
/// `AnalyticsWidgetSpec`.
///
/// All sealed shapes use a `kind` discriminator as the first key. The
/// reader and writer in this file are inverses: `decode(encode(x)) ==
/// x` for every supported shape.
///
/// This is the only place in the package that knows the JSON shape of
/// the persisted payloads. Consumers call `decode*` to read and
/// `encode*` to write. Adding a new sealed case (e.g. a new `Measure`
/// family member) means updating this codec and any consumer
/// round-trip tests, and nothing else downstream.
///
/// ## Schema version
///
/// `AnalyticsWidgetSpec.schemaVersion` is enforced via
/// [ensureCanDecode]: callers should invoke it on a freshly-loaded
/// spec before decoding any of its inner JSON blobs. This guards
/// against attempting to read v2 specs with a v1 codec.
abstract class WidgetPayloadCodec {
  /// The maximum schema version this codec can decode.
  ///
  /// Persisted specs with `schemaVersion > currentSchemaVersion` are
  /// rejected by [ensureCanDecode] at decode time. No automatic
  /// migrations are implemented; this constant and
  /// [validateSchemaVersion] reserve the seam for when a second
  /// schema shape ships. At that point, a `migrate(json, fromVersion)`
  /// hook would slot in here.
  static const int currentSchemaVersion = 1;

  /// Verifies that [spec] was written by a codec compatible with this
  /// one — i.e. that `spec.schemaVersion <= currentSchemaVersion`.
  ///
  /// Callers should invoke this immediately after loading a spec from
  /// storage, before calling any of the `decode*` methods on its
  /// inner JSON blobs. Throws [FormatException] for a too-new spec;
  /// callers should catch and convert to a typed user-visible error
  /// state (e.g. "This widget was saved by a newer app version").
  static void ensureCanDecode(AnalyticsWidgetSpec spec) {
    validateSchemaVersion(spec.schemaVersion);
  }

  /// Rejects persisted specs from a newer schema version than this
  /// codec supports. Older or absent versions (treated as v1) are
  /// accepted — per-payload backward compatibility is handled by the
  /// tolerant decoders below.
  ///
  /// Most callers want [ensureCanDecode] (which takes a spec
  /// directly) rather than this low-level version-only check.
  ///
  /// Throws [FormatException] on a too-new version; callers should
  /// catch and convert to a typed user-visible error state.
  static void validateSchemaVersion(int version) {
    if (version > currentSchemaVersion) {
      throw FormatException(
        'Widget schemaVersion $version is newer than this codec '
        'supports (max $currentSchemaVersion). The widget was likely '
        'saved by a newer version of the application.',
      );
    }
  }

  // ── QueryPayload ──────────────────────────────────────────────────────

  static String encodeQueryPayload(QueryPayload payload) {
    return jsonEncode(_queryPayloadToJson(payload));
  }

  static QueryPayload decodeQueryPayload(String text) {
    final json = _decodeJsonObject(text);
    return _queryPayloadFromJson(json);
  }

  static Map<String, dynamic> _queryPayloadToJson(QueryPayload payload) {
    switch (payload) {
      case SingleQuerySpec(query: final q):
        return {'kind': 'single', 'query': _querySpecToJson(q)};
      case PairedQuerySpec(xQuery: final x, yQuery: final y):
        return {
          'kind': 'paired',
          'xQuery': _querySpecToJson(x),
          'yQuery': _querySpecToJson(y),
        };
    }
  }

  static QueryPayload _queryPayloadFromJson(Map<String, dynamic> json) {
    final kind = _optionalString(json, 'kind');
    switch (kind) {
      case 'single':
        return SingleQuerySpec(
          query: _querySpecFromJson(_requireMap(json, 'query')),
        );
      case 'paired':
        return PairedQuerySpec(
          xQuery: _querySpecFromJson(_requireMap(json, 'xQuery')),
          yQuery: _querySpecFromJson(_requireMap(json, 'yQuery')),
        );
      default:
        throw FormatException('Unknown QueryPayload kind: $kind');
    }
  }

  // ── AnalyticsQuerySpec ────────────────────────────────────────────────

  static Map<String, dynamic> _querySpecToJson(AnalyticsQuerySpec query) {
    return {
      'source': query.source,
      // Always emit `measures` as an array, even for single-measure
      // queries (which are the bulk of dashboard traffic). Consumers
      // parsing JSON should expect a `measures` array on every spec.
      'measures': [for (final m in query.measures) _measureToJson(m)],
      'filters': [for (final f in query.filters) _filterToJson(f)],
      // Always emit `groupBys`, even when empty — a list is a list.
      // Consumers parsing JSON should expect this key on every spec.
      'groupBys': [for (final g in query.groupBys) _groupByToJson(g)],
      if (query.having != null) 'having': _havingClauseToJson(query.having!),
      if (query.sort != null) 'sort': _sortToJson(query.sort!),
      if (query.limit != null) 'limit': query.limit,
      'derivedOperation': _derivedOpToJson(query.derivedOperation),
    };
  }

  static AnalyticsQuerySpec _querySpecFromJson(Map<String, dynamic> json) {
    return AnalyticsQuerySpec(
      source: _requireString(json, 'source'),
      // `measures` is required and non-empty per the validator; the
      // decoder mirrors that — a missing or empty `measures` key in
      // the JSON would produce an empty list here, which the validator
      // rejects with `measuresEmpty` at validation time.
      measures: [
        for (final m in (_optionalList(json, 'measures') ?? const []))
          _measureFromJson(_asMap(m)),
      ],
      filters: [
        for (final f in (_optionalList(json, 'filters') ?? const []))
          _filterFromJson(_asMap(f)),
      ],
      groupBys: [
        for (final g in (_optionalList(json, 'groupBys') ?? const []))
          _groupByFromJson(_asMap(g)),
      ],
      having: json['having'] == null
          ? null
          : _havingClauseFromJson(_requireMap(json, 'having')),
      sort: json['sort'] == null
          ? null
          : _sortFromJson(_requireMap(json, 'sort')),
      limit: _optionalInt(json, 'limit'),
      derivedOperation: json['derivedOperation'] == null
          ? const NoDerivedOp()
          : _derivedOpFromJson(_requireMap(json, 'derivedOperation')),
    );
  }

  // ── Measure ───────────────────────────────────────────────────────────

  static Map<String, dynamic> _measureToJson(Measure measure) {
    // Every measure carries an optional `label`. Encoded only when
    // non-null, so single-measure queries (where the default
    // auto-label is usually fine) keep payloads minimal.
    switch (measure) {
      case CountMeasure():
        return {
          'kind': 'count',
          if (measure.label != null) 'label': measure.label,
        };
      case FieldMeasure(fieldRef: final ref, aggregation: final agg):
        return {
          'kind': 'field',
          'fieldRef': _fieldRefToJson(ref),
          'aggregation': _fieldAggregationToJson(agg),
          if (measure.label != null) 'label': measure.label,
        };
      case StreakMeasure(
        entityIdField: final entityId,
        scheduledDateField: final scheduled,
        statusField: final status,
        completedStatusValue: final completed,
        entityLabelField: final entityLabel,
        topN: final topN,
      ):
        return {
          'kind': 'streak',
          'entityIdField': _fieldRefToJson(entityId),
          'scheduledDateField': _fieldRefToJson(scheduled),
          'statusField': _fieldRefToJson(status),
          'completedStatusValue': completed,
          // Both optional — omitted when null so encoded payloads stay
          // minimal.
          if (entityLabel != null)
            'entityLabelField': _fieldRefToJson(entityLabel),
          'topN': ?topN,
          if (measure.label != null) 'label': measure.label,
        };
      case TransformedMeasure(operand: final operand, op: final op):
        return {
          'kind': 'transformed',
          'op': _scalarOpToJson(op),
          'operand': _measureToJson(operand),
          if (measure.label != null) 'label': measure.label,
        };
      case CalculatedMeasure(
        operandA: final a,
        operandB: final b,
        combination: final combination,
      ):
        return {
          'kind': 'calculated',
          'combination': _seriesCombinationToJson(combination),
          'operandA': _measureToJson(a),
          'operandB': _measureToJson(b),
          if (measure.label != null) 'label': measure.label,
        };
    }
  }

  static Measure _measureFromJson(Map<String, dynamic> json) {
    final kind = _optionalString(json, 'kind');
    // Optional label — when omitted, the validator/executor will use
    // the auto-generated `'measure_<index>'` rule.
    final label = _optionalString(json, 'label');
    switch (kind) {
      case 'count':
        return CountMeasure(label: label);
      case 'field':
        return FieldMeasure(
          fieldRef: _fieldRefFromJson(_requireMap(json, 'fieldRef')),
          aggregation: _fieldAggregationFromJson(
            _requireMap(json, 'aggregation'),
          ),
          label: label,
        );
      case 'streak':
        return StreakMeasure(
          entityIdField: _fieldRefFromJson(_requireMap(json, 'entityIdField')),
          scheduledDateField: _fieldRefFromJson(
            _requireMap(json, 'scheduledDateField'),
          ),
          statusField: _fieldRefFromJson(_requireMap(json, 'statusField')),
          completedStatusValue: _requireString(json, 'completedStatusValue'),
          entityLabelField: json['entityLabelField'] == null
              ? null
              : _fieldRefFromJson(_requireMap(json, 'entityLabelField')),
          topN: _optionalInt(json, 'topN'),
          label: label,
        );
      case 'transformed':
        return TransformedMeasure(
          operand: _measureFromJson(_requireMap(json, 'operand')),
          op: _scalarOpFromJson(_requireMap(json, 'op')),
          label: label,
        );
      case 'calculated':
        return CalculatedMeasure(
          operandA: _measureFromJson(_requireMap(json, 'operandA')),
          operandB: _measureFromJson(_requireMap(json, 'operandB')),
          combination: _seriesCombinationFromJson(
            _requireString(json, 'combination'),
          ),
          label: label,
        );
      default:
        throw FormatException('Unknown Measure kind: $kind');
    }
  }

  // ── ScalarOp / SeriesCombination ──────────────────────────────────────

  /// Encodes a [ScalarOp] inline within its [TransformedMeasure]: a
  /// `kind` discriminator, plus `fill` for [FillNullOp].
  static Map<String, dynamic> _scalarOpToJson(ScalarOp op) {
    switch (op) {
      case NegateOp():
        return {'kind': 'negate'};
      case AbsOp():
        return {'kind': 'abs'};
      case FillNullOp(fill: final fill):
        return {'kind': 'fillNull', 'fill': fill};
    }
  }

  static ScalarOp _scalarOpFromJson(Map<String, dynamic> json) {
    final kind = _optionalString(json, 'kind');
    switch (kind) {
      case 'negate':
        return const NegateOp();
      case 'abs':
        return const AbsOp();
      case 'fillNull':
        return FillNullOp(_requireNum(json, 'fill'));
      default:
        throw FormatException('Unknown ScalarOp kind: $kind');
    }
  }

  /// Encodes a [SeriesCombination] as a single `kind` tag, stored inline
  /// within its [CalculatedMeasure].
  static String _seriesCombinationToJson(SeriesCombination combination) {
    switch (combination) {
      case SumCombination():
        return 'sum';
      case DifferenceCombination():
        return 'difference';
      case ProductCombination():
        return 'product';
      case RatioCombination():
        return 'ratio';
    }
  }

  static SeriesCombination _seriesCombinationFromJson(String tag) {
    switch (tag) {
      case 'sum':
        return const SumCombination();
      case 'difference':
        return const DifferenceCombination();
      case 'product':
        return const ProductCombination();
      case 'ratio':
        return const RatioCombination();
      default:
        throw FormatException('Unknown SeriesCombination tag: $tag');
    }
  }

  // ── FieldAggregation ──────────────────────────────────────────────────

  /// Encodes a [FieldAggregation] as a discriminated object: `kind`
  /// selects the variant, and per-variant fields (currently only `p`
  /// for `PercentileAgg`) follow. This matches the encoding pattern
  /// used elsewhere for sealed families with parameterized members
  /// — see `_derivedOpToJson` for `DerivedOperation`.
  static Map<String, dynamic> _fieldAggregationToJson(FieldAggregation agg) {
    switch (agg) {
      case SumAgg():
        return {'kind': 'sum'};
      case AverageAgg():
        return {'kind': 'average'};
      case MinAgg():
        return {'kind': 'min'};
      case MaxAgg():
        return {'kind': 'max'};
      case DistinctCountAgg():
        return {'kind': 'distinctCount'};
      case PercentileAgg(p: final p):
        return {'kind': 'percentile', 'p': p};
    }
  }

  static FieldAggregation _fieldAggregationFromJson(Map<String, dynamic> json) {
    final kind = _optionalString(json, 'kind');
    switch (kind) {
      case 'sum':
        return const SumAgg();
      case 'average':
        return const AverageAgg();
      case 'min':
        return const MinAgg();
      case 'max':
        return const MaxAgg();
      case 'distinctCount':
        return const DistinctCountAgg();
      case 'percentile':
        return PercentileAgg(p: _requireDouble(json, 'p'));
      default:
        throw FormatException('Unknown FieldAggregation kind: $kind');
    }
  }

  // ── Filter / GroupBy / Sort / DerivedOperation ────────────────────────

  static Map<String, dynamic> _filterToJson(Filter filter) {
    return {
      'fieldRef': _fieldRefToJson(filter.fieldRef),
      'operator': filter.operator.name,
      'value': _typedValueToJson(filter.value),
    };
  }

  static Filter _filterFromJson(Map<String, dynamic> json) {
    return Filter(
      fieldRef: _fieldRefFromJson(_requireMap(json, 'fieldRef')),
      operator: _enumFromName(FilterOperator.values, json['operator']),
      value: _typedValueFromJson(_requireMap(json, 'value')),
    );
  }

  // ── HavingClause ──────────────────────────────────────────────────────

  /// Encodes a [HavingClause] as a flat JSON object. `HavingClause`
  /// is a single concrete class rather than a sealed family, so no
  /// `kind` discriminator is needed — the field layout is fixed.
  /// The optional `measureLabel` is omitted from the output when
  /// null, keeping encoded payloads minimal (mirrors how the
  /// `StreakMeasure` codec handles `entityLabelField`).
  static Map<String, dynamic> _havingClauseToJson(HavingClause having) {
    return {
      'operator': having.operator.name,
      'threshold': _typedValueToJson(having.threshold),
      if (having.measureLabel != null) 'measureLabel': having.measureLabel,
    };
  }

  static HavingClause _havingClauseFromJson(Map<String, dynamic> json) {
    return HavingClause(
      operator: _enumFromName(HavingOperator.values, json['operator']),
      threshold: _typedValueFromJson(_requireMap(json, 'threshold')),
      measureLabel: _optionalString(json, 'measureLabel'),
    );
  }

  static Map<String, dynamic> _groupByToJson(GroupBy groupBy) {
    switch (groupBy) {
      case FieldGroupBy(fieldRef: final ref, label: final label):
        return {
          'kind': 'field',
          'fieldRef': _fieldRefToJson(ref),
          'label': ?label,
        };
      case TimeGroupBy(
        dateFieldRef: final ref,
        grain: final grain,
        label: final label,
      ):
        return {
          'kind': 'time',
          'dateFieldRef': _fieldRefToJson(ref),
          'grain': _timeGrainToJson(grain),
          'label': ?label,
        };
    }
  }

  static GroupBy _groupByFromJson(Map<String, dynamic> json) {
    final kind = _optionalString(json, 'kind');
    switch (kind) {
      case 'field':
        return FieldGroupBy(
          fieldRef: _fieldRefFromJson(_requireMap(json, 'fieldRef')),
          label: _optionalString(json, 'label'),
        );
      case 'time':
        return TimeGroupBy(
          dateFieldRef: _fieldRefFromJson(_requireMap(json, 'dateFieldRef')),
          grain: _timeGrainFromJson(_requireMap(json, 'grain')),
          label: _optionalString(json, 'label'),
        );
      default:
        throw FormatException('Unknown GroupBy kind: $kind');
    }
  }

  /// JSON shape: `{count: N, unit: 'day', anchor: iso8601, weekStartDay?: N}`.
  ///
  /// `anchor` is always emitted; `weekStartDay` is emitted only when
  /// non-null.
  static Map<String, dynamic> _timeGrainToJson(TimeGrain grain) {
    return {
      'count': grain.count,
      'unit': grain.unit.name,
      'anchor': grain.anchor.toIso8601String(),
      if (grain.weekStartDay != null) 'weekStartDay': grain.weekStartDay,
    };
  }

  static TimeGrain _timeGrainFromJson(Map<String, dynamic> json) {
    return TimeGrain(
      count: _requireInt(json, 'count'),
      unit: _enumFromName(TimeUnit.values, json['unit']),
      anchor: DateTime.parse(_requireString(json, 'anchor')),
      weekStartDay: _optionalInt(json, 'weekStartDay'),
    );
  }

  static Map<String, dynamic> _sortToJson(Sort sort) {
    return {
      'target': switch (sort.target) {
        GroupFieldSort(fieldRef: final ref) => {
          'kind': 'groupField',
          'fieldRef': _fieldRefToJson(ref),
        },
        // `measureLabel` is omitted when null — single-measure queries
        // don't need to set it, and multi-measure queries that target
        // the (sole) measure of an inferred-shape query can also leave
        // it null. The validator rejects ambiguous unlabeled-multi-
        // measure sorts with `preconditionViolation`; a non-null label
        // that doesn't match any measure is rejected with
        // `unknownMeasureLabel`.
        MeasureValueSort(measureLabel: final label) => {
          'kind': 'measureValue',
          'measureLabel': ?label,
        },
      },
      'direction': sort.direction.name,
      // Only emitted when set; the default of `false` decodes back
      // from a missing key.
      if (sort.forceNullsLast) 'forceNullsLast': true,
    };
  }

  static Sort _sortFromJson(Map<String, dynamic> json) {
    final target = _requireMap(json, 'target');
    final kind = _optionalString(target, 'kind');
    final SortTarget parsedTarget;
    switch (kind) {
      case 'groupField':
        parsedTarget = GroupFieldSort(
          fieldRef: _fieldRefFromJson(_asMap(target['fieldRef'])),
        );
      case 'measureValue':
        parsedTarget = MeasureValueSort(
          measureLabel: _optionalString(target, 'measureLabel'),
        );
      default:
        throw FormatException('Unknown SortTarget kind: $kind');
    }
    return Sort(
      target: parsedTarget,
      direction: _enumFromName(SortDirection.values, json['direction']),
      forceNullsLast: _optionalBool(json, 'forceNullsLast') ?? false,
    );
  }

  static Map<String, dynamic> _derivedOpToJson(DerivedOperation op) {
    switch (op) {
      case NoDerivedOp():
        return {'kind': 'none'};
      case CumulativeSumOp():
        return {'kind': 'cumulativeSum'};
      case DeltaOp():
        return {'kind': 'delta'};
      case MovingAverageOp(window: final window):
        return {'kind': 'movingAverage', 'window': window};
    }
  }

  static DerivedOperation _derivedOpFromJson(Map<String, dynamic> json) {
    final kind = _optionalString(json, 'kind');
    switch (kind) {
      case 'none':
        return const NoDerivedOp();
      case 'cumulativeSum':
        return const CumulativeSumOp();
      case 'delta':
        return const DeltaOp();
      case 'movingAverage':
        return MovingAverageOp(window: _requireInt(json, 'window'));
      default:
        throw FormatException('Unknown DerivedOperation kind: $kind');
    }
  }

  // ── DateRangeMode / WidgetDateRange ───────────────────────────────────

  static String encodeDateRangeMode(DateRangeMode mode) {
    return jsonEncode(_dateRangeModeToJson(mode));
  }

  static DateRangeMode decodeDateRangeMode(String text) {
    final json = _decodeJsonObject(text);
    return _dateRangeModeFromJson(json);
  }

  static Map<String, dynamic> _dateRangeModeToJson(DateRangeMode mode) {
    switch (mode) {
      case UsePageRange():
        return {'kind': 'usePageRange'};
      case NoDateRange():
        return {'kind': 'noDateRange'};
      case FixedOverride(range: final range):
        return {
          'kind': 'fixedOverride',
          'range': _widgetDateRangeToJson(range),
        };
    }
  }

  static DateRangeMode _dateRangeModeFromJson(Map<String, dynamic> json) {
    final kind = _optionalString(json, 'kind');
    switch (kind) {
      case 'usePageRange':
        return const UsePageRange();
      case 'noDateRange':
        return const NoDateRange();
      case 'fixedOverride':
        return FixedOverride(
          range: _widgetDateRangeFromJson(_requireMap(json, 'range')),
        );
      default:
        throw FormatException('Unknown DateRangeMode kind: $kind');
    }
  }

  /// Encodes a [WidgetDateRange] value to JSON.
  ///
  /// Public because consumers may persist a `WidgetDateRange` outside
  /// of a widget spec (e.g. a page-level date-range selector storing
  /// just this value).
  static String encodeWidgetDateRange(WidgetDateRange range) {
    return jsonEncode(_widgetDateRangeToJson(range));
  }

  /// Decodes a JSON [WidgetDateRange] previously written by
  /// [encodeWidgetDateRange].
  static WidgetDateRange decodeWidgetDateRange(String text) {
    final json = _decodeJsonObject(text);
    return _widgetDateRangeFromJson(json);
  }

  static Map<String, dynamic> _widgetDateRangeToJson(WidgetDateRange r) {
    switch (r) {
      case PresetRange(preset: final preset):
        return {'kind': 'preset', 'preset': preset.name};
      case CustomRange(start: final start, endExclusive: final endX):
        // Persist user-facing inclusive endpoints. The CustomRange
        // constructor converts back to exclusive on decode.
        final endInclusive = DateTime(endX.year, endX.month, endX.day - 1);
        return {
          'kind': 'custom',
          'start': start.toIso8601String(),
          'end': endInclusive.toIso8601String(),
        };
    }
  }

  static WidgetDateRange _widgetDateRangeFromJson(Map<String, dynamic> json) {
    final kind = _optionalString(json, 'kind');
    switch (kind) {
      case 'preset':
        final name = _optionalString(json, 'preset');
        if (name == 'custom') {
          // `custom` is not a member of [DateRangePreset]. Reject
          // this combination with a targeted message rather than the
          // less actionable 'unknown enum' failure from `_enumFromName`.
          throw const FormatException(
            'DateRangePreset.custom is not supported; custom ranges '
            'must use kind=custom with explicit start/end dates.',
          );
        }
        return PresetRange(preset: _enumFromName(DateRangePreset.values, name));
      case 'custom':
        return CustomRange(
          start: DateTime.parse(_requireString(json, 'start')),
          end: DateTime.parse(_requireString(json, 'end')),
        );
      default:
        throw FormatException('Unknown WidgetDateRange kind: $kind');
    }
  }

  // ── DisplaySpec ───────────────────────────────────────────────────────
  //
  // The display spec is intentionally minimal — just the display
  // type discriminator string. Future enhancements (axis labels,
  // formatting, etc.) can layer on top without breaking the on-disk
  // shape because unrecognized JSON keys are ignored on decode.

  static String encodeDisplaySpec(DisplaySpec spec) {
    return jsonEncode({'displayType': spec.displayType});
  }

  static DisplaySpec decodeDisplaySpec(String text) {
    final json = _decodeJsonObject(text);
    return DisplaySpec(displayType: _requireString(json, 'displayType'));
  }

  // ── FieldRef / TypedValue (shared atoms) ──────────────────────────────

  static Map<String, dynamic> _fieldRefToJson(FieldRef ref) {
    return {'sourceId': ref.sourceId, 'fieldId': ref.fieldId};
  }

  static FieldRef _fieldRefFromJson(Map<String, dynamic> json) {
    return FieldRef(
      sourceId: _requireString(json, 'sourceId'),
      fieldId: _requireString(json, 'fieldId'),
    );
  }

  static Map<String, dynamic> _typedValueToJson(TypedValue v) {
    switch (v) {
      case StringValue(value: final s):
        return {'kind': 'string', 'value': s};
      case EnumValue(value: final s):
        return {'kind': 'enum', 'value': s};
      case IntValue(value: final n):
        return {'kind': 'int', 'value': n};
      case DoubleValue(value: final n):
        return {'kind': 'double', 'value': n};
      case BoolValue(value: final b):
        return {'kind': 'bool', 'value': b};
      case DateTimeValue(value: final d):
        return {'kind': 'dateTime', 'value': d.toIso8601String()};
      case DurationValue(value: final d):
        return {'kind': 'duration', 'value': d.inMicroseconds};
      case StringListValue(values: final values):
        return {'kind': 'stringList', 'values': values};
      case EnumListValue(values: final values):
        return {'kind': 'enumList', 'values': values};
      case IntListValue(values: final values):
        return {'kind': 'intList', 'values': values};
      case NullValue(declaredType: final t):
        return {'kind': 'null', 'fieldType': t.name};
    }
  }

  static TypedValue _typedValueFromJson(Map<String, dynamic> json) {
    final kind = _optionalString(json, 'kind');
    switch (kind) {
      case 'string':
        return StringValue(_requireString(json, 'value'));
      case 'enum':
        return EnumValue(_requireString(json, 'value'));
      case 'int':
        return IntValue(_requireInt(json, 'value'));
      case 'double':
        final v = json['value'];
        if (v is! num) {
          throw FormatException(
            'Expected num at "value" for double; got '
            '${v == null ? "missing key" : v.runtimeType}.',
          );
        }
        return DoubleValue(v.toDouble());
      case 'bool':
        return BoolValue(_requireBool(json, 'value'));
      case 'dateTime':
        return DateTimeValue(DateTime.parse(_requireString(json, 'value')));
      case 'duration':
        return DurationValue(
          Duration(microseconds: _requireInt(json, 'value')),
        );
      case 'stringList':
        return StringListValue([
          for (final v in _requireList(json, 'values')) _asString(v),
        ]);
      case 'enumList':
        return EnumListValue([
          for (final v in _requireList(json, 'values')) _asString(v),
        ]);
      case 'intList':
        return IntListValue([
          for (final v in _requireList(json, 'values')) _asInt(v),
        ]);
      case 'null':
        return NullValue(_enumFromName(FieldType.values, json['fieldType']));
      default:
        throw FormatException('Unknown TypedValue kind: $kind');
    }
  }

  /// Looks up an enum value by its `.name`. Throws a [FormatException]
  /// if the name is missing, not a string, or unknown.
  static T _enumFromName<T extends Enum>(List<T> values, Object? name) {
    if (name == null) {
      throw FormatException(
        'Missing enum name for ${values.first.runtimeType}.',
      );
    }
    if (name is! String) {
      throw FormatException(
        'Expected String enum name for ${values.first.runtimeType}; '
        'got ${name.runtimeType}.',
      );
    }
    for (final v in values) {
      if (v.name == name) return v;
    }
    throw FormatException(
      'Unknown enum name "$name" for ${values.first.runtimeType}.',
    );
  }

  // ── Safe JSON readers ────────────────────────────────────────────────
  //
  // The codec's failure model is uniform: malformed payloads throw
  // [FormatException]. These helpers replace bare `as` casts so that a
  // wrong-typed or missing value produces a descriptive FormatException
  // rather than a generic TypeError.

  static String _requireString(Map<String, dynamic> json, String key) {
    final v = json[key];
    if (v is String) return v;
    throw FormatException(_typeMsg('String', key, v));
  }

  static String? _optionalString(Map<String, dynamic> json, String key) {
    final v = json[key];
    if (v == null) return null;
    if (v is String) return v;
    throw FormatException(_typeMsg('String?', key, v));
  }

  static int _requireInt(Map<String, dynamic> json, String key) {
    final v = json[key];
    if (v is int) return v;
    throw FormatException(_typeMsg('int', key, v));
  }

  static int? _optionalInt(Map<String, dynamic> json, String key) {
    final v = json[key];
    if (v == null) return null;
    if (v is int) return v;
    throw FormatException(_typeMsg('int?', key, v));
  }

  /// Reads a JSON-numeric value as a `num`, preserving the int/double
  /// distinction the JSON wire carries (`1` stays an int, `1.5` a
  /// double). Used for [FillNullOp.fill].
  static num _requireNum(Map<String, dynamic> json, String key) {
    final v = json[key];
    if (v is num) return v;
    throw FormatException(_typeMsg('num', key, v));
  }

  /// Reads a JSON-numeric value as a double. JSON does not distinguish
  /// integer and decimal literals at the wire level — `{"p": 1}` and
  /// `{"p": 1.0}` both parse to numbers — so this helper accepts any
  /// `num` and coerces via `toDouble()`.
  static double _requireDouble(Map<String, dynamic> json, String key) {
    final v = json[key];
    if (v is num) return v.toDouble();
    throw FormatException(_typeMsg('num (as double)', key, v));
  }

  static bool _requireBool(Map<String, dynamic> json, String key) {
    final v = json[key];
    if (v is bool) return v;
    throw FormatException(_typeMsg('bool', key, v));
  }

  static bool? _optionalBool(Map<String, dynamic> json, String key) {
    final v = json[key];
    if (v == null) return null;
    if (v is bool) return v;
    throw FormatException(_typeMsg('bool?', key, v));
  }

  static Map<String, dynamic> _requireMap(
    Map<String, dynamic> json,
    String key,
  ) {
    final v = json[key];
    if (v is Map<String, dynamic>) return v;
    throw FormatException(_typeMsg('Map', key, v));
  }

  static List<dynamic> _requireList(Map<String, dynamic> json, String key) {
    final v = json[key];
    if (v is List) return v;
    throw FormatException(_typeMsg('List', key, v));
  }

  static List<dynamic>? _optionalList(Map<String, dynamic> json, String key) {
    final v = json[key];
    if (v == null) return null;
    if (v is List) return v;
    throw FormatException(_typeMsg('List?', key, v));
  }

  /// Cast helpers for values not addressed by key (list elements,
  /// nested values), with the same FormatException contract.

  static String _asString(Object? v) {
    if (v is String) return v;
    throw FormatException(
      'Expected String; got ${v == null ? "null" : v.runtimeType}.',
    );
  }

  static int _asInt(Object? v) {
    if (v is int) return v;
    throw FormatException(
      'Expected int; got ${v == null ? "null" : v.runtimeType}.',
    );
  }

  static Map<String, dynamic> _asMap(Object? v) {
    if (v is Map<String, dynamic>) return v;
    throw FormatException(
      'Expected Map; got ${v == null ? "null" : v.runtimeType}.',
    );
  }

  /// Top-level JSON decode that surfaces malformed input as
  /// [FormatException] (instead of a bare cast error when the outermost
  /// JSON value isn't an object).
  static Map<String, dynamic> _decodeJsonObject(String text) {
    final decoded = jsonDecode(text);
    if (decoded is Map<String, dynamic>) return decoded;
    throw FormatException(
      'Expected a JSON object at top level; got ${decoded.runtimeType}.',
    );
  }

  static String _typeMsg(String expected, String key, Object? actual) =>
      'Expected $expected at "$key"; got '
      '${actual == null ? "missing key" : actual.runtimeType}.';
}
