import 'package:flutter_test/flutter_test.dart';
import 'package:passport_mdac_app/main.dart';
import 'package:passport_mdac_app/supabase_gateway.dart';

void main() {
  test('supportedAutomationTaskTypes contains all 4 modules', () {
    expect(SupabaseGateway.supportedAutomationTaskTypes, containsAll([
      'MDAC_REGISTRATION',
      'GMAIL_PIN',
      'REGISTRATION_CHECK',
      'VISIT_PASS_CHECK',
    ]));
  });

  test('DemoRepository manages latest tasks vs history tasks separately', () async {
    final repo = DemoRepository();
    repo.tasks.clear();
    expect(repo.tasks.isEmpty, isTrue);
    expect(repo.historyTasks.isEmpty, isTrue);

    final latestTask = AutomationTask(
      id: 'batch-latest-1',
      type: TaskType.mdacRegistration,
      customerIds: ['c-001', 'c-002'],
      createdAt: DateTime.now(),
      createdBy: 'test',
      status: TaskStatus.succeeded,
      successCount: 2,
      failedCount: 0,
    );
    repo.tasks.add(latestTask);

    final historyTask = AutomationTask(
      id: 'batch-hist-old',
      type: TaskType.visitPassCheck,
      customerIds: const [],
      createdAt: DateTime.now().subtract(const Duration(days: 5)),
      createdBy: 'test',
      status: TaskStatus.succeeded,
      successCount: 10,
      failedCount: 0,
      items: const [],
    );
    repo.historyTasks.add(historyTask);

    expect(repo.tasks.length, equals(1));
    expect(repo.historyTasks.length, equals(1));
    expect(repo.activeTaskForCustomer('c-001'), isNull);
  });
}
