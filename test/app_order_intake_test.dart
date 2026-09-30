import 'package:flutter_test/flutter_test.dart';
import 'package:passport_mdac_app/main.dart';
import 'package:passport_mdac_app/supabase_gateway.dart';

void main() {
  setUp(() {
    SupabaseGateway.resetTestingHandlers();
  });

  tearDown(() {
    SupabaseGateway.resetTestingHandlers();
  });

  group('V1.3 App Order Intake Tests (Section 17)', () {
    final validOcrValues = {
      'fullName': 'TAN JIA WEI',
      'passportNumber': 'E98765432',
      'dateOfBirth': '12/05/1992',
      'placeOfBirth': 'JOHOR',
      'nationality': 'MYS',
      'gender': '男',
      'passportExpiryDate': '12/05/2032',
    };

    final testDraft = OcrDraft(
      id: 'remote-ocr-11111111-2222-3333-4444-555555555555',
      sourceLabel: 'passport_scan.jpg',
      sourceIndex: 'Page 1',
      fullName: 'TAN JIA WEI',
      passportNumber: 'E98765432',
      dateOfBirth: '12/05/1992',
      placeOfBirth: 'JOHOR',
      nationality: 'MYS',
      gender: '男',
      passportExpiryDate: '12/05/2032',
      confidence: 0.95,
    );

    // Test A: confirmOcrWithSync() calls create_order_from_ocr, not create_customer_with_case
    test('Test A: confirmOcrWithSync() calls create_order_from_ocr, not create_customer_with_case', () async {
      final repo = _TestOrderIntakeRepository();
      repo.ocrDrafts.add(testDraft);

      bool createOrderFromOcrCalled = false;
      bool createCustomerWithCaseCalled = false;
      String? calledOcrResultId;

      SupabaseGateway.createOrderFromOcrHandler = ({
        required ocrResultId,
        required fullName,
        required passportNumber,
        required dateOfBirth,
        required placeOfBirth,
        required nationality,
        required gender,
        required passportExpiryDate,
        arrivalDate,
        departureDate,
        priority = 'NORMAL',
        price,
        cost,
        remark,
      }) async {
        createOrderFromOcrCalled = true;
        calledOcrResultId = ocrResultId;
        return {
          'order_id': 'order-uuid-001',
          'order_no': 'AA0001',
          'customer_id': 'cust-uuid-001',
          'passport_id': 'pass-uuid-001',
          'customer_reused': false,
          'match_method': 'NEW',
        };
      };

      SupabaseGateway.insertCustomerHandler = ({
        required fullName,
        required passportNumber,
        required dateOfBirth,
        required placeOfBirth,
        required nationality,
        required gender,
        required passportExpiryDate,
        businessStatus = 'PENDING',
        passportImagePath,
      }) async {
        createCustomerWithCaseCalled = true;
        return {'id': 'dummy'};
      };

      final err = await repo.confirmOcrWithSync(testDraft, validOcrValues, 'Operator1');

      expect(err, isNull);
      expect(createOrderFromOcrCalled, isTrue);
      expect(createCustomerWithCaseCalled, isFalse);
      expect(calledOcrResultId, equals('11111111-2222-3333-4444-555555555555'));
      expect(repo.ocrDrafts.where((d) => d.id == testDraft.id), isEmpty);
      expect(repo.lastConfirmedOrderSummary, contains('AA0001'));
      expect(repo.lastConfirmedOrderSummary, contains('NEW'));
    });

    // Test B: Successful response requires order_id, order_no, customer_id, passport_id
    test('Test B: Incomplete response without order_id / passport_id fails invariant check', () async {
      final repo = _TestOrderIntakeRepository();
      repo.ocrDrafts.add(testDraft);

      // Return missing passport_id and order_no
      SupabaseGateway.createOrderFromOcrHandler = ({
        required ocrResultId,
        required fullName,
        required passportNumber,
        required dateOfBirth,
        required placeOfBirth,
        required nationality,
        required gender,
        required passportExpiryDate,
        arrivalDate,
        departureDate,
        priority = 'NORMAL',
        price,
        cost,
        remark,
      }) async {
        return {
          'order_id': 'order-uuid-001',
          // missing order_no, customer_id, passport_id
        };
      };

      final err = await repo.confirmOcrWithSync(testDraft, validOcrValues, 'Operator1');

      expect(err, isNotNull);
      expect(err, contains('订单创建结果不完整，缺少必须的订单或客户凭证'));
    });

    // Test C: The App does NOT call markOcrResultCreated() after successful create_order_from_ocr
    test('Test C: The App does NOT call markOcrResultCreated() after create_order_from_ocr', () async {
      final repo = _TestOrderIntakeRepository();
      repo.ocrDrafts.add(testDraft);

      bool markOcrResultCreatedCalled = false;

      SupabaseGateway.createOrderFromOcrHandler = ({
        required ocrResultId,
        required fullName,
        required passportNumber,
        required dateOfBirth,
        required placeOfBirth,
        required nationality,
        required gender,
        required passportExpiryDate,
        arrivalDate,
        departureDate,
        priority = 'NORMAL',
        price,
        cost,
        remark,
      }) async {
        return {
          'order_id': 'order-uuid-002',
          'order_no': 'AA0002',
          'customer_id': 'cust-uuid-002',
          'passport_id': 'pass-uuid-002',
          'customer_reused': true,
          'match_method': 'PASSPORT_EXACT',
        };
      };

      SupabaseGateway.markOcrResultCreatedHandler = ({
        required resultId,
        required customerId,
        required extractedData,
      }) async {
        markOcrResultCreatedCalled = true;
      };

      final err = await repo.confirmOcrWithSync(testDraft, validOcrValues, 'Operator1');

      expect(err, isNull);
      expect(markOcrResultCreatedCalled, isFalse);
      expect(repo.lastConfirmedOrderSummary, contains('AA0002'));
      expect(repo.lastConfirmedOrderSummary, contains('REUSED'));
    });

    // Test D: The App does NOT enqueue any Worker after Order intake
    test('Test D: The App does NOT enqueue any Worker or create automation_item after Order intake', () async {
      final repo = _TestOrderIntakeRepository();
      repo.tasks.clear();
      repo.ocrDrafts.add(testDraft);

      SupabaseGateway.createOrderFromOcrHandler = ({
        required ocrResultId,
        required fullName,
        required passportNumber,
        required dateOfBirth,
        required placeOfBirth,
        required nationality,
        required gender,
        required passportExpiryDate,
        arrivalDate,
        departureDate,
        priority = 'NORMAL',
        price,
        cost,
        remark,
      }) async {
        return {
          'order_id': 'order-uuid-003',
          'order_no': 'AA0003',
          'customer_id': 'cust-uuid-003',
          'passport_id': 'pass-uuid-003',
          'customer_reused': false,
          'match_method': 'NEW',
        };
      };

      final err = await repo.confirmOcrWithSync(testDraft, validOcrValues, 'Operator1');

      expect(err, isNull);
      // Invariant: automation_item is NOT created during intake; tasks remains empty
      expect(repo.tasks, isEmpty);
      expect(repo.currentWorkerActivity, isNot(contains('已排队')));
    });

    // Test E: Idempotent retry returns the same order_id and the UI does not duplicate the local Customer card
    test('Test E: Idempotent retry returns same order_id and does not duplicate local Customer card', () async {
      final repo = _TestOrderIntakeRepository();
      repo.ocrDrafts.add(testDraft);

      final returnedCustomer = Customer(
        id: 'cust-uuid-005',
        fullName: 'TAN JIA WEI',
        passportNumber: 'E98765432',
        dateOfBirth: '12/05/1992',
        placeOfBirth: 'JOHOR',
        nationality: 'MYS',
        gender: '男',
        passportExpiryDate: '12/05/2032',
        businessStatus: 'PENDING',
        createdAt: DateTime.now(),
        createdBy: 'Operator1',
      );

      // Remote returns this customer upon sync
      repo.remoteCustomers = [returnedCustomer];

      SupabaseGateway.createOrderFromOcrHandler = ({
        required ocrResultId,
        required fullName,
        required passportNumber,
        required dateOfBirth,
        required placeOfBirth,
        required nationality,
        required gender,
        required passportExpiryDate,
        arrivalDate,
        departureDate,
        priority = 'NORMAL',
        price,
        cost,
        remark,
      }) async {
        // Idempotent retry returns identical order & customer identifiers
        return {
          'order_id': 'order-uuid-005',
          'order_no': 'AA0005',
          'customer_id': 'cust-uuid-005',
          'passport_id': 'pass-uuid-005',
          'customer_reused': true,
          'match_method': 'IDEMPOTENT_RETRY',
        };
      };

      // First confirmation
      final err1 = await repo.confirmOcrWithSync(testDraft, validOcrValues, 'Operator1');
      expect(err1, isNull);
      expect(repo.customers.where((c) => c.id == 'cust-uuid-005').length, equals(1));

      // Simulate idempotent retry for the draft
      repo.ocrDrafts.add(testDraft);
      final err2 = await repo.confirmOcrWithSync(testDraft, validOcrValues, 'Operator1');
      expect(err2, isNull);

      // Verify no duplicate Customer card in local state
      expect(repo.customers.where((c) => c.id == 'cust-uuid-005').length, equals(1));
    });
  });
}

class _TestOrderIntakeRepository extends DemoRepository {
  @override
  bool get remoteMode => true;

  bool syncCustomersCalled = false;
  bool syncActiveBatchesCalled = false;
  List<Customer> remoteCustomers = [];

  @override
  Future<String?> syncCustomersFromSupabase() async {
    syncCustomersCalled = true;
    customers
      ..clear()
      ..addAll(remoteCustomers);
    return null;
  }

  @override
  Future<String?> syncActiveBatchesFromSupabase() async {
    syncActiveBatchesCalled = true;
    return null;
  }
}
