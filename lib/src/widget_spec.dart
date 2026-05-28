/// A user-defined analytics widget definition.
///
/// One instance per widget in a dashboard. The class carries
/// identity, ordering, timestamps, and three opaque JSON payloads:
///
/// - [queryJson] — serialized `QueryPayload` (single or paired query)
/// - [displayJson] — serialized display spec (display type + options)
/// - [dateRangeModeJson] — serialized `DateRangeMode`
///
/// The JSON shape is defined and validated by `WidgetPayloadCodec`,
/// which is the only entry point for reading and writing these
/// fields. Storing them as opaque strings — rather than typed columns
/// — keeps the database schema stable as the contract evolves:
/// adding a new `Measure` case or `DerivedOperation` case is a codec
/// change, not a schema migration.
///
/// The [schemaVersion] field allows future shape changes to be
/// detected. Callers should invoke
/// `WidgetPayloadCodec.ensureCanDecode(spec)` immediately after
/// loading a spec from storage and before decoding any of its inner
/// JSON blobs. Specs with `schemaVersion >
/// WidgetPayloadCodec.currentSchemaVersion` are rejected with a
/// `FormatException`. Specs constructed without an explicit
/// `schemaVersion` are treated as schema version 1 and decode
/// normally.
///
/// ## Equality
///
/// `==` and `hashCode` are **id-based**, not structural. Two specs
/// with the same [id] but different content are considered equal,
/// because the spec models a persisted entity — its identity is the
/// [id], not the snapshot of its fields. Use [copyWith] (or
/// re-decoding) when you need to detect content changes; comparing
/// the JSON strings is the simplest deep-equality check.
class AnalyticsWidgetSpec {
  const AnalyticsWidgetSpec({
    required this.id,
    required this.title,
    required this.queryJson,
    required this.displayJson,
    required this.dateRangeModeJson,
    required this.sortOrder,
    required this.createdAt,
    required this.updatedAt,
    this.schemaVersion = 1,
  });

  /// Stable identifier. Typically a UUID.
  final String id;

  /// User-supplied widget title.
  final String title;

  /// Serialized `QueryPayload` (single or paired query). Use
  /// `WidgetPayloadCodec.decodeQueryPayload` to parse.
  final String queryJson;

  /// Serialized display spec — display type and optional options.
  /// Use `WidgetPayloadCodec.decodeDisplaySpec` to parse.
  final String displayJson;

  /// Serialized `DateRangeMode`. Use
  /// `WidgetPayloadCodec.decodeDateRangeMode` to parse.
  final String dateRangeModeJson;

  /// Position in the dashboard list. 0 = top.
  final int sortOrder;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// Persistence schema version. See class docs.
  final int schemaVersion;

  AnalyticsWidgetSpec copyWith({
    String? id,
    String? title,
    String? queryJson,
    String? displayJson,
    String? dateRangeModeJson,
    int? sortOrder,
    DateTime? createdAt,
    DateTime? updatedAt,
    int? schemaVersion,
  }) {
    return AnalyticsWidgetSpec(
      id: id ?? this.id,
      title: title ?? this.title,
      queryJson: queryJson ?? this.queryJson,
      displayJson: displayJson ?? this.displayJson,
      dateRangeModeJson: dateRangeModeJson ?? this.dateRangeModeJson,
      sortOrder: sortOrder ?? this.sortOrder,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      schemaVersion: schemaVersion ?? this.schemaVersion,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AnalyticsWidgetSpec && id == other.id;

  @override
  int get hashCode => id.hashCode;
}
