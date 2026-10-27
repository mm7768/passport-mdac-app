import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:passport_mdac_app/features/tasks/customer_task_launch.dart';
import 'package:passport_mdac_app/supabase_gateway.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String id(int n) => '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';

Map<String, dynamic> choiceRow(int n, {int? customer, int? passport}) => {
  'id': id(200 + n),
  'customer_id': id(customer ?? 100 + n),
  'passport_id': id(passport ?? 300 + n),
  'order_no': 'SYNTHETIC-${n.toString().padLeft(3, '0')}',
  'arrival_date': '2035-01-01',
  'departure_date': '2035-01-02',
  'case_status': 'NEW',
  'business_status': null,
};

class FakeLaunchApi {
  final rows = <Map<String, dynamic>>[];
  final contexts = <String, Map<String, dynamic>?>{};
  final batchOrders = <String, List<Map<String, dynamic>>>{};
  final active = <String>{};
  final createdSelections = <List<String>>[];
  final contextReads = <String, int>{};
  int loads = 0;
  bool loseCreateResponse = false;
  bool leaveCreationUnknown = false;
  Object? creationError;
  Completer<Map<String, dynamic>>? pendingCreate;

  CustomerTaskLaunchCoordinator coordinator() => CustomerTaskLaunchCoordinator(
    loadOrderRows: (ids) async {
      loads++;
      return rows.where((r) => ids.contains(r['customer_id'])).toList();
    },
    loadContext: (caseId) async {
      contextReads.update(caseId, (n) => n + 1, ifAbsent: () => 1);
      return contexts[caseId];
    },
    createBatch: (caseIds, {batchName}) async {
      createdSelections.add(List<String>.of(caseIds));
      if (creationError != null) throw creationError!;
      if (pendingCreate != null) return pendingCreate!.future;
      if (!leaveCreationUnknown) {
        for (final caseId in caseIds) {
          assign(caseId, id(1000));
        }
      }
      if (loseCreateResponse) throw TimeoutException('Synthetic response lost');
      return {'id': id(1000)};
    },
    loadActiveBatches: () async => [
      for (final batch in active) {'batch_id': batch, 'status': 'OPEN'},
    ],
    loadBatchOrders: (batchId) async => batchOrders[batchId] ?? [],
  );

  void assign(String caseId, String batchId, {String disposition = 'ACTIVE'}) {
    final row = rows.singleWhere((r) => r['id'] == caseId);
    final context = {
      'batch_id': batchId,
      'membership_id': id(500 + rows.indexOf(row)),
      'order_id': caseId,
      'case_id': caseId,
      'customer_id': row['customer_id'],
      'passport_id': row['passport_id'],
      'order_no': row['order_no'],
      'membership_status': disposition,
      'business_status': 'CURRENT',
      'priority': 'NORMAL',
      'display_name': 'SYNTHETIC',
      'passport_number': 'SYNTHETIC',
      'arrival_date': row['arrival_date'],
      'departure_date': row['departure_date'],
    };
    contexts[caseId] = context;
    batchOrders
        .putIfAbsent(batchId, () => [])
        .add(Map<String, dynamic>.of(context));
    active.add(batchId);
  }
}

void installTransport(Future<http.Response> Function(http.Request) handler) {
  SupabaseGateway.useClientForTesting(
    SupabaseClient(
      'https://isolated.invalid',
      'test-public-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        final response = await handler(request);
        return http.Response(
          response.body,
          response.statusCode,
          headers: {'content-type': 'application/json', ...response.headers},
          request: request,
        );
      }),
    ),
  );
}

