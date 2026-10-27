/// Counts one current task per item ID. Attempts and result rows are not tasks.
class TaskCounts {
  TaskCounts(Iterable<Map<String, dynamic>> rows) : items = _unique(rows);

  final List<Map<String, dynamic>> items;

  static List<Map<String, dynamic>> _unique(
    Iterable<Map<String, dynamic>> rows,
  ) {
    final byId = <String, Map<String, dynamic>>{};
    var anonymous = 0;
    for (final row in rows) {
      final id = row['id']?.toString();
      byId[id == null || id.isEmpty ? 'anonymous-${anonymous++}' : id] = row;
    }
    return byId.values.toList(growable: false);
  }

  int count(String status) => items.where((i) => i['status'] == status).length;
  int get total => items.length;
  int get succeeded => count('SUCCEEDED');
  int get failed => count('FAILED');
  int get review => count('NEEDS_REVIEW');
  int get completed => succeeded + failed;
  bool get blocked => items.any(
    (i) =>
        const ['QUEUED', 'CLAIMED', 'RUNNING'].contains(i['status']) ||
        i['result_unknown'] == true ||
        (i['submission_started_at'] != null && i['status'] != 'SUCCEEDED'),
  );
  int get retryable => blocked
      ? 0
      : items
            .where(
              (i) =>
                  i['status'] == 'FAILED' &&
                  i['result_unknown'] == false &&
                  i.containsKey('submission_started_at') &&
                  i['submission_started_at'] == null &&
                  (int.tryParse('${i['attempt_count']}') ?? 5) < 5,
            )
            .length;
}
