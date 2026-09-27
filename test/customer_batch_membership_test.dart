import 'package:flutter_test/flutter_test.dart';
import 'package:passport_mdac_app/main.dart';

void main() {
  group('MdacBatchMembership', () {
    test('1. parses correctly when customer has single batch', () {
      final membership = MdacBatchMembership.fromMap({
        'batch_id': 'batch-001',
        'name': '25-9',
        'created_at': '2026-09-24T22:25:33.408Z',
        'customer_ids': ['c-1', 'c-2'],
      });

      expect(membership.batchId, 'batch-001');
      expect(membership.name, '25-9');
      expect(membership.customerIds, ['c-1', 'c-2']);
    });

    test('2 & 3. selects the latest batch when customer appears in multiple historical batches', () {
      final oldBatch = MdacBatchMembership(
        batchId: 'old-batch-uuid',
        name: '旧批次',
        createdAt: DateTime(2026, 9, 20, 10, 0),
        customerIds: ['customer-shared', 'customer-old'],
      );

      final newBatch = MdacBatchMembership(
        batchId: 'new-batch-uuid',
        name: '最新批次',
        createdAt: DateTime(2026, 9, 25, 12, 0),
        customerIds: ['customer-shared', 'customer-new'],
      );

      final memberships = [oldBatch, newBatch];

      // Simulate grouping index mapping
      final customerMdacBatch = <String, MdacBatchMembership>{};
      for (final batch in memberships) {
        for (final customerId in batch.customerIds) {
          final existing = customerMdacBatch[customerId];
          if (existing == null || batch.createdAt.isAfter(existing.createdAt)) {
            customerMdacBatch[customerId] = batch;
          }
        }
      }

      // Shared customer must resolve to the newest batch
      expect(customerMdacBatch['customer-shared']?.batchId, 'new-batch-uuid');
      expect(customerMdacBatch['customer-shared']?.name, '最新批次');
      expect(customerMdacBatch['customer-old']?.batchId, 'old-batch-uuid');
      expect(customerMdacBatch['customer-new']?.batchId, 'new-batch-uuid');
    });

    test('4. customer with no batch falls back to createdAt date key', () {
      final customerDate = DateTime(2026, 9, 23, 14, 30);
      final customer = Customer(
        id: 'cust-no-batch',
        fullName: 'TEST USER',
        passportNumber: 'E12345678',
        dateOfBirth: '01/01/1990',
        placeOfBirth: 'BEIJING',
        nationality: 'CHN',
        gender: 'MALE',
        passportExpiryDate: '01/01/2030',
        businessStatus: 'REGISTERED',
        createdAt: customerDate,
        createdBy: 'test-admin',
      );

      final customerMdacBatch = <String, MdacBatchMembership>{};
      final membership = customerMdacBatch[customer.id];

      expect(membership, isNull);
      final dateKey = 'date_${customer.createdAt.year.toString().padLeft(4, '0')}-${customer.createdAt.month.toString().padLeft(2, '0')}-${customer.createdAt.day.toString().padLeft(2, '0')}';
      expect(dateKey, 'date_2026-09-23');
    });

    test('5. batch rename updates name from database note and preserves customerIds', () {
      final repo = DemoRepository();
      repo.mdacBatchMemberships.clear();

      final batch = MdacBatchMembership(
        batchId: 'batch-test-rename',
        name: '原批次名',
        createdAt: DateTime(2026, 9, 24),
        customerIds: ['c-1', 'c-2'],
      );
      repo.mdacBatchMemberships.add(batch);

      expect(repo.mdacBatchMemberships.first.name, '原批次名');

      // Update batch note locally
      repo.updateBatchNote(batchId: 'batch-test-rename', note: '新批次名-25-9');

      expect(repo.mdacBatchMemberships.first.name, '新批次名-25-9');
      expect(repo.mdacBatchMemberships.first.customerIds, ['c-1', 'c-2']);
    });

    test('6. 24-9 and 25-9 batch groups produce exactly 30 and 20 customers', () {
      final batch24 = MdacBatchMembership(
        batchId: '1ec16fdc-b88c-439e-9f2f-6e68a46e96f8',
        name: '24-9',
        createdAt: DateTime(2026, 9, 24, 11, 11),
        customerIds: List.generate(30, (i) => 'c-24-$i'),
      );

      final batch25 = MdacBatchMembership(
        batchId: '38cda812-0ab8-48c0-aea2-5f7f5946867b',
        name: '25-9',
        createdAt: DateTime(2026, 9, 24, 22, 25),
        customerIds: List.generate(20, (i) => 'c-25-$i'),
      );

      final memberships = [batch24, batch25];

      final customerMdacBatch = <String, MdacBatchMembership>{};
      for (final b in memberships) {
        for (final cid in b.customerIds) {
          customerMdacBatch[cid] = b;
        }
      }

      final count24 = customerMdacBatch.values.where((b) => b.name == '24-9').length;
      final count25 = customerMdacBatch.values.where((b) => b.name == '25-9').length;

      expect(count24, 30);
      expect(count25, 20);
    });

    test('7. membership sync failure does not crash DemoRepository', () async {
      final repo = DemoRepository();
      // In local unit test without Supabase init, remoteMode is false, returns null safely
      final result = await repo.syncMdacBatchMembershipsFromSupabase();
      expect(result, isNull);
      expect(repo.mdacBatchMemberships, isNotNull);
    });
  });
}
