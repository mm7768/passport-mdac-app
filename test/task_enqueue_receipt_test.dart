import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:passport_mdac_app/features/batches/batch_models.dart';
import 'package:passport_mdac_app/supabase_gateway.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const actor = '11111111-1111-4111-8111-111111111111';
const requestId = '22222222-2222-4222-8222-222222222222';
const marker = '[APP-LAUNCH:$requestId]';
const type = 'MDAC_REGISTRATION';

AppBatchOrder order(int n) => AppBatchOrder.fromMap({
  'case_id': 'case-$n',
  'order_id': 'case-$n',
  'customer_id': 'customer-$n',
  'membership_id': 'membership-$n',
  'batch_id': 'operational-$n',
  'order_no': 'SYNTHETIC-$n',
});
Map<String, dynamic> receipt({
  String note = 'SYNTHETIC $marker',
  List<Map<String, dynamic>>? items,
}) => {
  'id': 'automation-batch',
  'created_by': actor,
  'task_type': type,
  'note': note,
  'items':
      items ??
      [
        {'id': 'item-1', 'case_id': 'case-1', 'customer_id': 'customer-1'},
      ],
};

Future<void> install(
  Future<http.Response> Function(http.Request) handler, {
  bool signedIn = true,
}) async {
  final client = SupabaseClient(
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
  );
  if (signedIn) {
    await client.auth.setInitialSession(
      jsonEncode({
        'access_token': 'synthetic-non-JWT-token',
        'token_type': 'bearer',
        'user': {
          'id': actor,
          'app_metadata': {},
          'aud': 'authenticated',
          'created_at': '2035-01-01T00:00:00Z',
        },
      }),
    );
  }
  SupabaseGateway.useClientForTesting(client);
}

Future<bool> confirm() => SupabaseGateway.confirmCustomerTaskLaunchReceipt(
  requestId: requestId,
  taskType: type,
  orders: [order(1)],
);
Future<void> guard() => SupabaseGateway.ensureNoDuplicateMdacTask(
  orders: [order(1)],
  entryDate: '2035-01-01',
  exitDate: '2035-01-02',
);

