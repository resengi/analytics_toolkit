/// A display specification for an analytics widget.
///
/// `DisplaySpec` is the part of an [AnalyticsWidgetSpec] that tells
/// the host *how* to present a query result. The package itself is
/// rendering-agnostic — it never inspects or interprets the
/// [displayType] string. Consumers are free to use any vocabulary
/// that fits their renderer: `'bar'`, `'line'`, `'table'`, `'pie'`,
/// `'sparkline'`, custom tokens, semantic types — all are valid.
///
/// Persistence is via [WidgetPayloadCodec.encodeDisplaySpec] /
/// [decodeDisplaySpec]. The on-disk JSON shape is intentionally
/// minimal so future fields (axis hints, formatting, color hints, …)
/// can be added without breaking existing payloads — unrecognized
/// keys are ignored on decode.
class DisplaySpec {
  const DisplaySpec({required this.displayType});

  /// Free-form discriminator naming the display kind. Opaque to
  /// `analytics_toolkit`; meaning is consumer-defined.
  final String displayType;

  @override
  bool operator ==(Object other) =>
      other is DisplaySpec && displayType == other.displayType;

  @override
  int get hashCode => displayType.hashCode;

  @override
  String toString() => 'DisplaySpec(displayType=$displayType)';
}
