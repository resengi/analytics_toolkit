/// Closed set of filter operators.
///
/// Compatibility with `FieldType` is enforced by the validator.
enum FilterOperator {
  equals,
  notEquals,
  lessThan,
  lessThanOrEqual,
  greaterThan,
  greaterThanOrEqual,
  inList,
}

/// Sort direction.
enum SortDirection { ascending, descending }

/// Comparison operators usable inside a `HavingClause` to filter
/// aggregated bucket values against a threshold.
///
/// This is a strict subset of `FilterOperator` (the six ordered /
/// equality operators, with `inList` deliberately omitted). The
/// duplication is intentional rather than DRY-violating: `FilterOperator`
/// is a filter-stage concern; `HavingOperator` is a post-aggregation
/// concern, and the two operator sets are structurally different
/// (HAVING has no meaningful `inList` analogue — bucket values are
/// scalars compared against a single threshold). Having each context
/// declare exactly the operators it accepts keeps validator logic
/// free of "is this operator legal here" branches and matches the
/// single-responsibility instinct elsewhere in the codebase.
enum HavingOperator {
  equals,
  notEquals,
  lessThan,
  lessThanOrEqual,
  greaterThan,
  greaterThanOrEqual,
}
