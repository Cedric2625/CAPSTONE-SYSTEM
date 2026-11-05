/// "just now", "5m ago", "3h ago", "2d ago" — the one relative-time format used
/// across the app. [capitalize] is for when it stands alone as a value
/// ("Just now") rather than inside a sentence ("Reported just now").
String timeAgo(DateTime t, {bool capitalize = false}) {
  final diff = DateTime.now().difference(t);
  final text = diff.inMinutes < 1
      ? 'just now'
      : diff.inMinutes < 60
          ? '${diff.inMinutes}m ago'
          : diff.inHours < 24
              ? '${diff.inHours}h ago'
              : '${diff.inDays}d ago';
  return capitalize ? '${text[0].toUpperCase()}${text.substring(1)}' : text;
}
