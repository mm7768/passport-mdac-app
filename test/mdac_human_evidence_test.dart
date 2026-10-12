import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:passport_mdac_app/main.dart';
import 'package:passport_mdac_app/main_isolation.dart';
import 'package:passport_mdac_app/mdac_human_evidence.dart';
import 'package:passport_mdac_app/supabase_gateway.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  const actor = '00000000-0000-4000-8000-000000000001';
  const item = '00000000-0000-4000-8000-000000000002';
  const evidence = '00000000-0000-4000-8000-000000000003';
  tearDown(SupabaseGateway.resetTestingHandlers);

  test(
    'isolated preview rejects absent or privileged keys before initialization',
    () {
      const url = 'https://rvgslhjmiaunylwhcamz.supabase.co';
      requireIsolationPreviewConfiguration(url, 'sb_publishable_synthetic');
      for (final key in ['', 'sb_secret_synthetic', 'invalid-key']) {
        expect(
          () => requireIsolationPreviewConfiguration(url, key),
          throwsStateError,
        );
      }
      expect(
        () => requireIsolationPreviewConfiguration(
          'https://xdmcxhvdqsbcqedfprcy.supabase.co',
          'sb_publishable_synthetic',
        ),
        throwsStateError,
      );
    },
  );

  test('disconnected retry cannot show successful queueing', () async {
    final repository = DemoRepository();
    expect(
      await repository.requeueAutomationTask(item, 'synthetic'),
      isNotNull,
    );
    expect(
      await repository.requeueFailedAutomationItems(item, 'synthetic'),
      isNotNull,
    );
    repository.dispose();
  });

  test(
    'two retry buttons cannot send overlapping calls for the same batch',
    () async {
      final reply = Completer<void>();
      var calls = 0;
      SupabaseGateway.requeueRpcHandler = (rpc, params) async {
        calls++;
        await reply.future;
        return {
          'id': item,
          'request_id': params['p_request_id'],
          'requeued_item_ids': [evidence],
          'attempt_ids': [actor],
          'replayed': false,
        };
      };
      final repository = _SyntheticRetryRepository();
      final first = repository.requeueAutomationTask(item, 'synthetic');
      expect(
        await repository.requeueFailedAutomationItems(item, 'synthetic'),
        isNotNull,
      );
      expect(calls, 1);
      reply.complete();
      expect(await first, isNull);
      expect(
        await repository.requeueFailedAutomationItems(item, 'synthetic'),
        isNull,
      );
      expect(calls, 2);
      repository.dispose();
    },
  );

  test('reason code and actor/item/unique object are exact frozen JSON', () {
    final result = mdacHumanEvidencePayload(
      actorId: actor,
      itemId: item,
      evidenceId: evidence,
      extension: 'png',
      reason: 'INDEPENDENT_CHECK',
    );
    expect(result, {
      'reason': 'INDEPENDENT_CHECK',
      'evidence_ref': {
        'bucket': 'passport-documents',
        'path': 'mdac-human-evidence/$actor/$item/$evidence.png',
      },
    });
    expect(result.containsKey('human_confirmed_success'), isFalse);
  });
  test('free text PII reason, URLs and non UUID refs are rejected', () {
    for (final reason in ['', 'someone passport', 'https://synthetic.test']) {
      expect(
        () => mdacHumanEvidencePayload(
          actorId: actor,
          itemId: item,
          evidenceId: evidence,
          extension: 'pdf',
          reason: reason,
        ),
        throwsFormatException,
      );
    }
    expect(
      () => mdacHumanEvidencePayload(
        actorId: actor,
        itemId: 'other/path',
        evidenceId: evidence,
        extension: 'png',
        reason: 'MANUAL_UNKNOWN',
      ),
      throwsFormatException,
    );
  });
  test('each action generates independent canonical UUIDv4 paths', () {
    final ids = List.generate(100, (_) => newMdacHumanEvidenceId());
    expect(ids.toSet().length, 100);
    for (final id in ids) {
      expect(
        id,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
    }
  });
  test('PNG and PDF magic bytes require matching declared extension', () {
    final png = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10, 0]);
    final pdf = Uint8List.fromList([37, 80, 68, 70, 45, 0]);
    expect(validateMdacHumanFile(png, 'png'), 'image/png');
    expect(validateMdacHumanFile(pdf, 'pdf'), 'application/pdf');
    expect(() => validateMdacHumanFile(png, 'pdf'), throwsFormatException);
    expect(() => validateMdacHumanFile(pdf, 'jpg'), throwsFormatException);
  });
  test('empty, oversized or invalid evidence fails before upload', () {
    for (final bytes in [
      Uint8List(0),
      Uint8List(6 * 1024 * 1024 + 1),
      Uint8List.fromList([1, 2, 3]),
    ]) {
      expect(() => validateMdacHumanFile(bytes, 'png'), throwsFormatException);
    }
  });
  test('production and ambiguous runtime URLs are rejected', () {
    requireMdacHumanIsolation(
      'https://rvgslhjmiaunylwhcamz.supabase.co/rest/v1',
    );
    for (final url in [
      'https://xdmcxhvdqsbcqedfprcy.supabase.co/rest/v1',
      'http://rvgslhjmiaunylwhcamz.supabase.co/rest/v1',
      'https://rvgslhjmiaunylwhcamz.supabase.co/rest/v1?override=true',
    ]) {
      expect(() => requireMdacHumanIsolation(url), throwsStateError);
    }
  });
  test(
    'controlled deletion PENDING is returned without direct writes',
    () async {
      SupabaseGateway.humanEvidenceDeleteRpcHandler = (rpc, params) async {
        expect(rpc, 'delete_customer_human_evidence');
        expect(params, {'p_check_id': item, 'p_type': 'VISIT_PASS_CHECK'});
        return {
          'deleted': false,
          'state': 'PENDING',
          'request_id': evidence,
          'check_id': item,
          'type': 'VISIT_PASS_CHECK',
        };
      };
      final result = await SupabaseGateway.deleteCustomerHumanEvidence(
        checkId: item,
        type: 'VISIT_PASS_CHECK',
        screenshotPath: 'untrusted/path.png',
      );
      expect(result['deleted'], isFalse);
    },
  );
  test('controlled completed deletion requires exact check/type', () async {
    SupabaseGateway.humanEvidenceDeleteRpcHandler = (rpc, params) async => {
      'deleted': true,
      'check_id': item,
      'type': 'REGISTRATION_CHECK',
    };
    expect(
      (await SupabaseGateway.deleteCustomerHumanEvidence(
        checkId: item,
        type: 'REGISTRATION_CHECK',
      ))['deleted'],
      isTrue,
    );
    await expectLater(
      SupabaseGateway.deleteCustomerHumanEvidence(
        checkId: item,
        type: 'VISIT_PASS_CHECK',
      ),
      throwsFormatException,
    );
  });
  test('missing RPC refuses without naked deletion fallback', () async {
    var calls = 0;
    SupabaseGateway.humanEvidenceDeleteRpcHandler = (rpc, params) async {
      calls++;
      throw const PostgrestException(
        message: 'synthetic missing',
        code: 'PGRST202',
      );
    };
    await expectLater(
      SupabaseGateway.deleteCustomerHumanEvidence(
        checkId: item,
        type: 'VISIT_PASS_CHECK',
      ),
      throwsA(isA<PostgrestException>()),
    );
    expect(calls, 1);
  });
  test('invalid pending cleanup cannot be reported as accepted', () async {
    SupabaseGateway.humanEvidenceDeleteRpcHandler = (rpc, params) async => {
      'deleted': false,
      'state': 'PENDING',
      'request_id': 'not-uuid',
      'check_id': item,
      'type': 'VISIT_PASS_CHECK',
    };
    await expectLater(
      SupabaseGateway.deleteCustomerHumanEvidence(
        checkId: item,
        type: 'VISIT_PASS_CHECK',
      ),
      throwsFormatException,
    );
  });
  test(
    'old FOUND cleanup helper is fail closed rather than immediate erase',
    () async {
      await expectLater(
        SupabaseGateway.deleteCustomerOldVisitPassScreenshots(
          customerId: actor,
          currentScreenshotPath: 'synthetic/path.png',
        ),
        throwsStateError,
      );
    },
  );
}

class _SyntheticRetryRepository extends DemoRepository {
  @override
  bool get remoteMode => true;

  @override
  Future<String?> syncAutomationTasksFromSupabase() async => null;

  @override
  Future<String?> syncCustomersFromSupabase() async => null;
}
