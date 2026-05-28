// A runnable tour of the `analytics_toolkit` package.
//
// Each section below builds a small in-memory dataset, runs a query,
// and prints the result. The sections progress from the simplest case
// (one group-by, one measure) through the time-series pipeline, derived
// post-aggregation transforms, streak measures, and on to the codec
// used to persist a query as JSON.
//
// Run from the `example/` directory:
//
//   dart run
//
// To run a single section, pass its number on the command line:
//
//   dart run example/lib/main.dart 5

// ignore_for_file: avoid_print

import 'package:analytics_toolkit/analytics_toolkit.dart';

void main(List<String> args) {
  final selected = args.isEmpty ? null : int.tryParse(args.first);

  final sections = <(int, String, void Function())>[
    (1, 'Basic series — count tasks by status', _basicSeries),
    (2, 'Multi-measure — count + sum + average per group', _multiMeasure),
    (
      3,
      'Filter, sort, and limit — top three statuses by count',
      _filterSortLimit,
    ),
    (4, 'HAVING — only groups whose count is at least 2', _havingClause),
    (5, 'Two group-bys — status by priority', _multiSeries),
    (6, 'Time-grouped + densified — events per day', _timeGroupedDensified),
    (
      7,
      'Derived operation — cumulative count over time',
      _derivedCumulativeSum,
    ),
    (8, 'Streak measure — current and longest per habit', _streak),
    (9, 'Column aliasing with `GroupBy.label`', _columnAliasing),
    (10, 'Codec — encode a query to JSON and back', _codecRoundtrip),
  ];

  print('═══════════════════════════════════════════════════════════');
  print('  analytics_toolkit — runnable tour');
  print('═══════════════════════════════════════════════════════════');

  for (final (n, title, run) in sections) {
    if (selected != null && selected != n) continue;
    print('');
    print('━━━ $n. $title ━━━');
    print('');
    run();
  }

  print('');
  print('═══════════════════════════════════════════════════════════');
}

// ── Shared sources ──────────────────────────────────────────────────────

final _tasks = SourceDef(
  sourceId: 'tasks',
  displayName: 'Tasks',
  fields: const [
    FieldDef(
      sourceId: 'tasks',
      fieldId: 'status',
      displayName: 'Status',
      fieldType: FieldType.enumeration,
      filterable: true,
      groupable: true,
      aggregatable: false,
      sortable: true,
    ),
    FieldDef(
      sourceId: 'tasks',
      fieldId: 'priority',
      displayName: 'Priority',
      fieldType: FieldType.integer,
      filterable: true,
      groupable: true,
      aggregatable: true,
      sortable: true,
    ),
    FieldDef(
      sourceId: 'tasks',
      fieldId: 'estimateHours',
      displayName: 'Estimate (hours)',
      fieldType: FieldType.double,
      filterable: true,
      groupable: false,
      aggregatable: true,
      sortable: true,
    ),
  ],
);

final _events = SourceDef(
  sourceId: 'events',
  displayName: 'Events',
  primaryDateFieldId: 'occurredAt',
  fields: const [
    FieldDef(
      sourceId: 'events',
      fieldId: 'occurredAt',
      displayName: 'Occurred At',
      fieldType: FieldType.dateTime,
      filterable: true,
      groupable: true,
      aggregatable: false,
      sortable: true,
    ),
  ],
);

final _habitLogs = SourceDef(
  sourceId: 'habit_logs',
  displayName: 'Habit Logs',
  fields: const [
    FieldDef(
      sourceId: 'habit_logs',
      fieldId: 'habitId',
      displayName: 'Habit',
      fieldType: FieldType.string,
      filterable: true,
      groupable: true,
      aggregatable: false,
      sortable: true,
    ),
    FieldDef(
      sourceId: 'habit_logs',
      fieldId: 'scheduledFor',
      displayName: 'Scheduled For',
      fieldType: FieldType.dateTime,
      filterable: true,
      groupable: true,
      aggregatable: false,
      sortable: true,
    ),
    FieldDef(
      sourceId: 'habit_logs',
      fieldId: 'status',
      displayName: 'Status',
      fieldType: FieldType.enumeration,
      filterable: true,
      groupable: true,
      aggregatable: false,
      sortable: true,
    ),
  ],
);