void main() {
  tearDown(() => SupabaseGateway.useClientForTesting(null));

  test(
    'Gateway Case choices are explicit filtered reads, no latest-order limit',
    () async {
      final requests = <http.Request>[];
      installTransport((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode([choiceRow(1), choiceRow(2, customer: 101)]),
          200,
        );
      });
      final rows = await SupabaseGateway.fetchCustomerTaskOrderChoices([
        id(101),
      ]);
      expect(rows.length, 2);
      expect(requests.single.method, 'GET');
      expect(requests.single.url.path, '/rest/v1/customer_cases');
      expect(
        requests.single.url.queryParameters['customer_id'],
        'in.("${id(101)}")',
      );
      expect(
        requests.single.url.queryParameters['website_archived_at'],
        'is.null',
      );
      expect(
        requests.single.url.queryParameters['select'],
        contains('passport_id'),
      );
      expect(requests.single.url.queryParameters['order'], startsWith('id.asc'));
      expect(requests.single.url.queryParameters['limit'], '500');
      expect(requests.single.url.queryParameters['offset'], '0');
    },
  );

  test(
    'Case choices paginate beyond one response without dropping older Cases',
    () async {
      final offsets = <String?>[];
      installTransport((request) async {
        offsets.add(request.url.queryParameters['offset']);
        return http.Response(
          jsonEncode(
            offsets.length == 1
                ? [for (var n = 1; n <= 500; n++) choiceRow(n, customer: 101)]
                : [choiceRow(501, customer: 101)],
          ),
          200,
        );
      });
      final rows = await SupabaseGateway.fetchCustomerTaskOrderChoices([
        id(101),
      ]);
      expect(rows.length, 501);
      expect(offsets, ['0', '500']);
    },
  );

  test('Gateway creates only selected existing Cases through existing authorized RPC', () async {
    final requests = <http.Request>[];
    installTransport((request) async {
      requests.add(request);
      return http.Response(jsonEncode({'id': id(1000)}), 200);
    });
    await SupabaseGateway.createCustomerTaskOperationalBatch([
      id(201),
      id(202),
    ], batchName: 'SYNTHETIC');
    expect(requests.single.method, 'POST');
    expect(requests.single.url.path, '/rest/v1/rpc/create_operational_batch');
    expect(jsonDecode(requests.single.body), {
      'p_order_ids': [id(201), id(202)],
      'p_batch_name': 'SYNTHETIC',
    });
  });

  test('raw context loader accepts zero or one existing membership without enrichment', () async {
    var calls = 0;
    installTransport((request) async {
      calls++;
      expect(request.url.path, '/rest/v1/rpc/get_app_order_execution_context');
      return http.Response(
        calls == 1
            ? '[]'
            : jsonEncode([
                {'case_id': id(201)},
              ]),
        200,
      );
    });
    expect(
      await SupabaseGateway.fetchCustomerTaskOrderExecutionContext(id(201)),
      isNull,
    );
    expect(
      (await SupabaseGateway.fetchCustomerTaskOrderExecutionContext(
        id(201),
      ))!['case_id'],
      id(201),
    );
    expect(calls, 2);
  });

  test(
    'load nineteen unique choices reads only and preserves every OrderNo',
    () async {
      final api = FakeLaunchApi()
        ..rows.addAll([for (var n = 1; n <= 19; n++) choiceRow(n)]);
      final choices = await api.coordinator().loadOrders([
        for (var n = 1; n <= 19; n++) id(100 + n),
      ]);
      expect(choices.length, 19);
      expect(choices.map((c) => c.orderNo).toSet().length, 19);
      expect(api.createdSelections, isEmpty);
      expect(api.contextReads, isEmpty);
    },
  );

  test('no Case stays empty and multiple Cases stay explicit, never latest guessed', () async {
    final api = FakeLaunchApi()
      ..rows.addAll([choiceRow(1), choiceRow(2, customer: 101)]);
    final coordinator = api.coordinator();
    expect(await coordinator.loadOrders([id(999)]), isEmpty);
    final choices = await coordinator.loadOrders([id(101)]);
    expect(choices.map((c) => c.caseId).toList(), [id(201), id(202)]);
    expect(api.createdSelections, isEmpty);
    final groups = await coordinator.prepareSelectedOrders([choices.first]);
    expect(api.createdSelections.single, [id(201)]);
    expect(groups.single.orders.single.caseId, id(201));
  });

  test(
    'nineteen explicitly selected unassigned Cases create once with strict IDs',
    () async {
      final api = FakeLaunchApi()
        ..rows.addAll([for (var n = 1; n <= 19; n++) choiceRow(n)]);
      final coordinator = api.coordinator();
      final choices = await coordinator.loadOrders([
        for (var n = 1; n <= 19; n++) id(100 + n),
      ]);
      final groups = await coordinator.prepareSelectedOrders(choices);
      expect(api.createdSelections.length, 1);
      expect(
        api.createdSelections.single.toSet(),
        choices.map((c) => c.caseId).toSet(),
      );
      expect(groups.single.orders.length, 19);
      for (final order in groups.single.orders) {
        final choice = choices.singleWhere((c) => c.caseId == order.caseId);
        expect(order.customerId, choice.customerId);
        expect(order.passportId, choice.passportId);
        expect(order.caseId, order.orderId);
        expect(order.batchId, groups.single.batchId);
        expect(order.membershipId, isNotEmpty);
      }
    },
  );

  test(
    'existing memberships reused and only unassigned choices are created',
    () async {
      final api = FakeLaunchApi()
        ..rows.addAll([choiceRow(1), choiceRow(2), choiceRow(3)]);
      api.assign(id(201), id(1001));
      api.assign(id(202), id(1002), disposition: 'COMPLETED');
      final coordinator = api.coordinator();
      final choices = await coordinator.loadOrders([id(101), id(102), id(103)]);
      final groups = await coordinator.prepareSelectedOrders(choices);
      expect(api.createdSelections.single, [id(203)]);
      expect(groups.map((g) => g.batchId).toSet(), {
        id(1000),
        id(1001),
        id(1002),
      });
      expect(groups.expand((g) => g.orders).map((o) => o.caseId).toSet(), {
        id(201),
        id(202),
        id(203),
      });
    },
  );

  test('all existing memberships require zero creation writes', () async {
    final api = FakeLaunchApi()..rows.add(choiceRow(1));
    api.assign(id(201), id(1001));
    final coordinator = api.coordinator();
    final choices = await coordinator.loadOrders([id(101)]);
    await coordinator.prepareSelectedOrders(choices);
    expect(api.createdSelections, isEmpty);
  });

  test('lost create response recovers memberships with one read pass, never blind create again', () async {
    final api = FakeLaunchApi()
      ..rows.addAll([choiceRow(1), choiceRow(2)])
      ..loseCreateResponse = true;
    final coordinator = api.coordinator();
    final choices = await coordinator.loadOrders([id(101), id(102)]);
    final groups = await coordinator.prepareSelectedOrders(choices);
    expect(groups.single.orders.length, 2);
    expect(api.createdSelections.length, 1);
    expect(api.contextReads[id(201)], 2);
    expect(api.contextReads[id(202)], 2);
  });

  test('unknown create result blocks without a second creation RPC', () async {
    final api = FakeLaunchApi()
      ..rows.add(choiceRow(1))
      ..loseCreateResponse = true
      ..leaveCreationUnknown = true;
    final coordinator = api.coordinator();
    final choices = await coordinator.loadOrders([id(101)]);
    await expectLater(
      coordinator.prepareSelectedOrders(choices),
      throwsA(isA<CustomerTaskLaunchException>()),
    );
    expect(api.createdSelections.length, 1);
    expect(api.contextReads[id(201)], 2);
  });

  test('permission denial is not hidden by context-recovery', () async {
    final api = FakeLaunchApi()
      ..rows.add(choiceRow(1))
      ..creationError = const PostgrestException(
        message: 'SYNTHETIC FORBIDDEN',
        code: '42501',
      );
    final coordinator = api.coordinator();
    final choices = await coordinator.loadOrders([id(101)]);
    await expectLater(
      coordinator.prepareSelectedOrders(choices),
      throwsA(isA<PostgrestException>()),
    );
    expect(api.contextReads[id(201)], 1);
    expect(api.createdSelections.length, 1);
  });

  test('closed parent blocks preparation, no automation enqueue or extra membership writes', () async {
    final api = FakeLaunchApi()..rows.add(choiceRow(1));
    api.assign(id(201), id(1001));
    api.active.clear();
    final coordinator = api.coordinator();
    final choices = await coordinator.loadOrders([id(101)]);
    await expectLater(
      coordinator.prepareSelectedOrders(choices),
      throwsA(isA<CustomerTaskLaunchException>()),
    );
    expect(api.createdSelections, isEmpty);
  });

  test(
    'released membership, changed customer and changed passport are rejected',
    () async {
      final api = FakeLaunchApi()..rows.add(choiceRow(1));
      api.assign(id(201), id(1001));
      api.contexts[id(201)]!['released_at'] = '2035-01-01';
      final coordinator = api.coordinator();
      final choices = await coordinator.loadOrders([id(101)]);
      await expectLater(
        coordinator.prepareSelectedOrders(choices),
        throwsA(isA<CustomerTaskLaunchException>()),
      );
      api.contexts[id(201)]!.remove('released_at');
      api.contexts[id(201)]!['customer_id'] = id(999);
      await expectLater(
        coordinator.prepareSelectedOrders(choices),
        throwsA(isA<CustomerTaskLaunchException>()),
      );
      api.contexts[id(201)]!['customer_id'] = id(101);
      api.rows.single['passport_id'] = id(999);
      await expectLater(
        coordinator.prepareSelectedOrders(choices),
        throwsA(isA<CustomerTaskLaunchException>()),
      );
      expect(api.createdSelections, isEmpty);
    },
  );

  test(
    'one explicit Case per customer and duplicate-click protection',
    () async {
      final api = FakeLaunchApi()
        ..rows.addAll([choiceRow(1), choiceRow(2, customer: 101)]);
      final coordinator = api.coordinator();
      final choices = await coordinator.loadOrders([id(101)]);
      await expectLater(
        coordinator.prepareSelectedOrders(choices),
        throwsA(isA<CustomerTaskLaunchException>()),
      );
      expect(api.createdSelections, isEmpty);
      api.pendingCreate = Completer<Map<String, dynamic>>();
      final first = coordinator.prepareSelectedOrders([choices.first]);
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        coordinator.prepareSelectedOrders([choices.first]),
        throwsA(isA<CustomerTaskLaunchException>()),
      );
      api.assign(id(201), id(1000));
      api.pendingCreate!.complete({'id': id(1000)});
      await first;
      expect(api.createdSelections.length, 1);
    },
  );
}
