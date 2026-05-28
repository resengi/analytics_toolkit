/// Typed change events for analytics dashboard controllers.
///
/// A controller emits `AnalyticsChange` to signal what changed so
/// listeners can apply targeted invalidation rules — e.g. "only
/// reload if my source is in `sourceIds`", or "ignore page-range
/// changes for streak widgets that don't take a date range."
///
/// Without a typed change event, every controller notification looks
/// the same and every listener has to refetch everything; the typed
/// event lets listeners decide whether they care.
///
/// ## Locked semantics
///
/// | Kind          | Meaning                                                       | Required metadata          |
/// |---------------|---------------------------------------------------------------|----------------------------|
/// | `dateRange`   | Page-level resolved date range changed.                       | none                       |
/// | `widgetSet`   | Exactly one widget's spec changed (create / update / delete). | `widgetId` populated       |
/// | `widgetOrder` | Pure layout reorder. No widget needs to refetch data.         | none                       |
/// | `sourceData`  | Underlying records mutated.                                   | `sourceIds` (null = all)   |
/// | `restore`     | Single-widget restore (undo).                                 | `widgetId` populated       |
///
/// Bulk operations do **not** piggyback on `widgetSet`. Multi-widget
/// restore is out of scope; if it becomes a use case, add a
/// `widgetIds: Set<String>` field rather than overloading `widgetId`.
enum AnalyticsChangeKind {
  dateRange,
  widgetSet,
  widgetOrder,
  sourceData,
  restore,
}

/// A single typed change event.
///
/// Typically carried as a `ValueNotifier<AnalyticsChange?>` — the
/// controller is widget-scoped, listeners are local, and only the
/// latest change matters (no replay or backpressure needed).
class AnalyticsChange {
  AnalyticsChange({required this.kind, this.widgetId, Set<String>? sourceIds})
    : sourceIds = sourceIds == null ? null : Set.unmodifiable(sourceIds);

  final AnalyticsChangeKind kind;

  /// Populated for [AnalyticsChangeKind.widgetSet] and
  /// [AnalyticsChangeKind.restore].
  final String? widgetId;

  /// Populated for [AnalyticsChangeKind.sourceData]. `null` means
  /// "treat as all sources" — i.e. the change scope is unknown, so
  /// invalidate conservatively.
  final Set<String>? sourceIds;

  @override
  String toString() =>
      'AnalyticsChange(${kind.name}, widgetId: $widgetId, sourceIds: $sourceIds)';
}
