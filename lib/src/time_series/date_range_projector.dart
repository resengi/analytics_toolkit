import '../errors.dart';
import '../query/query_components.dart';
import '../query/query_enums.dart';
import '../query/query_spec.dart';
import '../schema/schema.dart';
import '../schema/source_lookup.dart';
import '../schema/typed_value.dart';
import 'date_range.dart';

/// Date-range projection helper.
///
/// Resolves a [DateRangeMode] to concrete dates, builds two date
/// filters against the source's primary date field, and appends them
/// to the query's existing filters. The persisted query is never
/// mutated; the projection always works on a copy via
/// `AnalyticsQuerySpec.withAdditionalFilters`.
///
/// The package's intended pattern is for the host application to call
/// `DateRangeProjector.project(...)` once per widget before passing
/// the projected query to `AnalyticsExecutor.execute(...)`.
abstract class DateRangeProjector {
  /// Returns the input query with date-range filters appended, based
  /// on the resolved [mode].
  ///
  /// * If [mode] is `NoDateRange`, returns `Ok(query)` unchanged —
  ///   the validator has already ensured this only happens for
  ///   measures that don't take a date range.
  /// * If [mode] is `UsePageRange` or `FixedOverride`, the effective
  ///   range is resolved and two AND filters are appended to the
  ///   query against the source's primary date field.
  ///
  /// Required arguments:
  /// * [pageRange] — the already-resolved page-level date range,
  ///   used for `UsePageRange` mode.
  /// * [today] — the reference "now" used for relative preset
  ///   resolution. Required and non-null. The package never reads
  ///   wall-clock time; callers must supply it so projection is
  ///   deterministic and testable.
  ///
  /// Optional arguments:
  /// * [earliestDataDate] — for `FixedOverride` modes that resolve to
  ///   the `allTime` preset, the earliest date that has data.
  ///
  /// Error cases:
  /// * `Err(unknownSource)` — `query.source` is not in [sources].
  /// * `Err(primaryDateFieldRequiredForOperation)` — the source has
  ///   no primary date field (it's a non-temporal source) or its
  ///   declared primary date field is missing or not a `dateTime`.
  ///   Date-range projection is impossible against such a source.
  static Result<AnalyticsQuerySpec, AnalyticsError> project({
    required AnalyticsQuerySpec query,
    required DateRangeMode mode,
    required List<SourceDef> sources,
    required (DateTime, DateTime) pageRange,
    required DateTime today,
    DateTime? earliestDataDate,
  }) {
    // Resolve the effective range. NoDateRange → no projection needed.
    final resolved = DatePresetResolver.resolveMode(
      mode,
      today: today,
      earliestDataDate: earliestDataDate,
      pageRange: pageRange,
    );
    if (resolved == null) {
      return Ok(query);
    }

    // Source lookup.
    final source = findSourceById(sources, query.source);
    if (source == null) {
      return Err(
        AnalyticsError(
          kind: AnalyticsErrorKind.unknownSource,
          humanMessage: 'Unknown source: ${query.source}',
        ),
      );
    }

    // The source must be temporal — it must declare a primary date
    // field of type dateTime. Non-temporal sources cannot have date
    // ranges projected against them. SourceDef's constructor enforces
    // that a non-null primaryDateFieldId references a declared
    // dateTime field, so once we've passed the null check there is no
    // further field-shape check to perform here.
    final primaryFieldId = source.primaryDateFieldId;
    if (primaryFieldId == null) {
      return Err(
        AnalyticsError(
          kind: AnalyticsErrorKind.primaryDateFieldRequiredForOperation,
          humanMessage:
              'Source ${source.sourceId} has no primary date field; '
              'date-range projection requires a dateTime primary date '
              'field.',
        ),
      );
    }

    final fieldRef = FieldRef(
      sourceId: source.sourceId,
      fieldId: primaryFieldId,
    );

    // Build the two AND filters and append. The resolver returns a
    // half-open `[startInclusive, endExclusive)` range; the projection
    // mirrors that directly.
    return Ok(
      query.withAdditionalFilters([
        Filter(
          fieldRef: fieldRef,
          operator: FilterOperator.greaterThanOrEqual,
          value: DateTimeValue(resolved.$1),
        ),
        Filter(
          fieldRef: fieldRef,
          operator: FilterOperator.lessThan,
          value: DateTimeValue(resolved.$2),
        ),
      ]),
    );
  }
}
