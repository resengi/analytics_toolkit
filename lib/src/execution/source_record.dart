import '../schema/typed_value.dart';

/// A normalized analytics record produced by a source provider.
///
/// The executor only knows about field IDs and `TypedValue`s — it has
/// no knowledge of the domain semantics behind any field. The source
/// provider is responsible for emitting records whose `fields` map
/// keys match the `fieldId`s declared in the source's `FieldDef`s
/// and whose values are [TypedValue]s of the declared subtype. The
/// executor verifies the latter at the top of every pipeline and
/// returns [AnalyticsErrorKind.sourceRecordTypeMismatch] when a record
/// violates this contract.
///
/// `SourceRecord` is intentionally a thin wrapper around a map. It
/// does not enforce schema matching at construction time. Absent
/// fields are returned as Dart `null` from [operator []]; downstream
/// engines treat that as "no value for this record" and skip it from
/// aggregations and groupings. An explicit [NullValue] in [fields]
/// means "the provider intentionally emitted a null" and is also
/// skipped by aggregations.
///
/// ## Field absence: omission vs explicit `NullValue`
///
/// The two ways to express "no value for this field" sit side by side:
///
/// ```dart
/// // Record A: the `note` field is simply omitted.
/// final a = SourceRecord(fields: {
///   'amount': const IntValue(12),
///   // 'note' not present — record['note'] returns Dart null.
/// });
///
/// // Record B: the `note` field is present but explicitly null.
/// final b = SourceRecord(fields: {
///   'amount': const IntValue(7),
///   'note': const NullValue(FieldType.string), // intentional absence.
/// });
/// ```
///
/// Both records skip `note` for every aggregation, group-by, and
/// filter match — the two forms are interchangeable downstream. Use
/// the explicit `NullValue` when the field is declared on the source
/// and the provider wants to make the absence intentional (it reads
/// more clearly than a missing key, and survives any future code
/// that iterates declared keys rather than the underlying map).
class SourceRecord {
  SourceRecord({required Map<String, TypedValue> fields})
    : fields = Map.unmodifiable(fields);

  /// Field values keyed by `fieldId`.
  final Map<String, TypedValue> fields;

  /// Returns the typed value for [fieldId], or null if the record has
  /// no entry for that field.
  ///
  /// A record that explicitly contains `NullValue` for a field
  /// returns that `NullValue`, not Dart `null`. The two are
  /// semantically distinct but treated the same way by every
  /// downstream engine — both signal "no value for this record" and
  /// are skipped from aggregations, groupings, and filter matches.
  /// Source providers may use either form to express absence; the
  /// explicit `NullValue` is preferred when the field is declared and
  /// the provider wants to make the absence intentional.
  TypedValue? operator [](String fieldId) => fields[fieldId];
}