void main() {
  tearDown(() => SupabaseGateway.useClientForTesting(null));

  test('receipt without an authenticated actor stays unknown without sending anything', () async {
    var calls = 0;
    await install((_) async {
      calls++;
      return http.Response('[]', 200);
    }, signedIn: false);
    expect(await confirm(), false);
    expect(calls, 0);
  });
  test(
    'receipt exact marker actor type Cases and customers confirms read-only',
    () async {
      final calls = <http.Request>[];
      await install((r) async {
        calls.add(r);
        if (r.url.path.endsWith('/automation_batches')) {
          expect(r.method, 'GET');
          expect(r.url.queryParameters['created_by'], 'eq.$actor');
          expect(r.url.queryParameters['task_type'], 'eq.$type');
          expect(r.url.queryParameters['note'], 'like.%$marker%');
          return http.Response(jsonEncode([receipt()]), 200);
        }
        expect(r.url.path, '/rest/v1/rpc/get_app_order_execution_context');
        return http.Response(
          jsonEncode([
            {
              'case_id': 'case-1',
              'customer_id': 'customer-1',
              'membership_id': 'membership-1',
              'batch_id': 'operational-1',
            },
          ]),
          200,
        );
      });
      expect(await confirm(), true);
      expect(calls.length, 1);
      expect(calls.any((r) => r.url.path.contains('create_')), false);
    },
  );
  test('absent receipt never calls create or authorizes resend', () async {
    final calls = <http.Request>[];
    await install((r) async {
      calls.add(r);
      return http.Response('[]', 200);
    });
    expect(await confirm(), false);
    expect(calls.length, 1);
    expect(calls.single.method, 'GET');
  });
  test(
    'ambiguous receipt read throws rather than claiming not queued',
    () async {
      await install(
        (_) async => throw TimeoutException('SYNTHETIC NETWORK LOSS'),
      );
      await expectLater(confirm(), throwsA(isA<TimeoutException>()));
    },
  );
  test(
    'wrong marker or multiple matching markers do not acknowledge another task',
    () async {
      for (final note in ['SYNTHETIC OTHER', 'SYNTHETIC $marker $marker']) {
        await install(
          (_) async => http.Response(jsonEncode([receipt(note: note)]), 200),
        );
        expect(await confirm(), false);
      }
    },
  );
  test('extra Cases, wrong customer, and legacy NULL Case cannot confirm strict launch', () async {
    for (final rows in <List<Map<String, dynamic>>>[
      [
        {'case_id': 'case-1', 'customer_id': 'customer-2'},
      ],
      [
        {'case_id': null, 'customer_id': 'customer-1'},
      ],
      [
        {'case_id': 'case-1', 'customer_id': 'customer-1'},
        {'case_id': 'case-2', 'customer_id': 'customer-2'},
      ],
    ]) {
      await install(
        (_) async => http.Response(jsonEncode([receipt(items: rows)]), 200),
      );
      expect(await confirm(), false);
    }
  });
  test('committed receipt still acknowledges after parent release without a live membership read', () async {
    final calls = <http.Request>[];
    await install((r) async {
      calls.add(r);
      if (!r.url.path.endsWith('/automation_batches')) {
        throw StateError(
          'Receipt must not depend on a now-released membership',
        );
      }
      return http.Response(jsonEncode([receipt()]), 200);
    });
    expect(await confirm(), true);
    expect(calls.length, 1);
    expect(calls.single.method, 'GET');
  });
  test('known sameCase success is blocked before any create', () async {
    final calls = <http.Request>[];
    await install((r) async {
      calls.add(r);
      return http.Response(
        jsonEncode([
          {
            'id': 'result',
            'case_id': 'case-1',
            'customer_id': 'customer-1',
            'registration_status': 'SUCCEEDED',
            'entry_date': '2035-01-01',
            'exit_date': '2035-01-02',
          },
        ]),
        200,
      );
    });
    await expectLater(guard(), throwsA(isA<FormatException>()));
    expect(calls.length, 1);
    expect(calls.single.method, 'GET');
  });
  test(
    'legacy NULL Case sameCustomer and exactdates success is blocked',
    () async {
      await install(
        (_) async => http.Response(
          jsonEncode([
            {
              'id': 'legacy',
              'case_id': null,
              'customer_id': 'customer-1',
              'registration_status': 'SUCCEEDED',
              'entry_date': '2035-01-01',
              'exit_date': '2035-01-02',
            },
          ]),
          200,
        ),
      );
      await expectLater(guard(), throwsA(isA<FormatException>()));
    },
  );
  test('differentCase modern result or legacy othertrip is not silently bound to this Case', () async {
    final calls = <http.Request>[];
    await install((r) async {
      calls.add(r);
      return http.Response(
        jsonEncode(
          r.url.path.endsWith('/mdac_registrations')
              ? [
                  {
                    'id': 'other',
                    'case_id': 'case-2',
                    'customer_id': 'customer-1',
                    'registration_status': 'SUCCEEDED',
                    'entry_date': '2035-01-01',
                    'exit_date': '2035-01-02',
                  },
                  {
                    'id': 'legacy',
                    'case_id': null,
                    'customer_id': 'customer-1',
                    'registration_status': 'SUCCEEDED',
                    'entry_date': '2034-01-01',
                    'exit_date': '2034-01-02',
                  },
                ]
              : [],
        ),
        200,
      );
    });
    await guard();
    expect(calls.length, 2);
    expect(calls.every((r) => r.method == 'GET'), true);
  });
  test('alreadyexisting sameCase MDAC task sends user to original task for every state', () async {
    for (final status in ['SUCCEEDED', 'RUNNING', 'NEEDS_REVIEW', 'FAILED']) {
      await install(
        (r) async => http.Response(
          jsonEncode(
            r.url.path.endsWith('/mdac_registrations')
                ? []
                : [
                    {
                      'id': 'existing',
                      'case_id': 'case-1',
                      'customer_id': 'customer-1',
                      'status': status,
                      'batch': {
                        'task_type': type,
                        'entry_date': '2035-01-01',
                        'exit_date': '2035-01-02',
                      },
                    },
                  ],
          ),
          200,
        ),
      );
      await expectLater(guard(), throwsA(isA<FormatException>()));
    }
  });
  test(
    'legacy active or uncertain sameCustomer trip is blocked after restart',
    () async {
      await install(
        (r) async => http.Response(
          jsonEncode(
            r.url.path.endsWith('/mdac_registrations')
                ? []
                : [
                    {
                      'id': 'existing',
                      'case_id': null,
                      'customer_id': 'customer-1',
                      'status': 'NEEDS_REVIEW',
                      'batch': {
                        'task_type': type,
                        'entry_date': '2035-01-01',
                        'exit_date': '2035-01-02',
                      },
                    },
                  ],
          ),
          200,
        ),
      );
      await expectLater(guard(), throwsA(isA<FormatException>()));
    },
  );
  test('network or malformed existingtask state fails closed', () async {
    await install((_) async => throw TimeoutException('SYNTHETIC OFFLINE'));
    await expectLater(guard(), throwsA(isA<TimeoutException>()));
    await install(
      (r) async => http.Response(
        jsonEncode(
          r.url.path.endsWith('/mdac_registrations')
              ? []
              : [
                  {
                    'id': 'existing',
                    'case_id': 'case-1',
                    'customer_id': 'customer-1',
                    'batch': null,
                  },
                ],
        ),
        200,
      ),
    );
    await expectLater(guard(), throwsA(isA<FormatException>()));
  });
}
