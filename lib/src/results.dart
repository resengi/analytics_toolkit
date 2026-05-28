/// The result-type family produced by query execution.
///
/// This file is the library declaration; the type definitions live in
/// the `results/` subdirectory and are joined here via `part`. Start
/// with [AnalyticsResult] (in `results/table_result.dart`) for the
/// family overview.
library;

import 'equality.dart';
import 'schema/schema.dart';
import 'schema/typed_value.dart';
import 'time_series/time_grain.dart';

part 'results/bucket_key.dart';
part 'results/series_result.dart';
part 'results/table_result.dart';
