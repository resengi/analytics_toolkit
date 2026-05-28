import '../execution/source_record.dart';
import '../query/measure.dart';
import '../results.dart';
import '../schema/schema.dart';
import '../schema/typed_value.dart';
import 'grain_arithmetic.dart';
import 'streak_calculator.dart';
import 'time_grain.dart';

/// Executes a `StreakMeasure` query.
///
/// Streak execution is its own pipeline because the measure ignores
/// `groupBys`, `sort`, and `derivedOperation`.
///
/// The result is a [TableResult] with one row per entity and four
/// columns:
///
/// - `entityId` (string, group-key) — the entity's stable identifier
///   (stringified). The pipeline implicitly groups by entity, and
///   this is the column that flattens the grouping dimension into
///   the table, consistent with every other `TableResult` producer.
/// - `entityLabel` (string, measure) — user-facing display label,
///   derived from `entityLabelField` or falling back to the entity
///   ID. Treated as a measure column because it is derived metadata,
///   not the grouping dimension itself.
/// - `currentStreak` (integer, measure) — current run length.
/// - `longestStreak` (integer, measure) — longest historical run.
///
/// Row identity is also carried in [RowKey] as a length-1 tuple
/// wrapping the entity ID — the group-key column is the row-key
/// contents made readable for row-wise consumption.
///
/// The actual streak math (consecutive completion runs over a set of
/// scheduled dates) is delegated to `StreakCalculator`.
abstract class StreakExecutor {
  /// Runs the streak pipeline against [records] and returns a
  /// `TableResult` with one row per entity.
  ///
  /// Pipeline:
  /// 1. Group records by `entityIdField` (one streak per entity).
  /// 2. For each entity, collect scheduled dates and completed dates
  ///    (records whose `statusField` value equals `completedStatusValue`).
  /// 3. Determine the entity's display label — either the first
  ///    non-empty `entityLabelField` value, or the entity ID if the
  ///    label field is null or absent.
  /// 4. Run the streak algorithm.
  /// 5. Sort rows by current streak descending.
  /// 6. Apply `topN` if set; preserve the original total as
  ///    `TableResult.truncatedCount`.
  static TableResult execute(
    StreakMeasure measure,
    Iterable<SourceRecord> records, {
    required DateTime asOf,
  }) {
    // Day-truncate the reference date once, at the boundary. The
    // calculator and the `scheduled`/`completed` sets below all
    // operate on day-truncated DateTimes.
    final asOfDay = TimeGrain.day.startOfBucket(asOf);

    // Step 1: group records by entity identity.
    //
    // Entity-id fields can be any non-null typed value — strings,
    // integers, enums, booleans, even dateTimes. We stringify each
    // value to use as a stable dedup key. Records whose entity-id
    // field is null or unsupported are skipped.
    final byEntity = <String, List<SourceRecord>>{};
    for (final r in records) {
      final id = r[measure.entityIdField.fieldId];
      final key = _entityKey(id);
      if (key == null) continue;
      byEntity.putIfAbsent(key, () => []).add(r);
    }

    final rows = <_StreakRow>[];

    for (final entry in byEntity.entries) {
      final entityRecords = entry.value;

      // Step 2: collect scheduled and completed dates.
      final scheduled = <DateTime>{};
      final completed = <DateTime>{};

      for (final r in entityRecords) {
        // The executor's type-validation pass guarantees that a
        // non-null value at this field is a [DateTimeValue]. Skip
        // records that simply omit the field or carry an explicit
        // [NullValue].
        final dateValue = r[measure.scheduledDateField.fieldId];
        if (dateValue == null || dateValue is NullValue) continue;
        if (dateValue is! DateTimeValue) {
          throw StateError(
            'StreakExecutor: unreachable for non-DateTimeValue '
            '${dateValue.runtimeType} on scheduled-date field; executor '
            'type-validation pass should have rejected.',
          );
        }
        final day = TimeGrain.day.startOfBucket(dateValue.value);
        scheduled.add(day);

        // The validator rejects status fields that aren't string or
        // enumeration, and the executor's type pass guarantees the
        // record's value is the matching subtype. So a non-null,
        // non-NullValue status value is either a [StringValue] or an
        // [EnumValue], both of which expose `raw` as a [String].
        final statusValue = r[measure.statusField.fieldId];
        if (statusValue == null || statusValue is NullValue) continue;
        if (statusValue.raw == measure.completedStatusValue) {
          completed.add(day);
        }
      }

      // Step 3: determine entity label.
      // If a label field is configured, use the first non-empty value
      // we find across the entity's records. Otherwise fall back to
      // the entity ID.
      String label = entry.key;
      final labelFieldRef = measure.entityLabelField;
      if (labelFieldRef != null) {
        for (final r in entityRecords) {
          final v = r[labelFieldRef.fieldId];
          if (v is StringValue && v.value.isNotEmpty) {
            label = v.value;
            break;
          }
        }
      }

      // Step 4: compute streak.
      final (current, longest) = StreakCalculator.computeStreak(
        scheduled,
        completed,
        asOfDay,
      );

      rows.add(
        _StreakRow(
          entityKey: entry.key,
          entityLabel: label,
          currentStreak: current,
          longestStreak: longest,
        ),
      );
    }

    // Step 5: sort by current streak descending. Ties: longest streak
    // descending, then entity label ascending for deterministic order.
    rows.sort((a, b) {
      final cur = b.currentStreak.compareTo(a.currentStreak);
      if (cur != 0) return cur;
      final lng = b.longestStreak.compareTo(a.longestStreak);
      if (lng != 0) return lng;
      return a.entityLabel.compareTo(b.entityLabel);
    });

    // Step 6: apply topN cap. The total row count is preserved as
    // `truncatedCount` so a renderer can show "+N more".
    final totalRows = rows.length;
    final topN = measure.topN;
    final keptRows = (topN != null && topN < totalRows)
        ? rows.sublist(0, topN)
        : rows;
    final truncatedCount = totalRows - keptRows.length;

    return TableResult(
      columns: [
        // Group-key column: the entity ID (stringified). The streak
        // pipeline groups implicitly by entity, so the entity ID is
        // the row's grouping dimension; flattening it into a group-key
        // column matches the same denormalization every other
        // `TableResult` producer applies (a `MultiIndex.reset_index()`
        // in Pandas terms). Row identity is also carried in `RowKey`
        // — the column is the row-key contents made readable.
        TableColumn(
          label: 'entityId',
          fieldType: FieldType.string,
          kind: TableColumnKind.groupKey,
          values: [for (final row in keptRows) StringValue(row.entityKey)],
        ),
        // Measure columns: the user-facing label (derived metadata,
        // either from `entityLabelField` or the stringified ID
        // fallback) and the two streak statistics.
        TableColumn(
          label: 'entityLabel',
          fieldType: FieldType.string,
          kind: TableColumnKind.measure,
          values: [for (final row in keptRows) StringValue(row.entityLabel)],
        ),
        TableColumn(
          label: 'currentStreak',
          fieldType: FieldType.integer,
          kind: TableColumnKind.measure,
          values: [for (final row in keptRows) IntValue(row.currentStreak)],
        ),
        TableColumn(
          label: 'longestStreak',
          fieldType: FieldType.integer,
          kind: TableColumnKind.measure,
          values: [for (final row in keptRows) IntValue(row.longestStreak)],
        ),
      ],
      rowKeys: [
        for (final row in keptRows) RowKey([StringBucketKey(row.entityKey)]),
      ],
      truncatedCount: truncatedCount,
    );
  }

  /// Stable string key for entity grouping.
  ///
  /// Returns `null` for null / unsupported values (which causes the
  /// record to be skipped). String, int, double, enum, bool, and
  /// dateTime values produce a deterministic key — for non-string
  /// types this stringifies the underlying value. Two records with
  /// equal `raw` values produce the same key regardless of the
  /// `TypedValue` subtype.
  static String? _entityKey(TypedValue? value) {
    if (value == null || value is NullValue) return null;
    final raw = value.raw;
    if (raw is String) return raw;
    if (raw is int) return raw.toString();
    if (raw is double) return raw.toString();
    if (raw is bool) return raw.toString();
    if (raw is DateTime) return raw.toIso8601String();
    if (raw is Duration) return raw.inMicroseconds.toString();
    // List-valued types are not valid entity identifiers — skip them.
    return null;
  }
}

class _StreakRow {
  _StreakRow({
    required this.entityKey,
    required this.entityLabel,
    required this.currentStreak,
    required this.longestStreak,
  });
  final String entityKey;
  final String entityLabel;
  final int currentStreak;
  final int longestStreak;
}
