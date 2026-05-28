/// Closed set of supported field types.
///
/// Field type names are persisted by `.name` in query payloads —
/// renaming a value is a breaking change.
enum FieldType {
  string,
  enumeration,
  integer,
  double,
  boolean,
  dateTime,
  duration,
}

/// A stable typed reference to a field on a source.
///
/// Two `FieldRef`s are equal iff their `(sourceId, fieldId)` are equal.
class FieldRef {
  const FieldRef({required this.sourceId, required this.fieldId});

  final String sourceId;
  final String fieldId;

  @override
  bool operator ==(Object other) =>
      other is FieldRef &&
      sourceId == other.sourceId &&
      fieldId == other.fieldId;

  @override
  int get hashCode => Object.hash(sourceId, fieldId);

  @override
  String toString() => '$sourceId#$fieldId';
}

/// A field declaration on a source.
///
/// Capability flags are advisory hints from the source provider — the
/// validator enforces them, and the executor trusts queries the
/// validator has accepted.
class FieldDef {
  const FieldDef({
    required this.fieldId,
    required this.sourceId,
    required this.displayName,
    required this.fieldType,
    required this.filterable,
    required this.groupable,
    required this.aggregatable,
    required this.sortable,
  });

  final String fieldId;
  final String sourceId;
  final String displayName;
  final FieldType fieldType;
  final bool filterable;
  final bool groupable;
  final bool aggregatable;
  final bool sortable;

  /// Convenience: returns a `FieldRef` pointing at this field.
  FieldRef get ref => FieldRef(sourceId: sourceId, fieldId: fieldId);
}

/// A source declaration.
///
/// A source represents a queryable collection of records (a table, a
/// list, a database view, etc).
///
/// [primaryDateFieldId] is optional. When set, it names the
/// `dateTime` field used for **page-level date-range projection**
/// (`DateRangeProjector`) and **cross-source temporal alignment** in
/// paired queries — it tells the system which date field to filter
/// against when a page's date range applies. `TimeGroupBy` works on
/// any `dateTime` field declared on the source regardless of primary
/// status; the primary is only the default for date-range projection.
///
/// The validator rejects date-range projection and cross-source
/// alignment against a source with no primary date field.
///
/// **Note:** Not a `const` constructor — `SourceDef` uses a lazy
/// `_fieldsById` cache for amortized-O(1) field lookup, which
/// requires instance state. Build sources with `SourceDef(...)`, not
/// `const SourceDef(...)`.
class SourceDef {
  SourceDef({
    required this.sourceId,
    required this.displayName,
    required List<FieldDef> fields,
    this.primaryDateFieldId,
  }) : fields = List.unmodifiable(fields) {
    final seenIds = <String>{};
    for (final f in fields) {
      if (f.sourceId != sourceId) {
        throw ArgumentError.value(
          f.sourceId,
          'fields',
          'Field ${f.fieldId} declares sourceId ${f.sourceId} but '
              'belongs to SourceDef $sourceId.',
        );
      }
      if (!seenIds.add(f.fieldId)) {
        throw ArgumentError.value(
          f.fieldId,
          'fields',
          'Duplicate fieldId in SourceDef $sourceId.',
        );
      }
    }
    if (primaryDateFieldId != null) {
      final f = this.fields.firstWhere(
        (f) => f.fieldId == primaryDateFieldId,
        orElse: () => throw ArgumentError.value(
          primaryDateFieldId,
          'primaryDateFieldId',
          'No field with this id is declared on the source.',
        ),
      );
      if (f.fieldType != FieldType.dateTime) {
        throw ArgumentError.value(
          primaryDateFieldId,
          'primaryDateFieldId',
          'Must reference a dateTime field; got ${f.fieldType.name}.',
        );
      }
    }
  }

  final String sourceId;
  final String displayName;
  final List<FieldDef> fields;

  /// The id of the `dateTime` field in [fields] used for time-series
  /// operations. Null means this source is non-temporal.
  ///
  /// If non-null, must reference a field in [fields] whose
  /// `fieldType == FieldType.dateTime`. The validator checks this when
  /// a query against this source uses a time-series operation.
  final String? primaryDateFieldId;

  /// Lazy field-id → [FieldDef] index, built on first access. Source
  /// definitions with many fields used in queries with many filters /
  /// group-bys would otherwise pay O(N×M) for linear-scan lookups; this
  /// flips it to amortized O(1) after a single build.
  late final Map<String, FieldDef> _fieldsById = {
    for (final f in fields) f.fieldId: f,
  };

  /// Looks up a field by id. Returns null if not found.
  ///
  /// Amortized O(1) via a lazy id → field map built on first access.
  FieldDef? fieldById(String fieldId) => _fieldsById[fieldId];

  /// Returns the field referenced by [primaryDateFieldId], or null if
  /// this source is non-temporal or the declaration is malformed.
  FieldDef? get primaryDateField {
    final id = primaryDateFieldId;
    if (id == null) return null;
    return fieldById(id);
  }
}
