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

  group('Batch Integration Contract - Repository & Rule Tests', () {
    test('DemoRepository initializes with empty activeBatches and not loading', () {
      final repo = DemoRepository();
      expect(repo.activeBatches, isEmpty);
      expect(repo.activeBatchesLoading, isFalse);
      expect(repo.activeBatchesError, isNull);
    });

    test('Order ID stability: Order identity remains constant across multiple batch assignments', () {
      // Simulates AA0010 moving from Batch A (where it was released) to Batch B
      const stableOrderId = 'case-aa0010-stable-uuid';
      const orderNo = 'AA0010';

      final membershipInBatchA = AppBatchOrder(
        membershipId: 'mem-001',
        batchId: 'batch-A',
        orderId: stableOrderId,
        caseId: stableOrderId,
        orderNo: orderNo,
        customerId: 'cust-001',
        displayName: '张三',
        passportNumber: 'E99999999',
        businessStatus: 'ACTION_REQUIRED',
        priority: 'NORMAL',
        membershipStatus: 'ACTIVE',
      );

      final membershipInBatchB = AppBatchOrder(
        membershipId: 'mem-002',
        batchId: 'batch-B',
        orderId: stableOrderId, // Exactly identical stable ID
        caseId: stableOrderId,
        orderNo: orderNo,
        customerId: 'cust-001',
        displayName: '张三',
        passportNumber: 'E99999999',
        businessStatus: 'CURRENT',
        priority: 'NORMAL',
        membershipStatus: 'ACTIVE',
      );

      expect(membershipInBatchA.orderId, equals(membershipInBatchB.orderId));
      expect(membershipInBatchA.orderNo, equals(membershipInBatchB.orderNo));
      expect(membershipInBatchA.customerId, equals(membershipInBatchB.customerId));
      expect(membershipInBatchA.batchId, isNot(equals(membershipInBatchB.batchId)));
    });

    test('DemoRepository in local/unconfigured mode returns null for sync without crash', () async {
      final repo = DemoRepository();
      final err = await repo.syncActiveBatchesFromSupabase();
      expect(err, isNull);
      expect(repo.activeBatches, isEmpty);
    });
  });
}
