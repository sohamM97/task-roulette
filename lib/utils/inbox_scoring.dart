export 'dart:math' show exp;

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
