import 'package:flutter_test/flutter_test.dart';
import 'package:passport_mdac_app/features/tasks/task_models.dart';

void main() {
  group('AutomationTask', () {
    test('reports progress from successful and failed items', () {
      final task = AutomationTask(
        id: 'batch-1',
        type: TaskType.gmailPin,
        customerIds: const [
          'customer-1',
          'customer-2',
          'customer-3',
          'customer-4',
        ],
        createdAt: DateTime(2026, 8, 31),
        createdBy: 'Tester',
        successCount: 2,
        failedCount: 1,
      );

      expect(task.totalCount, 4);
      expect(task.completedCount, 3);
      expect(task.progress, 0.75);
    });

    test('reports zero progress for an empty task', () {
      final task = AutomationTask(
        id: 'batch-empty',
        type: TaskType.registrationCheck,
        customerIds: const [],
        createdAt: DateTime(2026, 8, 31),
        createdBy: 'Tester',
      );

      expect(task.progress, 0);
    });
  });

  test('active statuses include manual review but exclude terminal states', () {
    expect(isInProgressTaskStatus(TaskStatus.queued), isTrue);
    expect(isInProgressTaskStatus(TaskStatus.running), isTrue);
    expect(isInProgressTaskStatus(TaskStatus.needsReview), isTrue);
    expect(isInProgressTaskStatus(TaskStatus.succeeded), isFalse);
    expect(isInProgressTaskStatus(TaskStatus.partialSuccess), isFalse);
    expect(isInProgressTaskStatus(TaskStatus.failed), isFalse);
  });
}