// ── Shared records ──────────────────────────────────────────────────────

List<SourceRecord> _taskRecords() => [
  _task(status: 'done', priority: 3, estimate: 4.0),
  _task(status: 'todo', priority: 1, estimate: 1.5),
  _task(status: 'done', priority: 2, estimate: 2.0),
  _task(status: 'todo', priority: 2, estimate: 8.0),
  _task(status: 'done', priority: 1, estimate: 0.5),
  _task(status: 'in_progress', priority: 3, estimate: 6.0),
  _task(status: 'done', priority: 3, estimate: 3.5),
  _task(status: 'todo', priority: 3, estimate: 5.0),
  _task(status: 'done', priority: 2, estimate: 1.0),
];

SourceRecord _task({
  required String status,
  required int priority,
  required double estimate,
}) => SourceRecord(
  fields: {
    'status': EnumValue(status),
    'priority': IntValue(priority),
    'estimateHours': DoubleValue(estimate),
  },
);

List<SourceRecord> _eventRecords() {
  // Eight events across a five-day window. Day 2 (Jan 6) and day 5
  // (Jan 9) get nothing — the densified pipeline fills them with zero.
  DateTime t(int day, int hour) => DateTime(2026, 1, 4 + day, hour);
  return [
    _event(t(1, 9)),
    _event(t(1, 14)),
    _event(t(3, 11)),
    _event(t(3, 15)),
    _event(t(3, 18)),
    _event(t(4, 8)),
    _event(t(4, 12)),
    _event(t(4, 16)),
  ];
}

SourceRecord _event(DateTime occurredAt) =>
    SourceRecord(fields: {'occurredAt': DateTimeValue(occurredAt)});

