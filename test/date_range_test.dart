import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:test/test.dart';

/// Date-range value types and the `DatePresetResolver` semantics.
///
/// `CustomRange` constructs from an inclusive `[start, end]` pair
/// supplied by the caller and stores a half-open `[start,
/// endExclusive)` internally — `endExclusive` is the start of the day
/// after the user-facing end. The conversion day-aligns both
/// endpoints; same-day start and end produce a one-day window.
///
/// `DatePresetResolver` computes a half-open window for every
/// [DateRangePreset], parameterized by `today`, `weekStartDay`,
/// `quarterStartMonth`, and (for `allTime`) `earliestDataDate`. The
/// resolver is purely functional and hermetic — no `DateTime.now()`.
void main() {
  // ────────────────────────────────────────────────────────────────────
  // CustomRange inclusive → half-open conversion
  // ────────────────────────────────────────────────────────────────────

  group('CustomRange — inclusive → half-open conversion', () {
    test('endExclusive is the start of the day after end', () {
      final r = CustomRange(
        start: DateTime(2026, 5, 1),
        end: DateTime(2026, 5, 10),
      );
      expect(r.start, DateTime(2026, 5, 1));
      expect(r.endExclusive, DateTime(2026, 5, 11));
    });

    test('start is day-aligned regardless of time component', () {
      final r = CustomRange(
        start: DateTime(2026, 5, 1, 14, 30, 45),
        end: DateTime(2026, 5, 10),
      );
      expect(r.start, DateTime(2026, 5, 1));
    });

    test('end is day-aligned regardless of time component', () {
      final r = CustomRange(
        start: DateTime(2026, 5, 1),
        end: DateTime(2026, 5, 10, 23, 59, 59),
      );
      expect(r.endExclusive, DateTime(2026, 5, 11));
    });

    test('same-day start and end produce a one-day window', () {
      final r = CustomRange(
        start: DateTime(2026, 5, 1),
        end: DateTime(2026, 5, 1),
      );
      expect(r.start, DateTime(2026, 5, 1));
      expect(r.endExclusive, DateTime(2026, 5, 2));
    });

    test('month boundary crosses correctly', () {
      final r = CustomRange(
        start: DateTime(2026, 4, 30),
        end: DateTime(2026, 5, 1),
      );
      expect(r.start, DateTime(2026, 4, 30));
      expect(r.endExclusive, DateTime(2026, 5, 2));
    });

    test('year boundary crosses correctly', () {
      final r = CustomRange(
        start: DateTime(2025, 12, 31),
        end: DateTime(2026, 1, 1),
      );
      expect(r.start, DateTime(2025, 12, 31));
      expect(r.endExclusive, DateTime(2026, 1, 2));
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // DatePresetResolver
  // ────────────────────────────────────────────────────────────────────

  group('DatePresetResolver — common presets', () {
    final today = DateTime(2026, 5, 15); // a Friday

    test('last7Days spans today and the 6 preceding days', () {
      final (start, end) = DatePresetResolver.resolve(
        const PresetRange(preset: DateRangePreset.last7Days),
        today: today,
      );
      // 6 days back from May 15 is May 9; end-exclusive is May 16.
      expect(start, DateTime(2026, 5, 9));
      expect(end, DateTime(2026, 5, 16));
    });

    test('last30Days spans today and the 29 preceding days', () {
      final (start, end) = DatePresetResolver.resolve(
        const PresetRange(preset: DateRangePreset.last30Days),
        today: today,
      );
      expect(start, DateTime(2026, 4, 16));
      expect(end, DateTime(2026, 5, 16));
    });

    test('thisMonth starts at the 1st of the month and ends tomorrow', () {
      final (start, end) = DatePresetResolver.resolve(
        const PresetRange(preset: DateRangePreset.thisMonth),
        today: today,
      );
      expect(start, DateTime(2026, 5, 1));
      expect(end, DateTime(2026, 5, 16));
    });

    test('lastMonth spans the entire previous month', () {
      final (start, end) = DatePresetResolver.resolve(
        const PresetRange(preset: DateRangePreset.lastMonth),
        today: today,
      );
      expect(start, DateTime(2026, 4, 1));
      expect(end, DateTime(2026, 5, 1));
    });

    test('quarterToDate starts at the quarter\'s first month', () {
      // May 15 is in Q2 (Apr-Jun) when quarterStartMonth=1.
      final (start, end) = DatePresetResolver.resolve(
        const PresetRange(preset: DateRangePreset.quarterToDate),
        today: today,
      );
      expect(start, DateTime(2026, 4, 1));
      expect(end, DateTime(2026, 5, 16));
    });
  });

  group('DatePresetResolver — thisWeek with weekStartDay', () {
    // May 15, 2026 is a Friday (weekday = 5).
    final today = DateTime(2026, 5, 15);

    test('Sunday-start: week starts Sunday May 10', () {
      // weekday Fri=5, Sun=7. (5 - 7) % 7 = 5 days back.
      final (start, end) = DatePresetResolver.resolve(
        const PresetRange(preset: DateRangePreset.thisWeek),
        today: today,
        weekStartDay: DateTime.sunday,
      );
      expect(start, DateTime(2026, 5, 10));
      expect(end, DateTime(2026, 5, 16));
    });

    test('Monday-start: week starts Monday May 11', () {
      // (5 - 1) % 7 = 4 days back.
      final (start, end) = DatePresetResolver.resolve(
        const PresetRange(preset: DateRangePreset.thisWeek),
        today: today,
        weekStartDay: DateTime.monday,
      );
      expect(start, DateTime(2026, 5, 11));
      expect(end, DateTime(2026, 5, 16));
    });
  });

  group('DatePresetResolver — allTime', () {
    test('uses earliestDataDate when supplied', () {
      final (start, end) = DatePresetResolver.resolve(
        const PresetRange(preset: DateRangePreset.allTime),
        today: DateTime(2026, 5, 15),
        earliestDataDate: DateTime(2020, 1, 1, 14, 30),
      );
      // Day-aligned: 2020-01-01.
      expect(start, DateTime(2020, 1, 1));
      expect(end, DateTime(2026, 5, 16));
    });

    test('without earliestDataDate falls back to today − 365 days', () {
      final (start, end) = DatePresetResolver.resolve(
        const PresetRange(preset: DateRangePreset.allTime),
        today: DateTime(2026, 5, 15),
      );
      expect(start, DateTime(2025, 5, 15));
      expect(end, DateTime(2026, 5, 16));
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // CustomRange round-trips through the codec
  // ────────────────────────────────────────────────────────────────────

  group('CustomRange codec round-trip preserves inclusive endpoints', () {
    test(
      'encoded then decoded CustomRange has the same start and endExclusive',
      () {
        final original = CustomRange(
          start: DateTime(2026, 5, 1),
          end: DateTime(2026, 5, 10),
        );
        final encoded = WidgetPayloadCodec.encodeWidgetDateRange(original);
        final decoded =
            WidgetPayloadCodec.decodeWidgetDateRange(encoded) as CustomRange;
        expect(decoded.start, original.start);
        expect(decoded.endExclusive, original.endExclusive);
      },
    );
  });

  // ────────────────────────────────────────────────────────────────────
  // PresetRange — preset == custom is rejected
  // ────────────────────────────────────────────────────────────────────

  group('PresetRange decoding — custom preset is rejected', () {
    test('a PresetRange json with preset:"custom" fails to decode', () {
      // The codec emits CustomRange via a different discriminator
      // than PresetRange. Forcing a PresetRange with preset name
      // "custom" is invalid: the catch-all `custom` belongs to the
      // CustomRange shape, not the preset list.
      const malformed = '{"kind":"preset","preset":"custom"}';
      expect(
        () => WidgetPayloadCodec.decodeWidgetDateRange(malformed),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
