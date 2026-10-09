import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:passport_mdac_app/supabase_gateway.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  const batch = '00000000-0000-4000-8000-000000000001';
  const item = '00000000-0000-4000-8000-000000000002';
  const attempt = '00000000-0000-4000-8000-000000000003';
  Map<String, dynamic> success(
    Map<String, dynamic> params, {
    bool replayed = false,
  }) => {
    'id': batch,
    'request_id': params['p_request_id'],
    'requeued_item_ids': [item],
    'attempt_ids': [attempt],
    'replayed': replayed,
  };
  tearDown(SupabaseGateway.resetTestingHandlers);

  test('all retry uses guarded namespace and canonical request key', () async {
    final calls = <String>[];
    SupabaseGateway.requeueRpcHandler = (rpc, params) async {
      calls.add(rpc);
      expect(params['p_batch_id'], batch);
      expect(params['p_reason'], 'USER_RETRY');
      expect(
        params['p_request_id'],
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
      return success(params);
    };
    final result = await SupabaseGateway.requeueAutomationBatch(batch);
    expect(result['id'], batch);
    expect(calls, ['requeue_automation_batch_guarded']);
  });

  test('failed retry uses one RPC, no direct task/parent PATCH', () async {
    final calls = <String>[];
    SupabaseGateway.requeueRpcHandler = (rpc, params) async {
      calls.add(rpc);
      expect(params['p_batch_id'], batch);
      expect(params['p_reason'], 'USER_RETRY');
      expect(params['p_request_id'], isA<String>());
      return success(params);
    };
    await SupabaseGateway.requeueFailedItems(batch);
    expect(calls, ['requeue_automation_failed_items']);
  });

  test('missing failed RPC refuses instead of old PATCH', () async {
    var count = 0;
    SupabaseGateway.requeueRpcHandler = (rpc, params) async {
      count++;
      throw const PostgrestException(
        message: 'synthetic missing',
        code: 'PGRST202',
      );
    };
    await expectLater(
      SupabaseGateway.requeueFailedItems(batch),
      throwsStateError,
    );
    expect(count, 1);
  });

  test('all retry never falls back to old unsafe RPC', () async {
    var count = 0;
    SupabaseGateway.requeueRpcHandler = (rpc, params) async {
      count++;
      throw const PostgrestException(
        message: 'synthetic rejection',
        code: '42501',
      );
    };
    await expectLater(
      SupabaseGateway.requeueAutomationBatch(batch),
      throwsA(isA<PostgrestException>()),
    );
    expect(count, 1);
  });

  test('invalid response is not reported as success', () async {
    for (final response in [
      null,
      <String, dynamic>{},
      {'id': 'different'},
    ]) {
      SupabaseGateway.requeueRpcHandler = (rpc, params) async => response;
      await expectLater(
        SupabaseGateway.requeueAutomationBatch(batch),
        throwsFormatException,
      );
      await expectLater(
        SupabaseGateway.requeueFailedItems(batch),
        throwsFormatException,
      );
    }
  });

  test('unknown outcome is not automatically replayed', () async {
    var count = 0;
    SupabaseGateway.requeueRpcHandler = (rpc, params) async {
      count++;
      throw StateError('synthetic network unknown');
    };
    await expectLater(
      SupabaseGateway.requeueFailedItems(batch),
      throwsStateError,
    );
    expect(count, 1);
  });

  test('unconfigured/non-isolated candidate refuses before request', () async {
    await expectLater(
      SupabaseGateway.requeueAutomationBatch(batch),
      throwsStateError,
    );
    await expectLater(
      SupabaseGateway.requeueFailedItems(batch),
      throwsStateError,
    );
  });

  test(
    'network unknown keeps key for deliberate retry without automatic replay',
    () async {
      final keys = <String>[];
      SupabaseGateway.requeueRpcHandler = (rpc, params) async {
        keys.add(params['p_request_id'] as String);
        if (keys.length == 1) throw StateError('synthetic lost response');
        return success(params, replayed: true);
      };
      await expectLater(
        SupabaseGateway.requeueFailedItems(batch),
        throwsStateError,
      );
      expect(keys.length, 1);
      await SupabaseGateway.requeueFailedItems(batch);
      expect(keys[0], keys[1]);
      await SupabaseGateway.requeueFailedItems(batch);
      expect(keys[2], isNot(keys[1]));
    },
  );

  test(
    'explicit request UUID is passed unchanged and mismatched response refused',
    () async {
      const key = '00000000-0000-4000-8000-000000000004';
      SupabaseGateway.requeueRpcHandler = (rpc, params) async {
        expect(params['p_request_id'], key);
        return {...success(params), 'request_id': attempt};
      };
      await expectLater(
        SupabaseGateway.requeueAutomationBatch(batch, requestId: key),
        throwsFormatException,
      );
    },
  );

  test('invalid request UUID refuses before network', () async {
    var calls = 0;
    SupabaseGateway.requeueRpcHandler = (rpc, params) async {
      calls++;
      return success(params);
    };
    await expectLater(
      SupabaseGateway.requeueAutomationBatch(batch, requestId: 'not-a-uuid'),
      throwsFormatException,
    );
    expect(calls, 0);
  });

  test('operations do not share uncertain keys', () async {
    final keys = <String, String>{};
    SupabaseGateway.requeueRpcHandler = (rpc, params) async {
      keys[rpc] = params['p_request_id'] as String;
      throw StateError('synthetic network unknown');
    };
    await expectLater(
      SupabaseGateway.requeueAutomationBatch(batch),
      throwsStateError,
    );
    await expectLater(
      SupabaseGateway.requeueFailedItems(batch),
      throwsStateError,
    );
    expect(keys.values.toSet().length, 2);
  });

  test('concurrent double click sends same key and relies on server replay', () async {
    final keys = <String>[];
    final gate = Completer<void>();
    SupabaseGateway.requeueRpcHandler = (rpc, params) async {
      keys.add(params['p_request_id'] as String);
      if (keys.length == 2) gate.complete();
      await gate.future;
      return success(params, replayed: true);
    };
    await Future.wait([
      SupabaseGateway.requeueFailedItems(batch),
      SupabaseGateway.requeueFailedItems(batch),
    ]);
    expect(keys.length, 2);
    expect(keys[0], keys[1]);
  });

  test('explicit server rejection remains visible and never retries itself', () async {
    final keys = <String>[];
    SupabaseGateway.requeueRpcHandler = (rpc, params) async {
      keys.add(params['p_request_id'] as String);
      throw const PostgrestException(message: 'TASK_NOT_RETRYABLE', code: 'P0001');
    };
    await expectLater(SupabaseGateway.requeueAutomationBatch(batch),
        throwsA(isA<PostgrestException>()));
    expect(keys.length, 1);
    await expectLater(SupabaseGateway.requeueAutomationBatch(batch),
        throwsA(isA<PostgrestException>()));
    expect(keys[0], keys[1]);
  });

  test('late older reply cannot erase a newer network-unknown request key', () async {
    final keys = <String>[];
    final olderReply = Completer<void>();
    SupabaseGateway.requeueRpcHandler = (rpc, params) async {
      keys.add(params['p_request_id'] as String);
      final callNo = keys.length;
      if (callNo == 1) await Future<void>.delayed(Duration.zero);
      if (callNo == 2) await olderReply.future;
      if (callNo == 3) throw StateError('synthetic newer response lost');
      return success(params);
    };
    final first = SupabaseGateway.requeueAutomationBatch(batch);
    final second = SupabaseGateway.requeueAutomationBatch(batch);
    await first;
    await expectLater(SupabaseGateway.requeueAutomationBatch(batch), throwsStateError);
    expect(keys[0], keys[1]);
    expect(keys[2], isNot(keys[0]));
    olderReply.complete();
    await second;
    await SupabaseGateway.requeueAutomationBatch(batch);
    expect(keys[3], keys[2]);
  });

  test('invalid or duplicate attempt detail is not success', () async {
    for (final changes in [
      {'attempt_ids': <String>[]},
      {
        'requeued_item_ids': [item, item],
        'attempt_ids': [attempt, attempt],
      },
      {
        'attempt_ids': ['not-uuid'],
      },
      {'replayed': null},
    ]) {
      SupabaseGateway.requeueRpcHandler = (rpc, params) async => {
        ...success(params),
        ...changes,
      };
      await expectLater(
        SupabaseGateway.requeueAutomationBatch(batch),
        throwsFormatException,
      );
      await expectLater(
        SupabaseGateway.requeueFailedItems(batch),
        throwsFormatException,
      );
    }
  });
}
