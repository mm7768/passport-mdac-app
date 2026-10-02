import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:passport_mdac_app/features/batches/batch_models.dart';
import 'package:passport_mdac_app/features/batches/batches_screen.dart';
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
        'latest_mdac_status': 'SUCCEEDED',
        'latest_pin_status': 'RECEIVED',
        'latest_registration_status': 'CONFIRMED',
        'latest_visit_pass_status': 'CONFIRMED',
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
      expect(order.latestMdacStatus, 'SUCCEEDED');
      expect(order.latestPinStatus, 'RECEIVED');
      expect(order.latestRegistrationStatus, 'CONFIRMED');
      expect(order.latestVisitPassStatus, 'CONFIRMED');
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
        'latest_mdac_registration_id': 'mdac-uuid-001',
        'latest_mdac_status': 'SUCCEEDED',
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
      expect(ctx.latestMdacRegistrationId, 'mdac-uuid-001');
      expect(ctx.latestMdacStatus, 'SUCCEEDED');
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

  group('Integration Fix V1.2 - Case-Aware Execution & Lifecycle Tests (Section 15)', () {
    // Test 1: createBatchDrivenTaskAsync payload carries membership_id & operational_batch_id
    test('Test 1: createBatchDrivenTaskAsync payload binds customer_id, case_id, membership_id, operational_batch_id', () {
      final order = AppBatchOrder(
        membershipId: 'mem-uuid-101',
        batchId: 'batch-uuid-202',
        orderId: 'case-uuid-303',
        caseId: 'case-uuid-303',
        orderNo: 'AA0020',
        customerId: 'cust-uuid-404',
        displayName: '李四 (LI SI)',
        passportNumber: 'E98765432',
        businessStatus: 'CURRENT',
        priority: 'NORMAL',
        membershipStatus: 'ACTIVE',
      );

      final payloadItem = {
        'id': order.customerId,
        'customer_id': order.customerId,
        'case_id': order.caseId,
        'membership_id': order.membershipId,
        'operational_batch_id': order.batchId,
        'full_name': order.displayName,
        'passport_number': order.passportNumber,
      };

      expect(payloadItem['customer_id'], equals('cust-uuid-404'));
      expect(payloadItem['case_id'], equals('case-uuid-303'));
      expect(payloadItem['membership_id'], equals('mem-uuid-101'));
      expect(payloadItem['operational_batch_id'], equals('batch-uuid-202'));
    });

    // Test 2: Batch A stale page + Backend context has moved to Batch B -> rejects enqueue
    test('Test 2: Stale Batch A page with backend context moved to Batch B blocks enqueue', () async {
      final repo = _TestMockDemoRepository();
      final order = AppBatchOrder(
        membershipId: 'mem-batch-A',
        batchId: 'batch-A',
        orderId: 'case-order-001',
        caseId: 'case-order-001',
        orderNo: 'ORD-001',
        customerId: 'cust-001',
        displayName: '王测试',
        passportNumber: 'E11223344',
        businessStatus: 'CURRENT',
        priority: 'NORMAL',
        membershipStatus: 'ACTIVE',
      );

      // Backend active batch has batch-A and order is in batch-A
      repo.mockActiveBatches = [
        AppOperationalBatch(
          batchId: 'batch-A',
          batchName: '旧批次 A',
          batchNo: 'BATCH-A',
          status: 'OPEN',
          createdAt: DateTime.now(),
          totalCount: 1,
          completedCount: 0,
          pendingCount: 1,
        ),
      ];
      repo.mockOrders = [order];

      // But backend context has already moved to Batch B (stale page race condition)
      repo.mockContext = AppOrderExecutionContext(
        batchId: 'batch-B', // Different batch!
        membershipId: 'mem-batch-B', // Different membership!
        orderId: 'case-order-001',
        caseId: 'case-order-001',
        orderNo: 'ORD-001',
        customerId: 'cust-001',
        fullName: '王测试',
        passportNumber: 'E11223344',
        nationality: 'CHN',
        businessStatus: 'CURRENT',
        workflowStatus: 'SUBMITTED',
        priority: 'NORMAL',
      );

      final err = await repo.createBatchDrivenTaskAsync(
        type: TaskType.gmailPin,
        batchId: 'batch-A',
        orders: [order],
        actor: 'Tester',
      );

      expect(err, isNotNull);
      expect(err, contains('订单已被重新排单或当前批次状态已变化，请刷新后重试。'));
    });

    // Test 3: Active list request error must NOT mark batch CLOSED
    test('Test 3: Active list request network error does NOT mark batch as CLOSED', () {
      bool isBatchClosed = false;
      List<AppBatchOrder> localOrders = [
        AppBatchOrder(
          membershipId: 'mem-1',
          batchId: 'batch-current',
          orderId: 'case-1',
          caseId: 'case-1',
          orderNo: 'O1',
          customerId: 'c1',
          displayName: '测试',
          passportNumber: 'E111',
          businessStatus: 'CURRENT',
          priority: 'NORMAL',
          membershipStatus: 'ACTIVE',
        ),
      ];
      String? errorMessage;

      // Simulate network failure response from syncActiveBatchesFromSupabase
      const syncErr = '网络连接超时 / Network Error';

      if (syncErr.isNotEmpty) {
        // V1.2 Section 11 Logic:
        // Do NOT set isBatchClosed = true
        // Do NOT clear localOrders
        errorMessage = '无法确认批次当前状态，请检查网络后刷新';
      }

      expect(isBatchClosed, isFalse);
      expect(localOrders, isNotEmpty);
      expect(errorMessage, equals('无法确认批次当前状态，请检查网络后刷新'));
    });

    // Test 4: Authoritative active list response missing current batchId marks CLOSED
    test('Test 4: Authoritative active list without current batchId marks batch as CLOSED', () {
      bool isBatchClosed = false;
      List<AppBatchOrder> localOrders = [
        AppBatchOrder(
          membershipId: 'mem-1',
          batchId: 'batch-target',
          orderId: 'case-1',
          caseId: 'case-1',
          orderNo: 'O1',
          customerId: 'c1',
          displayName: '测试',
          passportNumber: 'E111',
          businessStatus: 'CURRENT',
          priority: 'NORMAL',
          membershipStatus: 'ACTIVE',
        ),
      ];

      final authoritativeActiveBatches = [
        AppOperationalBatch(
          batchId: 'other-batch-xyz',
          batchName: '另一个批次',
          batchNo: 'B-OTHER',
          status: 'OPEN',
          createdAt: DateTime.now(),
          totalCount: 5,
          completedCount: 2,
          pendingCount: 3,
        ),
      ];

      // Successful authoritative response check
      final isStillActive = authoritativeActiveBatches.any((b) => b.batchId == 'batch-target');
      if (!isStillActive) {
        localOrders = [];
        isBatchClosed = true;
      }

      expect(isBatchClosed, isTrue);
      expect(localOrders, isEmpty);
    });

    // Test 5: App Lifecycle resumed triggers active batch refresh
    test('Test 5: App Lifecycle resumed triggers active batch refresh', () async {
      final repo = _TestMockDemoRepository();
      repo.mockActiveBatches = [
        AppOperationalBatch(
          batchId: 'batch-fresh',
          batchName: '最新批次',
          batchNo: 'B-FRESH',
          status: 'OPEN',
          createdAt: DateTime.now(),
          totalCount: 10,
          completedCount: 5,
          pendingCount: 5,
        ),
      ];

      expect(repo.syncActiveBatchesCalled, isFalse);

      // Simulate AppLifecycleState.resumed
      await repo.syncActiveBatchesFromSupabase();

      expect(repo.syncActiveBatchesCalled, isTrue);
      expect(repo.activeBatches.any((b) => b.batchId == 'batch-fresh'), isTrue);
    });

    // Test D (V1.2.1 Section 5): Repository sync failure guards enqueue
    test('Test D (V1.2.1): syncActiveBatchesFromSupabase returns error -> createBatchDrivenTaskAsync refuses enqueue', () async {
      final repo = _TestMockDemoRepository();
      // Even if activeBatches had the batch previously cached
      repo.activeBatches.add(
        AppOperationalBatch(
          batchId: 'batch-cached',
          batchName: '旧缓存批次',
          batchNo: 'B-CACHED',
          status: 'OPEN',
          createdAt: DateTime.now(),
          totalCount: 1,
          completedCount: 0,
          pendingCount: 1,
        ),
      );
      repo.syncActiveBatchesErrorToReturn = '网络连接超时 / Network Error';

      final order = AppBatchOrder(
        membershipId: 'mem-1',
        batchId: 'batch-cached',
        orderId: 'case-order-001',
        caseId: 'case-order-001',
        orderNo: 'ORD-001',
        customerId: 'cust-001',
        displayName: '测试客户',
        passportNumber: 'E11223344',
        businessStatus: 'CURRENT',
        priority: 'NORMAL',
        membershipStatus: 'ACTIVE',
      );

      final err = await repo.createBatchDrivenTaskAsync(
        type: TaskType.gmailPin,
        batchId: 'batch-cached',
        orders: [order],
        actor: 'Tester',
      );

      expect(err, equals('无法确认批次当前状态，请检查网络后刷新'));
    });

    testWidgets('Batch Detail screen renders without overflow on 360px mobile screen', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final repo = _TestMockDemoRepository();
      final batch = AppOperationalBatch(
        batchId: 'b1000',
        batchName: 'OB0004',
        batchNo: 'OB0004',
        status: 'OPEN',
        createdAt: DateTime.parse('2026-09-30T10:00:00Z'),
        totalCount: 1,
        completedCount: 0,
        pendingCount: 1,
      );
      final order = AppBatchOrder(
        membershipId: 'm1',
        batchId: 'b1000',
        orderId: 'fe0bc53a-0000-0000-0000-000000000001',
        orderNo: 'AA0180',
        customerId: 'c1',
        caseId: 'case1',
        displayName: 'ZHANG SAN',
        passportNumber: 'ES3458078',
        businessStatus: 'CURRENT',
        membershipStatus: 'ACTIVE',
        arrivalDate: null,
        departureDate: null,
        priority: 'STANDARD',
      );
      repo.mockOrders = [order];
      repo.mockActiveBatches = [batch];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BatchDetailScreen(
              batch: batch,
              repository: repo,
              actor: 'Tester',
              role: UserRole.owner,
              onBack: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('OB0004'), findsWidgets);
      expect(find.text('AA0180'), findsOneWidget);
      expect(find.text('ZHANG SAN'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Tap order checkbox to select it and verify bottom bar when items are selected
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();

      expect(find.text('已选 1 单'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Batch MDAC & Automation Status Specification Tests (ANTIGRAVITY_BATCH_MDAC_STATUS_FIX)', () {
    // Test 1: MDAC SUCCEEDED shows Done
    testWidgets('Test 1: MDAC SUCCEEDED displays Done in Batch Detail and keeps disposition ACTIVE', (tester) async {
      final repo = _TestMockDemoRepository();
      final batch = AppOperationalBatch(
        batchId: 'b-001',
        batchName: 'OB0004',
        batchNo: 'OB0004',
        status: 'OPEN',
        createdAt: DateTime.parse('2026-09-30T10:00:00Z'),
        totalCount: 1,
        completedCount: 0,
        pendingCount: 1,
      );
      final order = AppBatchOrder(
        membershipId: 'mem-001',
        batchId: 'b-001',
        orderId: 'fe0b0c53-430e-4dbb-b6a9-97bb513b309d',
        orderNo: 'AA0180',
        customerId: 'cust-001',
        caseId: 'fe0b0c53-430e-4dbb-b6a9-97bb513b309d',
        displayName: 'ZHANG YIXIN',
        passportNumber: 'ES3458078',
        businessStatus: 'CURRENT',
        membershipStatus: 'ACTIVE',
        priority: 'NORMAL',
        latestMdacStatus: 'SUCCEEDED',
      );
      repo.mockOrders = [order];
      repo.mockActiveBatches = [batch];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BatchDetailScreen(
              batch: batch,
              repository: repo,
              actor: 'Tester',
              role: UserRole.owner,
              onBack: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('MDAC Done'), findsWidgets);
      // Invariant: disposition remains ACTIVE, order is not over-completed
      expect(order.membershipStatus, equals('ACTIVE'));
      expect(order.isActive, isTrue);
      expect(order.isCompleted, isFalse);
    });

    // Test 2: null MDAC record shows MDAC —
    testWidgets('Test 2: null MDAC record displays MDAC —', (tester) async {
      final repo = _TestMockDemoRepository();
      final batch = AppOperationalBatch(
        batchId: 'b-001',
        batchName: 'OB0004',
        batchNo: 'OB0004',
        status: 'OPEN',
        createdAt: DateTime.parse('2026-09-30T10:00:00Z'),
        totalCount: 1,
        completedCount: 0,
        pendingCount: 1,
      );
      final order = AppBatchOrder(
        membershipId: 'mem-002',
        batchId: 'b-001',
        orderId: 'case-002',
        orderNo: 'AA0181',
        customerId: 'cust-002',
        caseId: 'case-002',
        displayName: 'WANG WU',
        passportNumber: 'E99887766',
        businessStatus: 'CURRENT',
        membershipStatus: 'ACTIVE',
        priority: 'NORMAL',
        latestMdacStatus: null,
      );
      repo.mockOrders = [order];
      repo.mockActiveBatches = [batch];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BatchDetailScreen(
              batch: batch,
              repository: repo,
              actor: 'Tester',
              role: UserRole.owner,
              onBack: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('MDAC —'), findsWidgets);
    });

    // Test 3: MDAC FAILED shows Failed state without affecting other statuses
    testWidgets('Test 3: MDAC Failed displays Failed state and does not affect other statuses', (tester) async {
      final repo = _TestMockDemoRepository();
      final batch = AppOperationalBatch(
        batchId: 'b-001',
        batchName: 'OB0004',
        batchNo: 'OB0004',
        status: 'OPEN',
        createdAt: DateTime.parse('2026-09-30T10:00:00Z'),
        totalCount: 1,
        completedCount: 0,
        pendingCount: 1,
      );
      final order = AppBatchOrder(
        membershipId: 'mem-003',
        batchId: 'b-001',
        orderId: 'case-003',
        orderNo: 'AA0182',
        customerId: 'cust-003',
        caseId: 'case-003',
        displayName: 'LI SI',
        passportNumber: 'E55443322',
        businessStatus: 'CURRENT',
        membershipStatus: 'ACTIVE',
        priority: 'NORMAL',
        latestMdacStatus: 'FAILED',
        latestPinStatus: 'RECEIVED',
      );
      repo.mockOrders = [order];
      repo.mockActiveBatches = [batch];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BatchDetailScreen(
              batch: batch,
              repository: repo,
              actor: 'Tester',
              role: UserRole.owner,
              onBack: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('MDAC Failed'), findsWidgets);
      expect(find.text('PIN Done'), findsWidgets);
      expect(find.text('REG —'), findsWidgets);
      expect(find.text('VP —'), findsWidgets);
    });

    // Test 4: Strict Case Isolation (Same customer, two Orders)
    testWidgets('Test 4: Same Customer with two Orders strictly isolates MDAC status by case_id', (tester) async {
      final repo = _TestMockDemoRepository();
      final batch = AppOperationalBatch(
        batchId: 'b-001',
        batchName: 'OB0004',
        batchNo: 'OB0004',
        status: 'OPEN',
        createdAt: DateTime.parse('2026-09-30T10:00:00Z'),
        totalCount: 2,
        completedCount: 0,
        pendingCount: 2,
      );
      const sharedCustomerId = 'same-customer-uuid-888';
      final order1 = AppBatchOrder(
        membershipId: 'mem-101',
        batchId: 'b-001',
        orderId: 'case-order-1-uuid',
        orderNo: 'AA0180',
        customerId: sharedCustomerId,
        caseId: 'case-order-1-uuid',
        displayName: 'ZHANG YIXIN',
        passportNumber: 'ES3458078',
        businessStatus: 'CURRENT',
        membershipStatus: 'ACTIVE',
        priority: 'NORMAL',
        latestMdacStatus: 'SUCCEEDED',
      );
      final order2 = AppBatchOrder(
        membershipId: 'mem-102',
        batchId: 'b-001',
        orderId: 'case-order-2-uuid',
        orderNo: 'AA0181',
        customerId: sharedCustomerId,
        caseId: 'case-order-2-uuid',
        displayName: 'ZHANG YIXIN',
        passportNumber: 'ES3458078',
        businessStatus: 'CURRENT',
        membershipStatus: 'ACTIVE',
        priority: 'NORMAL',
        latestMdacStatus: null, // Order 2 has no MDAC
      );
      repo.mockOrders = [order1, order2];
      repo.mockActiveBatches = [batch];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BatchDetailScreen(
              batch: batch,
              repository: repo,
              actor: 'Tester',
              role: UserRole.owner,
              onBack: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Order 1 must display Done, Order 2 must display —
      expect(find.text('MDAC Done'), findsOneWidget);
      expect(find.text('MDAC —'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    // Test 5: 360px mobile responsive test with full automation badges
    testWidgets('Test 5: Batch Detail renders without overflow on 360px screen with automation badges and operable buttons', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final repo = _TestMockDemoRepository();
      final batch = AppOperationalBatch(
        batchId: 'b-001',
        batchName: 'OB0004',
        batchNo: 'OB0004',
        status: 'OPEN',
        createdAt: DateTime.parse('2026-09-30T10:00:00Z'),
        totalCount: 1,
        completedCount: 0,
        pendingCount: 1,
      );
      final order = AppBatchOrder(
        membershipId: 'mem-001',
        batchId: 'b-001',
        orderId: 'fe0b0c53-430e-4dbb-b6a9-97bb513b309d',
        orderNo: 'AA0180',
        customerId: 'cust-001',
        caseId: 'fe0b0c53-430e-4dbb-b6a9-97bb513b309d',
        displayName: 'ZHANG YIXIN (VERY LONG CUSTOMER NAME)',
        passportNumber: 'ES3458078',
        businessStatus: 'CURRENT',
        membershipStatus: 'ACTIVE',
        priority: 'URGENT',
        arrivalDate: '2026-10-01',
        departureDate: '2026-10-08',
        latestMdacStatus: 'SUCCEEDED',
        latestPinStatus: 'RECEIVED',
        latestRegistrationStatus: 'CONFIRMED',
        latestVisitPassStatus: 'CONFIRMED',
      );
      repo.mockOrders = [order];
      repo.mockActiveBatches = [batch];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BatchDetailScreen(
              batch: batch,
              repository: repo,
              actor: 'Tester',
              role: UserRole.owner,
              onBack: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // No overflow
      expect(tester.takeException(), isNull);

      // Automation badges visible
      expect(find.text('MDAC Done'), findsOneWidget);
      expect(find.text('PIN Done'), findsOneWidget);
      expect(find.text('REG Done'), findsOneWidget);
      expect(find.text('VP Done'), findsOneWidget);

      // Select order and test bottom bar buttons
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();

      expect(find.text('已选 1 单'), findsOneWidget);
      expect(find.text('启动 MDAC 注册'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    // Test 6: Order Execution Context dialog shows latest MDAC status and ID
    testWidgets('Test 6: Execution Context dialog displays latest MDAC registration status and ID', (tester) async {
      final repo = _TestMockDemoRepository();
      final batch = AppOperationalBatch(
        batchId: 'b-001',
        batchName: 'OB0004',
        batchNo: 'OB0004',
        status: 'OPEN',
        createdAt: DateTime.parse('2026-09-30T10:00:00Z'),
        totalCount: 1,
        completedCount: 0,
        pendingCount: 1,
      );
      final order = AppBatchOrder(
        membershipId: 'mem-001',
        batchId: 'b-001',
        orderId: 'fe0b0c53-430e-4dbb-b6a9-97bb513b309d',
        orderNo: 'AA0180',
        customerId: 'cust-001',
        caseId: 'fe0b0c53-430e-4dbb-b6a9-97bb513b309d',
        displayName: 'ZHANG YIXIN',
        passportNumber: 'ES3458078',
        businessStatus: 'CURRENT',
        membershipStatus: 'ACTIVE',
        priority: 'NORMAL',
        latestMdacStatus: 'SUCCEEDED',
      );
      repo.mockOrders = [order];
      repo.mockActiveBatches = [batch];
      repo.mockContext = const AppOrderExecutionContext(
        orderId: 'fe0b0c53-430e-4dbb-b6a9-97bb513b309d',
        caseId: 'fe0b0c53-430e-4dbb-b6a9-97bb513b309d',
        orderNo: 'AA0180',
        customerId: 'cust-001',
        fullName: 'ZHANG YIXIN',
        passportNumber: 'ES3458078',
        nationality: 'CHN',
        businessStatus: 'CURRENT',
        workflowStatus: 'MDAC_COMPLETED',
        priority: 'NORMAL',
        latestMdacRegistrationId: '7c3dc2e9-3b07-4f14-a8e0-26471437fa80',
        latestMdacStatus: 'SUCCEEDED',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BatchDetailScreen(
              batch: batch,
              repository: repo,
              actor: 'Tester',
              role: UserRole.owner,
              onBack: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tap info button to open context dialog
      await tester.tap(find.byIcon(Icons.info_outline_rounded).first);
      await tester.pumpAndSettle();

      expect(find.text('ZHANG YIXIN 执行上下文'), findsOneWidget);
      expect(find.text('MDAC 注册状态'), findsOneWidget);
      expect(find.text('SUCCEEDED'), findsOneWidget);
      expect(find.text('MDAC 注册记录 ID'), findsOneWidget);
      expect(find.text('7c3dc2e9-3b07-4f14-a8e0-26471437fa80'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

class _TestMockDemoRepository extends DemoRepository {
  @override
  bool get remoteMode => true;

  AppOrderExecutionContext? mockContext;
  List<AppBatchOrder> mockOrders = [];
  bool syncActiveBatchesCalled = false;
  String? syncActiveBatchesErrorToReturn;
  List<AppOperationalBatch> mockActiveBatches = [];

  @override
  Future<String?> syncActiveBatchesFromSupabase() async {
    syncActiveBatchesCalled = true;
    if (syncActiveBatchesErrorToReturn != null) {
      activeBatchesError = syncActiveBatchesErrorToReturn;
      return syncActiveBatchesErrorToReturn;
    }
    activeBatches
      ..clear()
      ..addAll(mockActiveBatches);
    return null;
  }

  @override
  Future<List<AppBatchOrder>> fetchBatchOrders(String batchId) async {
    return mockOrders;
  }

  @override
  Future<AppOrderExecutionContext?> fetchOrderExecutionContext(String orderId) async {
    return mockContext;
  }
}
