import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:passport_mdac_app/main.dart';
import 'package:passport_mdac_app/supabase_gateway.dart';
import 'package:passport_mdac_app/features/batches/batch_models.dart';
import 'package:passport_mdac_app/features/tasks/customer_task_launch.dart';
import 'customer_task_launch_ui_test.dart' as fixtures;

AppBatchOrder batchOrder(int i) => AppBatchOrder.fromMap({
  'membership_id': 'member-$i', 'batch_id': 'batch-$i', 'order_id': 'case-$i',
  'case_id': 'case-$i', 'order_no': 'ORD-$i', 'customer_id': 'customer-$i',
  'passport_id': 'passport-$i', 'display_name': 'SYNTHETIC',
  'passport_number': 'TEST$i', 'business_status': 'CURRENT',
  'membership_status': 'ACTIVE', 'priority': 'NORMAL',
});

class ReceiptRepository extends DemoRepository {
  ReceiptRepository() { customers..clear()..addAll(List.generate(2, fixtures.customer)); tasks.clear(); }
  bool receiptsReadable = false;
  final committed = <String>{};
  @override
  bool get remoteMode => true;
  @override
  Future<String?> syncMdacBatchMembershipsFromSupabase() async => null;
  @override
  Future<String?> syncAutomationTasksFromSupabase() async => null;
  @override
  Future<String?> syncCustomersFromSupabase() async => null;
  @override
  Future<String?> syncActiveBatchesFromSupabase() async {
    activeBatches..clear()..addAll(List.generate(2, (i) => AppOperationalBatch.fromMap({
      'batch_id': 'batch-$i', 'batch_name': 'Synthetic', 'status': 'OPEN',
    })));
    return null;
  }
  @override
  Future<List<AppBatchOrder>> fetchBatchOrders(String id) async => [batchOrder(int.parse(id.split('-').last))];
  @override
  Future<AppOrderExecutionContext?> fetchOrderExecutionContext(String id) async {
    final i = int.parse(id.split('-').last);
    return AppOrderExecutionContext.fromMap({
      'batch_id': 'batch-$i', 'membership_id': 'member-$i',
      'order_id': id, 'case_id': id, 'customer_id': 'customer-$i',
    });
  }
  @override
  Future<bool> confirmCustomerTaskLaunchReceipt(PendingCustomerTaskLaunch pending) async =>
      receiptsReadable && committed.contains(pending.requestId);
}

class SplitCoordinator extends fixtures.LaunchCoordinator {
  SplitCoordinator() : super(List.generate(2, fixtures.order));
  @override
  Future<List<CustomerTaskLaunchGroup>> prepareSelectedOrders(
      List<CustomerTaskOrderChoice> choices, {String? batchName}) async {
    prepares++;
    return List.generate(2, (i) => CustomerTaskLaunchGroup(batchId: 'batch-$i', orders: [batchOrder(i)]));
  }
}

class PendingWidgetRepository extends fixtures.LaunchRepository {
  PendingWidgetRepository() : super(2);
  int launchCalls = 0;
  bool pending = false;
  bool receiptVisible = false;
  @override
  int get pendingCustomerTaskLaunchCount => pending ? 1 : 0;
  @override
  bool hasPendingCustomerTaskLaunchFor(TaskType type, List<String> ids) => pending;
  @override
  Future<Set<String>> confirmPendingCustomerTaskLaunches() async {
    if (!receiptVisible) return {};
    pending = false;
    return {'customer-1'};
  }
  @override
  Future<String?> createBatchDrivenTaskAsync({required TaskType type,required String batchId,
    required List<AppBatchOrder> orders,required String actor,DateTime? entryDate,
    DateTime? exitDate,String? requestId}) async {
    launchCalls++;
    if (launchCalls == 1) return null;
    pending = true;
    throw CustomerTaskLaunchUnknown(requestId!);
  }
}

void main() {
  tearDown(() async { await SupabaseGateway.client?.dispose(); SupabaseGateway.useClientForTesting(null); });

  test('A acknowledged B committed response lost: subsequent call only confirms B and never reissues', () async {
    final repo = ReceiptRepository();
    final requests = <http.Request>[];
    SupabaseGateway.useClientForTesting(SupabaseClient('https://isolated.invalid','test-public-key',
      authOptions: const AuthClientOptions(autoRefreshToken:false),
      httpClient: MockClient((request) async {
        expect(request.method,'POST');
        expect(request.url.path,'/rest/v1/rpc/create_gmail_pin_batch');
        requests.add(request);
        final note = (jsonDecode(request.body) as Map)['p_note'] as String;
        final marker = RegExp(r'\[APP-LAUNCH:([^\]]+)\]').firstMatch(note)!.group(1)!;
        repo.committed.add(marker);
        if (requests.length == 2) throw TimeoutException('committed but response lost');
        return http.Response('{"id":"acknowledged-batch"}',200,request:request);
      }),
    ));
    expect(await repo.createBatchDrivenTaskAsync(type:TaskType.gmailPin,batchId:'batch-0',
      orders:[batchOrder(0)],actor:'Synthetic owner',requestId:'11111111-1111-4111-8111-111111111111'),isNull);
    await expectLater(repo.createBatchDrivenTaskAsync(type:TaskType.gmailPin,batchId:'batch-1',
      orders:[batchOrder(1)],actor:'Synthetic owner',requestId:'22222222-2222-4222-8222-222222222222'),
      throwsA(isA<CustomerTaskLaunchUnknown>()));
    expect(requests,hasLength(2));
    expect(repo.committed,hasLength(2));
    expect(repo.pendingCustomerTaskLaunchCount,1);
    await expectLater(repo.createBatchDrivenTaskAsync(type:TaskType.gmailPin,batchId:'batch-1',
      orders:[batchOrder(1)],actor:'Synthetic owner',requestId:'33333333-3333-4333-8333-333333333333'),
      throwsA(isA<CustomerTaskLaunchUnknown>()));
    expect(requests,hasLength(2));
    expect(repo.pendingCustomerTaskLaunchCount,1);
    repo.receiptsReadable=true;
    expect(await repo.confirmPendingCustomerTaskLaunches(),{'customer-1'});
    expect(requests,hasLength(2));
    expect(repo.pendingCustomerTaskLaunchCount,0);
  });

  testWidgets('partial unknown is shown as pending and next tap confirms instead of creating', (tester) async {
    final repo = PendingWidgetRepository();
    final coordinator = SplitCoordinator();
    await fixtures.mount(tester,repo,coordinator);
    await tester.ensureVisible(fixtures.launchChip('获取 PIN'));
    await tester.tap(fixtures.launchChip('获取 PIN'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认发起 (2)'));
    await tester.pumpAndSettle();
    expect(repo.launchCalls,2);
    expect(find.textContaining('发起结果待确认'),findsWidgets);
    expect(find.textContaining('其余未排队'),findsNothing);
    await tester.ensureVisible(fixtures.launchChip('获取 PIN'));
    await tester.tap(fixtures.launchChip('获取 PIN'));
    await tester.pumpAndSettle();
    expect(repo.launchCalls,2);
    expect(coordinator.prepares,1);
    repo.receiptVisible=true;
    await tester.ensureVisible(find.text('确认发起结果 (1)'));
    await tester.tap(find.text('确认发起结果 (1)'));
    await tester.pumpAndSettle();
    expect(repo.pendingCustomerTaskLaunchCount,0);
    expect(repo.launchCalls,2);
  });
}