List<SourceRecord> _habitRecords() {
  // Two habits over ten days. `morning_run` completed on days 1-5 and
  // 8-10, missed on 6-7 → current streak 3, longest 5. `read` completed
  // on every day → current 10, longest 10.
  final start = DateTime(2026, 1, 1);
  DateTime day(int n) => start.add(Duration(days: n));
  String runStatus(int d) => (d == 6 || d == 7) ? 'missed' : 'done';
  return [
    for (final d in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
      _habitLog('morning_run', day(d), runStatus(d)),
    for (final d in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
      _habitLog('read', day(d), 'done'),
  ];
}

SourceRecord _habitLog(String habitId, DateTime scheduledFor, String status) =>
    SourceRecord(
      fields: {
        'habitId': StringValue(habitId),
        'scheduledFor': DateTimeValue(scheduledFor),
        'status': EnumValue(status),
      },
    );

// ── Examples ────────────────────────────────────────────────────────────

void _basicSeries() {
  // The headline use case: one group-by, one measure → SeriesResult.
  final query = AnalyticsQuerySpec(
    source: 'tasks',
    measures: const [CountMeasure()],
    groupBys: const [
      FieldGroupBy(
        fieldRef: FieldRef(sourceId: 'tasks', fieldId: 'status'),
      ),
    ],
  );
  _runAndPrint(query, _taskRecords(), [_tasks]);
}

void _multiMeasure() {
  // One group-by, three measures of different aggregations → the
  // executor produces a MultiMeasureSeriesResult. Labels are left null
  // on each measure so the auto-generated `measure_0..measure_2` rule
  // applies; explicit labels are demonstrated in section 9.
  const priority = FieldRef(sourceId: 'tasks', fieldId: 'priority');
  const estimate = FieldRef(sourceId: 'tasks', fieldId: 'estimateHours');
  final query = AnalyticsQuerySpec(
    source: 'tasks',
    measures: const [
      CountMeasure(label: 'count'),
      FieldMeasure(
        fieldRef: priority,
        aggregation: SumAgg(),
        label: 'priority_sum',
      ),
      FieldMeasure(
        fieldRef: estimate,
        aggregation: AverageAgg(),
        label: 'avg_estimate',
      ),
    ],
    groupBys: const [
      FieldGroupBy(
        fieldRef: FieldRef(sourceId: 'tasks', fieldId: 'status'),
      ),
    ],
  );
  _runAndPrint(query, _taskRecords(), [_tasks]);
}

void _filterSortLimit() {
  // Only consider priority >= 2, then sort the resulting buckets by
  // count descending and keep the top 3. Sort targets are addressable
  // by either a group-field reference or a measure label.
  final query = AnalyticsQuerySpec(
    source: 'tasks',
    measures: const [CountMeasure(label: 'count')],
    groupBys: const [
      FieldGroupBy(
        fieldRef: FieldRef(sourceId: 'tasks', fieldId: 'status'),
      ),
    ],
    filters: const [
      Filter(
        fieldRef: FieldRef(sourceId: 'tasks', fieldId: 'priority'),
        operator: FilterOperator.greaterThanOrEqual,
        value: IntValue(2),
      ),
    ],
    sort: const Sort(
      target: MeasureValueSort(measureLabel: 'count'),
      direction: SortDirection.descending,
    ),
    limit: 3,
  );
  _runAndPrint(query, _taskRecords(), [_tasks]);
}

void _havingClause() {
  // HAVING filters at the bucket level — after grouping and
  // aggregation. Here it keeps only statuses whose count is >= 2.
  // Compare with Filter (section 3), which acts on records before
  // grouping.
  final query = AnalyticsQuerySpec(
    source: 'tasks',
    measures: const [CountMeasure(label: 'count')],
    groupBys: const [
      FieldGroupBy(
        fieldRef: FieldRef(sourceId: 'tasks', fieldId: 'status'),
      ),
    ],
    having: const HavingClause(
      operator: HavingOperator.greaterThanOrEqual,
      threshold: IntValue(2),
      measureLabel: 'count',
    ),
  );
  _runAndPrint(query, _taskRecords(), [_tasks]);
}

void _multiSeries() {
  // Two group-bys → MultiSeriesResult. The first group-by is the
  // primary axis; the second produces one named series per distinct
  // value, value-aligned to the primary.
  final query = AnalyticsQuerySpec(
    source: 'tasks',
    measures: const [CountMeasure()],
    groupBys: const [
      FieldGroupBy(
        fieldRef: FieldRef(sourceId: 'tasks', fieldId: 'status'),
      ),
      FieldGroupBy(
        fieldRef: FieldRef(sourceId: 'tasks', fieldId: 'priority'),
      ),
    ],
  );
  _runAndPrint(query, _taskRecords(), [_tasks]);
}

void _timeGroupedDensified() {
  // TimeGroupBy at day grain, with `dateRange` and the default
  // `densify: true` — every day in the range gets a bucket, even ones
  // with no observed records. Synthetic buckets carry `isSynthetic:
  // true` and an additive zero for `CountMeasure`.
  final query = AnalyticsQuerySpec(
    source: 'events',
    measures: const [CountMeasure()],
    groupBys: [
      TimeGroupBy(
        dateFieldRef: const FieldRef(sourceId: 'events', fieldId: 'occurredAt'),
        grain: TimeGrain.day,
      ),
    ],
  );
  _runAndPrint(
    query,
    _eventRecords(),
    [_events],
    dateRange: (DateTime(2026, 1, 5), DateTime(2026, 1, 10)),
  );
}

void _derivedCumulativeSum() {
  // Same time-grouped pipeline, with CumulativeSumOp applied as a
  // post-aggregation transform. The output is still a SeriesResult
  // with the same bucket layout; only the values change.
  final query = AnalyticsQuerySpec(
    source: 'events',
    measures: const [CountMeasure()],
    groupBys: [
      TimeGroupBy(
        dateFieldRef: const FieldRef(sourceId: 'events', fieldId: 'occurredAt'),
        grain: TimeGrain.day,
      ),
    ],
    derivedOperation: const CumulativeSumOp(),
  );
  _runAndPrint(
    query,
    _eventRecords(),
    [_events],
    dateRange: (DateTime(2026, 1, 5), DateTime(2026, 1, 10)),
  );
}

void _streak() {
  // StreakMeasure runs its own pipeline (no group-bys allowed) and
  // produces a TableResult with one row per entity, four columns:
  // entityId, displayLabel, currentStreak, longestStreak.
  final query = AnalyticsQuerySpec(
    source: 'habit_logs',
    measures: const [
      StreakMeasure(
        entityIdField: FieldRef(sourceId: 'habit_logs', fieldId: 'habitId'),
        scheduledDateField: FieldRef(
          sourceId: 'habit_logs',
          fieldId: 'scheduledFor',
        ),
        statusField: FieldRef(sourceId: 'habit_logs', fieldId: 'status'),
        completedStatusValue: 'done',
      ),
    ],
  );
  _runAndPrint(query, _habitRecords(), [
    _habitLogs,
  ], asOf: DateTime(2026, 1, 11));
}

void _columnAliasing() {
  // `GroupBy.label` overrides the column label the group-by projects
  // into the result. When the auto-generated column label would
  // collide with a measure's effective label, the validator now
  // returns `duplicateColumnLabel` — first showing the failure, then
  // resolving it with an alias.
  const ref = FieldRef(sourceId: 'tasks', fieldId: 'status');
  print(
    'Step 1: a query whose group column would collide with its measure label.',
  );
  final bad = AnalyticsQuerySpec(
    source: 'tasks',
    measures: const [
      CountMeasure(label: 'status'),
    ], // collides with the field id
    groupBys: const [FieldGroupBy(fieldRef: ref)],
  );
  switch (QueryValidator.validateQuery(bad, sources: [_tasks])) {
    case Ok():
      print('  (unexpected — validator should have rejected this)');
    case Err(error: final e):
      print('  validator rejected — ${e.kind.name}: ${e.humanMessage}');
  }

  print('');
  print('Step 2: same query with a `label:` on the group-by to disambiguate.');
  final good = AnalyticsQuerySpec(
    source: 'tasks',
    measures: const [CountMeasure(label: 'status')],
    groupBys: const [FieldGroupBy(fieldRef: ref, label: 'status_group')],
  );
  _runAndPrint(good, _taskRecords(), [_tasks]);
}

void _codecRoundtrip() {
  // Persist a query as JSON, decode it back, and confirm the decoded
  // value is structurally equal to the original. Useful for storing
  // user-built queries on disk or sending them over the wire.
  final query = AnalyticsQuerySpec(
    source: 'tasks',
    measures: const [CountMeasure(label: 'count')],
    groupBys: const [
      FieldGroupBy(
        fieldRef: FieldRef(sourceId: 'tasks', fieldId: 'status'),
        label: 'status_group',
      ),
    ],
    sort: const Sort(
      target: MeasureValueSort(measureLabel: 'count'),
      direction: SortDirection.descending,
      forceNullsLast: true,
    ),
  );
  final payload = SingleQuerySpec(query: query);

  final encoded = WidgetPayloadCodec.encodeQueryPayload(payload);
  print('Encoded JSON:');
  print('  $encoded');

  final decoded = WidgetPayloadCodec.decodeQueryPayload(encoded);
  print('');
  print('Decoded == original?  ${decoded == payload}');
}

// ── Helpers ─────────────────────────────────────────────────────────────

/// Validates [query], executes it against [records] and [sources], and
/// prints the result. Optional [asOf] / [dateRange] match
/// [AnalyticsExecutor.execute]'s named parameters.
void _runAndPrint(
  AnalyticsQuerySpec query,
  List<SourceRecord> records,
  List<SourceDef> sources, {
  DateTime? asOf,
  (DateTime, DateTime)? dateRange,
}) {
  switch (QueryValidator.validateQuery(query, sources: sources)) {
    case Ok():
      break;
    case Err(error: final e):
      print('Validation failed: ${e.humanMessage}');
      return;
  }
  final result = AnalyticsExecutor.execute(
    query: query,
    records: records,
    sources: sources,
    asOf: asOf,
    dateRange: dateRange,
  );
  switch (result) {
    case Ok(value: final r):
      _printResult(r);
    case Err(error: final e):
      print('Execution failed: ${e.humanMessage}');
  }
}

/// Dispatches on [AnalyticsResult]'s five concrete shapes and prints
/// each in a readable form. This isn't part of the library — it's the
/// kind of presentation glue a host application writes once.
void _printResult(AnalyticsResult result) {
  switch (result) {
    case ScalarResult(value: final v, measureLabel: final label):
      print('  ${label ?? 'value'}: ${_typed(v)}');

    case SeriesResult(buckets: final buckets):
      for (final b in buckets) {
        final mark = b.isSynthetic ? ' (synthetic)' : '';
        print('  ${_key(b.key).padRight(12)} → ${_typed(b.value)}$mark');
      }

    case MultiSeriesResult(
      xAxis: final xs,
      series: final ns,
      secondaryColumnLabel: final secondary,
    ):
      final header = ns.map((s) => _key(s.key)).join(' | ');
      print('  ${''.padRight(12)} | $secondary: $header');
      for (var i = 0; i < xs.length; i++) {
        final row = ns.map((s) => _typed(s.values[i]).padRight(6)).join(' | ');
        print('  ${_key(xs[i].key).padRight(12)} | $row');
      }

    case MultiMeasureSeriesResult(xAxis: final xs, series: final ms):
      final header = ms.map((s) => s.label.padRight(14)).join(' | ');
      print('  ${''.padRight(12)} | $header');
      for (var i = 0; i < xs.length; i++) {
        final row = ms.map((s) => _typed(s.values[i]).padRight(14)).join(' | ');
        print('  ${_key(xs[i].key).padRight(12)} | $row');
      }

    case TableResult(columns: final cols, rowKeys: final rks):
      // Width per column is the wider of the label and the longest
      // formatted value in that column.
      final widths = [
        for (final c in cols)
          [
            c.label.length,
            ...c.values.map((v) => _typed(v).length),
          ].reduce((a, b) => a > b ? a : b),
      ];
      final header = [
        for (var i = 0; i < cols.length; i++) cols[i].label.padRight(widths[i]),
      ].join(' | ');
      print('  $header');
      print('  ${'-' * header.length}');
      for (var r = 0; r < rks.length; r++) {
        final row = [
          for (var i = 0; i < cols.length; i++)
            _typed(cols[i].values[r]).padRight(widths[i]),
        ].join(' | ');
        print('  $row');
      }
  }
}

String _key(BucketKey k) => switch (k) {
  StringBucketKey(value: final v) => v,
  EnumBucketKey(value: final v) => v,
  BoolBucketKey(value: final v) => v.toString(),
  IntBucketKey(value: final v) => v.toString(),
  DoubleBucketKey(value: final v) => v.toString(),
  TimeBucketKey(instant: final t) =>
    '${t.year.toString().padLeft(4, '0')}-'
        '${t.month.toString().padLeft(2, '0')}-'
        '${t.day.toString().padLeft(2, '0')}',
  NullBucketKey() => '∅',
};

String _typed(TypedValue? v) {
  if (v == null) return '∅';
  return switch (v) {
    StringValue(value: final s) => s,
    EnumValue(value: final s) => s,
    BoolValue(value: final b) => b.toString(),
    IntValue(value: final i) => i.toString(),
    DoubleValue(value: final d) => d.toStringAsFixed(2),
    DateTimeValue(value: final t) =>
      '${t.year.toString().padLeft(4, '0')}-'
          '${t.month.toString().padLeft(2, '0')}-'
          '${t.day.toString().padLeft(2, '0')}',
    DurationValue(value: final d) => '${d.inSeconds}s',
    StringListValue(values: final xs) => xs.join(','),
    EnumListValue(values: final xs) => xs.join(','),
    IntListValue(values: final xs) => xs.join(','),
    NullValue() => '∅',
  };
}
