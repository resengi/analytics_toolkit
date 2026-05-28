import 'query/measure.dart';
import 'query/query_spec.dart';
import 'results.dart';

/// Pure function that computes the result shape a query payload would
/// produce, without executing it.
///
/// A builder UI can call this before display selection to populate the
/// list of compatible display types. It is total and deterministic.
///
/// Inference rules:
/// - `StreakMeasure` → `table`
/// - 1 measure + 0 group-bys → `scalar`
/// - 1 measure + 1 group-by  → `series`
/// - 1 measure + 2 group-bys → `multiSeries`
/// - N>1 measures + 1 group-by → `multiMeasureSeries`
/// - everything else with non-streak measures → `table`
/// - `PairedQuerySpec` → `pairedSeries`
///
/// For paired payloads, this function always reports `pairedSeries`
/// without inspecting the inner queries. The validator separately
/// enforces that both halves infer to `series` (and rejects the
/// payload with `incompatiblePairedQueryShapes` otherwise).
abstract class InferResultShape {
  /// Inference for a full payload.
  static ResultShape ofPayload(QueryPayload payload) {
    switch (payload) {
      case SingleQuerySpec(query: final q):
        return ofQuery(q);
      case PairedQuerySpec():
        return ResultShape.pairedSeries;
    }
  }

  /// Inference for a single query.
  static ResultShape ofQuery(AnalyticsQuerySpec query) {
    // Streak is its own shape regardless of how many measures or
    // group-bys appear in the spec. The validator enforces that a
    // streak query has exactly one measure (the streak) and zero
    // group-bys, so reaching here with a streak measure means the
    // spec is well-formed.
    if (query.measures.any((m) => m is StreakMeasure)) {
      return ResultShape.table;
    }
    final groupCount = query.groupBys.length;
    final measureCount = query.measures.length;

    // Single-measure shapes: cardinality drives the result type.
    if (measureCount == 1) {
      switch (groupCount) {
        case 0:
          return ResultShape.scalar;
        case 1:
          return ResultShape.series;
        case 2:
          return ResultShape.multiSeries;
        default:
          // 3 group-bys (capped at 3 by the validator) — foundational
          // table shape.
          return ResultShape.table;
      }
    }

    // Multi-measure shapes. Only the 1-groupBy case is a chart-shape
    // view (`MultiMeasureSeriesResult`); everything else (0, 2, or 3
    // group-bys) goes to the foundational `TableResult`.
    if (groupCount == 1) {
      return ResultShape.multiMeasureSeries;
    }
    return ResultShape.table;
  }
}
