/// Element-wise list equality. Identity-fast for the same reference,
/// length-fast for different lengths, otherwise pairwise `==`.
bool listEqualsByValue<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Hash mix-in for a list whose elements implement `==` and
/// `hashCode`. Delegates to [Object.hashAll].
int listHashByValue<T>(List<T> values) => Object.hashAll(values);
