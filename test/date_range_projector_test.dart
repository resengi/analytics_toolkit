import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:test/test.dart';

import '_fixtures.dart';

/// `DateRangeProjector.project` translates a `DateRangeMode` plus a
/// page-level range into two AND filters on the source's primary
/// date field: `>= startInclusive` and `< endExclusive`. The
/// projection is the only path that turns a date-range mode into
/// query filters at execution time.
///
/// Error cases: unknown source → `unknownSource`; non-temporal
/// source → `primaryDateFieldRequiredForOperation`. `NoDateRange`
/// mode is a no-op (returns the query unchanged).
void main() {
  final events = eventsSource();
  final tasks = tasksSource(); // no primaryDateFieldId
  final allSources = [events, tasks];

  // A standard page-level range to plumb through.
  final pageRange = (DateTime(2026, 5, 1), DateTime(2026, 5, 11));
  final today = DateTime(2026, 5, 15);

  AnalyticsQuerySpec eventsCountQuery() =>
      AnalyticsQuerySpec(source: 'events', measures: const [CountMeasure()]);

  // ────────────────────────────────────────────────────────────────────
  // Successful projection — two AND filters appended
  // ────────────────────────────────────────────────────────────────────

  group('successful projection appends two AND filters', () {
    test('UsePageRange projects the page range as >= and < filters', () {
      final result = DateRangeProjector.project(
        query: eventsCountQuery(),
        mode: const UsePageRange(),
        sources: allSources,
        pageRange: pageRange,
        today: today,
      );
      expect(result.isOk, isTrue);
      final projected = result.okOrNull!;
      expect(projected.filters, hasLength(2));

      final geFilter = projected.filters[0];
      expect(geFilter.operator, FilterOperator.greaterThanOrEqual);
      expect(geFilter.fieldRef.fieldId, 'occurredAt');
      expect(geFilter.value, DateTimeValue(pageRange.$1));

      final ltFilter = projected.filters[1];
      expect(ltFilter.operator, FilterOperator.lessThan);
      expect(ltFilter.fieldRef.fieldId, 'occurredAt');
      expect(ltFilter.value, DateTimeValue(pageRange.$2));
    });

    test('FixedOverride with a CustomRange ignores the page range', () {
      final fixed = CustomRange(
        start: DateTime(2026, 1, 1),
        end: DateTime(2026, 1, 31),
      );
      final result = DateRangeProjector.project(
        query: eventsCountQuery(),
        mode: FixedOverride(range: fixed),
        sources: allSources,
        pageRange: pageRange,
        today: today,
      );
      final projected = result.okOrNull!;
      expect((projected.filters[0].value as DateTimeValue).value, fixed.start);
      expect(
        (projected.filters[1].value as DateTimeValue).value,
        fixed.endExclusive,
      );
    });

    test('NoDateRange returns the query unchanged', () {
      final original = eventsCountQuery();
      final result = DateRangeProjector.project(
        query: original,
        mode: const NoDateRange(),
        sources: allSources,
        pageRange: pageRange,
        today: today,
      );
      // No filters appended.
      expect(result.okOrNull!.filters, isEmpty);
    });

    test('FixedOverride with a PresetRange resolves via today', () {
      final result = DateRangeProjector.project(
        query: eventsCountQuery(),
        mode: const FixedOverride(
          range: PresetRange(preset: DateRangePreset.last7Days),
        ),
        sources: allSources,
        pageRange: pageRange,
        today: today,
      );
      // today = May 15; last7Days → [May 9, May 16).
      final projected = result.okOrNull!;
      expect(
        (projected.filters[0].value as DateTimeValue).value,
        DateTime(2026, 5, 9),
      );
      expect(
        (projected.filters[1].value as DateTimeValue).value,
        DateTime(2026, 5, 16),
      );
    });

    test('existing filters are preserved and the date filters appended', () {
      final query = AnalyticsQuerySpec(
        source: 'events',
        measures: const [CountMeasure()],
        filters: [
          const Filter(
            fieldRef: FieldRef(sourceId: 'events', fieldId: 'kind'),
            operator: FilterOperator.equals,
            value: EnumValue('view'),
          ),
        ],
      );
      final result = DateRangeProjector.project(
        query: query,
        mode: const UsePageRange(),
        sources: allSources,
        pageRange: pageRange,
        today: today,
      );
      final projected = result.okOrNull!;
      // 1 existing + 2 date = 3.
      expect(projected.filters, hasLength(3));
      expect(projected.filters.first, query.filters.first);
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // Error cases
  // ────────────────────────────────────────────────────────────────────

  group('error cases', () {
    test('unknown source fires unknownSource', () {
      final result = DateRangeProjector.project(
        query: AnalyticsQuerySpec(
          source: 'nope',
          measures: const [CountMeasure()],
        ),
        mode: const UsePageRange(),
        sources: allSources,
        pageRange: pageRange,
        today: today,
      );
      expect(result.isErr, isTrue);
      expect(result.errOrNull!.kind, AnalyticsErrorKind.unknownSource);
    });

    test(
      'source without primaryDateFieldId fires primaryDateFieldRequiredForOperation',
      () {
        final result = DateRangeProjector.project(
          query: AnalyticsQuerySpec(
            source: 'tasks',
            measures: const [CountMeasure()],
          ),
          mode: const UsePageRange(),
          sources: allSources,
          pageRange: pageRange,
          today: today,
        );
        expect(result.isErr, isTrue);
        expect(
          result.errOrNull!.kind,
          AnalyticsErrorKind.primaryDateFieldRequiredForOperation,
        );
      },
    );
  });
}
