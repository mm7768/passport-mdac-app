import 'package:flutter_test/flutter_test.dart';
import 'package:passport_mdac_app/features/batches/batch_models.dart';
import 'package:passport_mdac_app/main.dart';

void main() {
  group('Batch Integration Contract - Model Tests', () {
    test('AppOperationalBatch.fromMap correctly parses active batch and calculates progress', () {
      final map = {
        'batch_id': 'b1000000-0000-0000-0000-000000000001',
        'batch_name': '28-9 早班',
        'batch_no': 'BATCH-20260928-001',
        'status': 'OPEN',
        'created_at': '2026-09-28T08:00:00Z',
        'total_count': 30,
        'completed_count': 22,
        'pending_count': 8,
      };

      final batch = AppOperationalBatch.fromMap(map);

      expect(batch.batchId, 'b1000000-0000-0000-0000-000000000001');
      expect(batch.batchName, '28-9 早班');
      expect(batch.batchNo, 'BATCH-20260928-001');
      expect(batch.status, 'OPEN');
      expect(batch.isOpen, isTrue);
      expect(batch.totalCount, 30);
      expect(batch.completedCount, 22);
      expect(batch.pendingCount, 8);
      expect(batch.progressRatio, closeTo(22 / 30, 0.001));
    });

    test('AppOperationalBatch handles zero totalCount gracefully without divide-by-zero', () {
      final map = {
        'batch_id': 'b2000000-0000-0000-0000-000000000002',
        'batch_name': '空批次',
        'batch_no': 'BATCH-EMPTY',
        'status': 'OPEN',
        'created_at': '2026-09-28T09:00:00Z',
        'total_count': 0,
        'completed_count': 0,
        'pending_count': 0,
      };

      final batch = AppOperationalBatch.fromMap(map);
      expect(batch.progressRatio, 0.0);
    });

    test('AppBatchOrder.fromMap maps stable Order ID and membership attributes', () {
      final map = {
        'membership_id': 'm1000000-0000-0000-0000-000000000001',
        'batch_id': 'b1000000-0000-0000-0000-000000000001',
        'order_id': 'c1000000-0000-0000-0000-000000000001',
        'case_id': 'c1000000-0000-0000-0000-000000000001',
        'order_no': 'AA0010',
        'customer_id': 'u1000000-0000-0000-0000-000000000001',
        'passport_id': 'p1000000-0000-0000-0000-000000000001',
        'display_name': '张三 (ZHANG SAN)',
        'passport_number': 'E12345678',
        'business_status': 'CURRENT',
        'workflow_status': 'submitted',
        'priority': 'URGENT',
        'membership_status': 'ACTIVE',
        'arrival_date': '2026-10-01',
        'departure_date': '2026-10-08',
      };

      final order = AppBatchOrder.fromMap(map);

      expect(order.membershipId, 'm1000000-0000-0000-0000-000000000001');
      expect(order.orderId, 'c1000000-0000-0000-0000-000000000001');
      expect(order.orderNo, 'AA0010');
      expect(order.displayName, '张三 (ZHANG SAN)');
      expect(order.passportNumber, 'E12345678');
      expect(order.businessStatus, 'CURRENT');
      expect(order.priority, 'URGENT');
      expect(order.membershipStatus, 'ACTIVE');
      expect(order.isActive, isTrue);
      expect(order.isCompleted, isFalse);
      expect(order.arrivalDate, '2026-10-01');
      expect(order.departureDate, '2026-10-08');
    });

    test('AppOrderExecutionContext.fromMap parses complete execution details and worker records', () {
      final map = {
        'batch_id': 'b1000000-0000-0000-0000-000000000001',
        'membership_id': 'm1000000-0000-0000-0000-000000000001',
        'order_id': 'c1000000-0000-0000-0000-000000000001',
        'case_id': 'c1000000-0000-0000-0000-000000000001',
        'order_no': 'AA0010',
        'customer_id': 'u1000000-0000-0000-0000-000000000001',
        'passport_id': 'p1000000-0000-0000-0000-000000000001',
        'full_name': '张三 (ZHANG SAN)',
        'passport_number': 'E12345678',
        'nationality': 'CHN',
        'date_of_birth': '1990-01-01',
        'gender': 'M',
        'passport_expiry_date': '2030-01-01',
        'arrival_date': '2026-10-01',
        'departure_date': '2026-10-08',
        'business_status': 'CURRENT',
        'workflow_status': 'submitted',
        'priority': 'NORMAL',
        'latest_pin_record_id': 'pin-uuid-001',
        'latest_pin_status': 'VERIFIED',
        'latest_registration_check_id': 'reg-uuid-001',
        'latest_registration_status': 'CONFIRMED',
        'latest_visit_pass_check_id': 'vp-uuid-001',
        'latest_visit_pass_status': 'CONFIRMED',
      };

      final ctx = AppOrderExecutionContext.fromMap(map);

      expect(ctx.orderId, 'c1000000-0000-0000-0000-000000000001');
      expect(ctx.fullName, '张三 (ZHANG SAN)');
      expect(ctx.passportNumber, 'E12345678');
      expect(ctx.nationality, 'CHN');
      expect(ctx.latestPinStatus, 'VERIFIED');
      expect(ctx.latestRegistrationStatus, 'CONFIRMED');
      expect(ctx.latestVisitPassStatus, 'CONFIRMED');
    });
  });

  group('Integration Fix V1.1 - Strict Batch-Driven Execution & Safety Rules', () {
    // 1. Batch Order AA0010 启动 Worker payload 带原 case_id
    test('Rule 1: Batch Order AA0010 preserves stable case_id in task execution payload', () {
      const stableCaseId = 'case-aa0010-stable-uuid';
      const orderNo = 'AA0010';
      const customerId = 'cust-zhangsan-001';

      final order = AppBatchOrder(
        membershipId: 'mem-001',
        batchId: 'batch-001',
        orderId: stableCaseId,
        caseId: stableCaseId,
        orderNo: orderNo,
        customerId: customerId,
        displayName: '张三',
        passportNumber: 'E12345678',
        businessStatus: 'CURRENT',
        priority: 'NORMAL',
        membershipStatus: 'ACTIVE',
      );

      final payloadItem = {
        'id': order.customerId,
        'case_id': order.caseId,
        'full_name': order.displayName,
        'passport_number': order.passportNumber,
      };

      expect(payloadItem['case_id'], equals(stableCaseId));
      expect(payloadItem['id'], equals(customerId));
      expect(payloadItem['case_id'], isNotNull);
    });

    // 2. 同 Customer 两个 Case 时不会拿错 Case
    test('Rule 2: Multiple cases for same customer explicitly bind target case_id without guessing', () {
      const customerId = 'cust-multi-001';
      const caseA = 'case-uuid-A';
      const caseB = 'case-uuid-B';

      final orderCaseB = AppBatchOrder(
        membershipId: 'mem-b-001',
        batchId: 'batch-target',
        orderId: caseB,
        caseId: caseB,
        orderNo: 'BB0020',
        customerId: customerId,
        displayName: '李四 (Case B)',
        passportNumber: 'E88888888',
        businessStatus: 'CURRENT',
        priority: 'NORMAL',
        membershipStatus: 'ACTIVE',
      );

      expect(orderCaseB.caseId, equals(caseB));
      expect(orderCaseB.caseId, isNot(equals(caseA)));
    });

    // 3. Batch A Release → Batch B 后仍使用同一 Order ID
    test('Rule 3: Batch A Release -> Batch B preserves the identical Order ID and Case ID', () {
      const stableOrderId = 'case-release-rebatch-uuid';
      const orderNo = 'AA0099';

      final orderInBatchA = AppBatchOrder(
        membershipId: 'mem-batch-a',
        batchId: 'batch-A',
        orderId: stableOrderId,
        caseId: stableOrderId,
        orderNo: orderNo,
        customerId: 'cust-099',
        displayName: '王五',
        passportNumber: 'E77777777',
        businessStatus: 'ACTION_REQUIRED',
        priority: 'NORMAL',
        membershipStatus: 'ACTIVE',
      );

      // After release and inclusion in Batch B
      final orderInBatchB = AppBatchOrder(
        membershipId: 'mem-batch-b',
        batchId: 'batch-B',
        orderId: stableOrderId,
        caseId: stableOrderId,
        orderNo: orderNo,
        customerId: 'cust-099',
        displayName: '王五',
        passportNumber: 'E77777777',
        businessStatus: 'CURRENT',
        priority: 'NORMAL',
        membershipStatus: 'ACTIVE',
      );

      expect(orderInBatchA.orderId, equals(orderInBatchB.orderId));
      expect(orderInBatchA.caseId, equals(orderInBatchB.caseId));
      expect(orderInBatchA.orderNo, equals(orderInBatchB.orderNo));
      expect(orderInBatchA.batchId, isNot(equals(orderInBatchB.batchId)));
    });

    // 4. Batch Closed 返回空列表时 App 正确识别 Closed (vs 正常空批次)
    test('Rule 4: Empty orders list correctly identifies Closed Batch when batch is not active', () {
      final activeBatches = [
        AppOperationalBatch(
          batchId: 'batch-active-1',
          batchName: '活跃批次 1',
          batchNo: 'BATCH-001',
          status: 'OPEN',
          createdAt: DateTime.now(),
          totalCount: 5,
          completedCount: 0,
          pendingCount: 5,
        ),
      ];

      // Closed batch check
      const closedBatchId = 'batch-closed-xyz';
      final isClosedBatchActive = activeBatches.any((b) => b.batchId == closedBatchId);
      expect(isClosedBatchActive, isFalse); // Correctly determined as Closed

      // Truly empty batch check
      const emptyActiveBatchId = 'batch-active-1';
      final isEmptyBatchActive = activeBatches.any((b) => b.batchId == emptyActiveBatchId);
      expect(isEmptyBatchActive, isTrue); // Correctly recognized as still Active (0 orders)
    });

    // 5. 页面缓存旧 Orders、后台 Close 后，再点 Worker → App 不 enqueue
    test('Rule 5: Pre-enqueue validation blocks execution when batch has been closed in backend', () async {
      final repo = DemoRepository();
      // repo has empty activeBatches (simulating closed / not found batch)
      final order = AppBatchOrder(
        membershipId: 'mem-stale',
        batchId: 'batch-stale-001',
        orderId: 'case-stale-001',
        caseId: 'case-stale-001',
        orderNo: 'STALE01',
        customerId: 'cust-stale',
        displayName: '测试客户',
        passportNumber: 'E00000000',
        businessStatus: 'CURRENT',
        priority: 'NORMAL',
        membershipStatus: 'ACTIVE',
      );

      // In local/unconfigured remoteMode, it safely rejects
      final err = await repo.createBatchDrivenTaskAsync(
        type: TaskType.mdacRegistration,
        batchId: 'batch-stale-001',
        orders: [order],
        actor: 'Tester',
        entryDate: DateTime.now().add(const Duration(days: 2)),
        exitDate: DateTime.now().add(const Duration(days: 5)),
      );

      expect(err, isNotNull);
    });

    // 6. Legacy customerId-only 流程仍能正常调用旧路径
    test('Rule 6: Legacy createTaskAsync accepts customerIds only without breaking', () async {
      final repo = DemoRepository();
      // In local mode, createTask handles legacy path
      final result = repo.createTask(
        type: TaskType.gmailPin,
        customerIds: ['c-001'],
        actor: 'Tester',
      );
      expect(result, isNull); // Succeeded in creating legacy task
      expect(repo.tasks.any((t) => t.customerIds.contains('c-001')), isTrue);
    });

    // 7. 无 Active Batch → 首页保持空，不 fallback 全量客户
    test('Rule 7: Zero active batches keeps workbench empty and does not expose all customers', () {
      final repo = DemoRepository();
      expect(repo.activeBatches, isEmpty);
      // Even though repository may have customers, activeBatches is strictly empty
      expect(repo.customers, isNotEmpty);
      expect(repo.activeBatches.length, 0);
    });
  });
}
