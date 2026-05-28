import 'schema.dart';

/// Returns the [SourceDef] with the given id, or null if none matches.
///
/// Shared helper used by the executor, validator, and any other
/// component that needs to resolve a source ID from a catalog.
///
/// Linear scan is intentional: source lists are small (single digits)
/// and constructed per call, so the cost of building a map is not
/// worth it.
SourceDef? findSourceById(List<SourceDef> sources, String id) {
  for (final s in sources) {
    if (s.sourceId == id) return s;
  }
  return null;
}
