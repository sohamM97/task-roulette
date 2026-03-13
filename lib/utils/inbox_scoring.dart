const _stopWords = <String>{
  'a', 'an', 'the', 'and', 'or', 'but', 'in', 'on', 'at', 'to', 'for',
  'of', 'with', 'by', 'from', 'is', 'it', 'my', 'do', 'up',
};

/// Tokenizes a name into lowercase word tokens, filtering stop words.
Set<String> tokenize(String name) {
  final words = name.toLowerCase().split(RegExp(r'\W+'));
  return words.where((w) => w.isNotEmpty && !_stopWords.contains(w)).toSet();
}

/// Jaccard similarity between two token sets. Returns 0 if both are empty.
double jaccardSimilarity(Set<String> a, Set<String> b) {
  if (a.isEmpty && b.isEmpty) return 0.0;
  final intersection = a.intersection(b).length;
  final union = a.union(b).length;
  return intersection / union;
}

/// Returns 1.0 if either name contains the other as a substring (case-insensitive),
/// 0.0 otherwise. Catches cases like "Groceries" matching "Buy groceries".
double substringMatch(String a, String b) {
  final aLower = a.toLowerCase();
  final bLower = b.toLowerCase();
  if (aLower.contains(bLower) || bLower.contains(aLower)) return 1.0;
  return 0.0;
}
