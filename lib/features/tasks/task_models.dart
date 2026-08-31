enum TaskType { mdacRegistration, gmailPin, registrationCheck, visitPassCheck }

enum TaskStatus {
  queued,
  running,
  succeeded,
  partialSuccess,
  failed,
  needsReview,
}

bool isInProgressTaskStatus(TaskStatus status) {
  return status == TaskStatus.queued ||
      status == TaskStatus.running ||
      status == TaskStatus.needsReview;
}

class AutomationTask {
  AutomationTask({
    required this.id,
    required this.type,
    required this.customerIds,
    required this.createdAt,
    required this.createdBy,
    this.entryDate,
    this.exitDate,
    this.status = TaskStatus.queued,
    this.successCount = 0,
    this.failedCount = 0,
    this.note = '',
  });

  final String id;
  final TaskType type;
  final List<String> customerIds;
  final DateTime createdAt;
  final String createdBy;
  final DateTime? entryDate;
  final DateTime? exitDate;
  TaskStatus status;
  int successCount;
  int failedCount;
  String note;

  int get totalCount => customerIds.length;
  int get completedCount => successCount + failedCount;
  double get progress => totalCount == 0 ? 0 : completedCount / totalCount;
}
