import 'package:flutter_test/flutter_test.dart';
import 'package:passport_mdac_app/main.dart';
import 'package:passport_mdac_app/supabase_gateway.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const customer = '00000000-0000-4000-8000-000000000001';
const jobId = '00000000-0000-4000-8000-000000000002';
const requestId = '00000000-0000-4000-8000-000000000003';
const protectedPath = 'automation-attempt-evidence/$jobId/$requestId.png';
const legacyPath = 'passports/$customer/synthetic-front.png';

Map<String, dynamic> job({bool managed = true}) => {
  'created': true,
  'job_id': jobId,
  if (managed) 'cleanup_request_id': requestId,
  if (managed) 'cleanup_not_before': '2026-10-12T08:00:00Z',
  'storage_paths': [
    if (managed) {'bucket': 'passport-documents', 'path': protectedPath},
    {'bucket': 'passport-documents', 'path': legacyPath},
  ],
};

class SyntheticDeleteRepository extends DemoRepository {
  @override
  bool get remoteMode => true;
  @override
  Future<String?> syncCustomersFromSupabase() async => null;
  @override
  Future<String?> syncOcrBatchesFromSupabase() async => null;
  @override
  Future<String?> syncOcrResultsFromSupabase() async => null;
}

void main() {
  tearDown(SupabaseGateway.resetTestingHandlers);

  test(
    'pending cleanup keeps stable job and never removes/marks/completes/fails',
    () async {
      final calls = <String>[];
      SupabaseGateway.hardDeleteRpcHandler = (rpc, params) async {
        calls.add(rpc);
        expect(rpc, 'create_customer_hard_delete_job');
        expect(params, {
          'p_customer_ids': [customer],
        });
        return job();
      };
      SupabaseGateway.customerStorageRemoveHandler = (_) async =>
          fail('no native remove before PURGED');
      SupabaseGateway.automationEvidenceCleanupHandler =
          (function, body) async {
            expect(function, 'automation-evidence-cleanup');
            expect(body, {'request_id': requestId});
            return {'request_id': requestId, 'state': 'PENDING', 'count': 0};
          };
      final repo = SyntheticDeleteRepository();
      final result = await repo.hardDeleteCustomersWithSync([
        customer,
      ], 'synthetic');
      expect(result.created, isTrue);
      expect(result.pending, isTrue);
      expect(result.jobId, jobId);
      expect(result.cleanupRequestId, requestId);
      expect(result.cleanupNotBefore?.isUtc, isTrue);
      expect(result.customerCount, 0);
      expect(calls, ['create_customer_hard_delete_job']);
      repo.dispose();
    },
  );

  test('deliberate same-selection resume uses same job/plan, then removes only legacy paths', () async {
    final calls = <String>[];
    var cleanups = 0;
    SupabaseGateway.hardDeleteRpcHandler = (rpc, params) async {
      calls.add(rpc);
      if (rpc == 'create_customer_hard_delete_job') return job();
      expect(params['p_job_id'], jobId);
      expect(rpc, isNot('fail_customer_hard_delete'));
      return {
        'job_id': jobId,
        'status': 'COMPLETED',
        'customer_count': 1,
        'storage_object_count': 2,
      };
    };
    SupabaseGateway.customerStorageRemoveHandler = (paths) async {
      calls.add('legacy_storage_remove');
      expect(paths, [
        {'bucket': 'passport-documents', 'path': legacyPath},
      ]);
    };
    SupabaseGateway.automationEvidenceCleanupHandler = (function, body) async {
      expect(body, {'request_id': requestId});
      cleanups++;
      return {
        'request_id': requestId,
        'count': cleanups == 1 ? 0 : 1,
        'state': cleanups == 1 ? 'PENDING' : 'PURGED',
      };
    };
    final repo = SyntheticDeleteRepository();
    expect(
      (await repo.hardDeleteCustomersWithSync([customer], 'synthetic')).pending,
      isTrue,
    );
    final completed = await repo.hardDeleteCustomersWithSync([
      customer,
    ], 'synthetic');
    expect(completed.pending, isFalse);
    expect(completed.created, isTrue);
    expect(completed.jobId, jobId);
    expect(completed.customerCount, 1);
    expect(calls, [
      'create_customer_hard_delete_job',
      'create_customer_hard_delete_job',
      'legacy_storage_remove',
      'mark_customer_hard_delete_storage_cleaned',
      'complete_customer_hard_delete',
    ]);
    repo.dispose();
  });

  test('network/HTTP uncertainty never fails the managed job or reports completion', () async {
    for (final error in [
      StateError('synthetic-secret-network'),
      const FunctionException(
        status: 409,
        details: {'request_id': requestId, 'state': 'PENDING', 'count': 0},
      ),
    ]) {
      var rpcCalls = 0;
      SupabaseGateway.hardDeleteRpcHandler = (rpc, params) async {
        rpcCalls++;
        expect(rpc, 'create_customer_hard_delete_job');
        return job();
      };
      SupabaseGateway.automationEvidenceCleanupHandler = (
        function,
        body,
      ) async => throw error;
      SupabaseGateway.customerStorageRemoveHandler = (_) async =>
          fail('native delete must not run');
      final repo = SyntheticDeleteRepository();
      expect(
        (await repo.hardDeleteCustomersWithSync([
          customer,
        ], 'synthetic')).pending,
        isTrue,
      );
      expect(rpcCalls, 1);
      repo.dispose();
    }
  });

  test(
    'wrong/malformed cleanup response cannot authorize completion',
    () async {
      for (final reply in [
        null,
        {},
        {'request_id': jobId, 'state': 'PURGED', 'count': 1},
        {'request_id': requestId, 'state': 'PURGED', 'count': -1},
        {'request_id': requestId, 'state': 'PURGED'},
        {'request_id': requestId, 'state': 'COMPLETE', 'count': 1},
      ]) {
        SupabaseGateway.automationEvidenceCleanupHandler = (
          function,
          body,
        ) async => reply;
        expect(
          (await SupabaseGateway.cleanupAutomationEvidence(requestId))['state'],
          'PENDING',
        );
      }
    },
  );

  test(
    'HTTP failure cannot authorize completion even with a PURGED response body',
    () async {
      SupabaseGateway.automationEvidenceCleanupHandler =
          (function, body) async => throw const FunctionException(
            status: 500,
            details: {'request_id': requestId, 'state': 'PURGED', 'count': 1},
          );
      expect(
        (await SupabaseGateway.cleanupAutomationEvidence(requestId))['state'],
        'PENDING',
      );
    },
  );

  test('old legal job without managed evidence keeps its existing cleanup sequence', () async {
    final calls = <String>[];
    SupabaseGateway.hardDeleteRpcHandler = (rpc, params) async {
      calls.add(rpc);
      return rpc == 'create_customer_hard_delete_job'
          ? job(managed: false)
          : {
              'job_id': jobId,
              'status': 'COMPLETED',
              'customer_count': 1,
              'storage_object_count': 1,
            };
    };
    SupabaseGateway.customerStorageRemoveHandler = (paths) async {
      calls.add('legacy_storage_remove');
      expect(paths.single['path'], legacyPath);
    };
    SupabaseGateway.automationEvidenceCleanupHandler = (function, body) async =>
        fail('no managed plan to invoke');
    final repo = SyntheticDeleteRepository();
    final completed = await repo.hardDeleteCustomersWithSync([
      customer,
    ], 'synthetic');
    expect(completed.created, isTrue);
    expect(completed.pending, isFalse);
    expect(calls, [
      'create_customer_hard_delete_job',
      'legacy_storage_remove',
      'mark_customer_hard_delete_storage_cleaned',
      'complete_customer_hard_delete',
    ]);
    repo.dispose();
  });

  test('only exact job COMPLETED with actual nonnegative integer counts is successful', () async {
    const completed = {
      'job_id': jobId,
      'status': 'COMPLETED',
      'customer_count': 1,
      'storage_object_count': 2,
      'deleted_ocr_batch_ids': <String>[],
    };
    for (final reply in [
      null,
      {},
      {...completed, 'job_id': requestId},
      {...completed, 'status': 'PENDING'},
      {...completed, 'status': 'STORAGE_CLEANED'},
      {...completed, 'customer_count': -1},
      {...completed, 'storage_object_count': -1},
      {...completed, 'customer_count': '1'},
      {...completed, 'storage_object_count': 1.5},
    ]) {
      SupabaseGateway.hardDeleteRpcHandler = (rpc, params) async => reply;
      await expectLater(
        SupabaseGateway.completeCustomerHardDelete(jobId),
        throwsFormatException,
      );
    }
    SupabaseGateway.hardDeleteRpcHandler = (rpc, params) async => completed;
    expect(await SupabaseGateway.completeCustomerHardDelete(jobId), completed);
  });

  test('protected path without a server plan keeps job pending, never client deletes', () async {
    SupabaseGateway.hardDeleteRpcHandler = (rpc, params) async {
      expect(rpc, 'create_customer_hard_delete_job');
      return job()..remove('cleanup_request_id');
    };
    SupabaseGateway.customerStorageRemoveHandler = (_) async =>
        fail('protected fallback forbidden');
    final repo = SyntheticDeleteRepository();
    expect(
      (await repo.hardDeleteCustomersWithSync([customer], 'synthetic')).pending,
      isTrue,
    );
    repo.dispose();
  });

  test(
    'malformed manifest preserves a managed pending job instead of fail/mark',
    () async {
      SupabaseGateway.hardDeleteRpcHandler = (rpc, params) async {
        expect(rpc, 'create_customer_hard_delete_job');
        return {
          ...job(),
          'storage_paths': [null],
        };
      };
      final repo = SyntheticDeleteRepository();
      expect(
        (await repo.hardDeleteCustomersWithSync([
          customer,
        ], 'synthetic')).pending,
        isTrue,
      );
      repo.dispose();
    },
  );

  test(
    'bare Storage helper refuses every protected namespace before any removal',
    () async {
      var removals = 0;
      SupabaseGateway.customerStorageRemoveHandler = (_) async {
        removals++;
      };
      for (final prefix in [
        'automation-attempt-evidence',
        'mdac-human-evidence',
        'human-query-evidence',
      ]) {
        await expectLater(
          SupabaseGateway.removeCustomerStorageObjects([
            {'bucket': 'passport-documents', 'path': legacyPath},
            {
              'bucket': 'passport-documents',
              'path': '$prefix/$jobId/synthetic.png',
            },
          ]),
          throwsFormatException,
        );
      }
      expect(removals, 0);
    },
  );
}
