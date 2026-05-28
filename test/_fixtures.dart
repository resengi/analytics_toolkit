import 'package:analytics_toolkit/analytics_toolkit.dart';

/// Shared test fixtures. Constructor-only — no execution helpers.
///
/// Two sources cover the common axes the rest of the suite needs:
///
/// - [tasksSource] — purely categorical, no `primaryDateFieldId`. Used
///   by tests that exercise non-temporal validation and execution
///   paths (filters, categorical grouping, sort over categorical
///   keys).
/// - [eventsSource] — temporal, with `primaryDateFieldId: 'occurredAt'`.
///   Used by tests that exercise `TimeGroupBy`, `DateRangeProjector`,
///   densification with a date range, and the streak pipeline.
///
/// Files needing a wider field-type matrix or a streak-specific shape
/// build their own `SourceDef` locally. The intent is to keep this
/// file small enough that any test can read it in 30 seconds and
/// understand exactly what it's getting.

/// A purely-categorical source — no `primaryDateFieldId`.
SourceDef tasksSource() => SourceDef(
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
      fieldId: 'title',
      displayName: 'Title',
      fieldType: FieldType.string,
      filterable: true,
      groupable: false,
      aggregatable: false,
      sortable: true,
    ),
  ],
);

/// A temporal source with a `primaryDateFieldId`.
SourceDef eventsSource() => SourceDef(
  sourceId: 'events',
  displayName: 'Events',
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
    FieldDef(
      sourceId: 'events',
      fieldId: 'kind',
      displayName: 'Kind',
      fieldType: FieldType.enumeration,
      filterable: true,
      groupable: true,
      aggregatable: false,
      sortable: true,
    ),
    FieldDef(
      sourceId: 'events',
      fieldId: 'amount',
      displayName: 'Amount',
      fieldType: FieldType.integer,
      filterable: true,
      groupable: false,
      aggregatable: true,
      sortable: true,
    ),
  ],
  primaryDateFieldId: 'occurredAt',
);

/// Builds a `FieldRef` for one of the standard sources, saving the
/// repeated `FieldRef(sourceId: ..., fieldId: ...)` call at test sites.
FieldRef ref(String sourceId, String fieldId) =>
    FieldRef(sourceId: sourceId, fieldId: fieldId);
