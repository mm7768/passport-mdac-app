import 'package:flutter_test/flutter_test.dart';
import 'package:passport_mdac_app/supabase_gateway.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  const batch = '00000000-0000-4000-8000-000000000001';
  tearDown(SupabaseGateway.resetTestingHandlers);

  test('all retry uses guarded namespace, only batch ID', () async {
    final calls = <String>[];
    SupabaseGateway.requeueRpcHandler = (rpc, params) async {
      calls.add(rpc);
      expect(params, {'p_batch_id': batch});
      return {'id': batch, 'status': 'QUEUED'};
    };
    final result = await SupabaseGateway.requeueAutomationBatch(batch);
    expect(result['id'], batch);
    expect(calls, ['requeue_automation_batch_guarded']);
  });

  test('failed retry uses one RPC, no direct task/parent PATCH', () async {
    final calls = <String>[];
    SupabaseGateway.requeueRpcHandler = (rpc, params) async {
      calls.add(rpc);
      expect(params, {'p_batch_id': batch});
      return {'id': batch, 'status': 'RUNNING'};
    };
    await SupabaseGateway.requeueFailedItems(batch);
    expect(calls, ['requeue_automation_failed_items']);
  });

  test('missing failed RPC refuses instead of old PATCH', () async {
    var count = 0;
    SupabaseGateway.requeueRpcHandler = (rpc, params) async {
      count++;
      throw const PostgrestException(message: 'synthetic missing', code: 'PGRST202');
    };
    await expectLater(SupabaseGateway.requeueFailedItems(batch), throwsStateError);
    expect(count, 1);
  });

  test('all retry never falls back to old unsafe RPC', () async {
    var count = 0;
    SupabaseGateway.requeueRpcHandler = (rpc, params) async {
      count++;
      throw const PostgrestException(message: 'synthetic rejection', code: '42501');
    };
    await expectLater(SupabaseGateway.requeueAutomationBatch(batch),
        throwsA(isA<PostgrestException>()));
    expect(count, 1);
  });

  test('invalid response is not reported as success', () async {
    for (final response in [null, <String, dynamic>{}, {'id': 'different'}]) {
      SupabaseGateway.requeueRpcHandler = (rpc, params) async => response;
      await expectLater(SupabaseGateway.requeueAutomationBatch(batch), throwsFormatException);
      await expectLater(SupabaseGateway.requeueFailedItems(batch), throwsFormatException);
    }
  });

  test('unknown outcome is not automatically replayed', () async {
    var count = 0;
    SupabaseGateway.requeueRpcHandler = (rpc, params) async {
      count++;
      throw StateError('synthetic network unknown');
    };
    await expectLater(SupabaseGateway.requeueFailedItems(batch), throwsStateError);
    expect(count, 1);
  });

  test('unconfigured/non-isolated candidate refuses before request', () async {
    await expectLater(SupabaseGateway.requeueAutomationBatch(batch), throwsStateError);
    await expectLater(SupabaseGateway.requeueFailedItems(batch), throwsStateError);
  });
}
