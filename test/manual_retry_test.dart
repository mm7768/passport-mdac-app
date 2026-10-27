import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:passport_mdac_app/features/tasks/manual_retry.dart';
import 'package:passport_mdac_app/main.dart';
import 'package:passport_mdac_app/supabase_gateway.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const requestId = '11111111-1111-4111-8111-111111111111';

ManualRetryPreview preview({
  String type = 'MDAC_REGISTRATION',
  int safe = 1,
  int uncertain = 1,
  String status = 'READY',
}) => ManualRetryPreview(
  status: status,
  taskType: type,
  snapshotToken: 'server-snapshot',
  safeCount: safe,
  uncertainCount: uncertain,
  excludedSuccessCount: 13,
  blockedReason: status == 'BLOCKED' ? 'LIVE_LEASE' : null,
);

class ManualRepository extends DemoRepository {
  ManualRepository(this.controller);
  final ManualRetryController controller;
  @override
  ManualRetryController manualRetryController(String batchId) => controller;
  @override
  Future<String?> syncAutomationTasksFromSupabase() async => null;
  @override
  Future<String?> syncCustomersFromSupabase() async => null;
}

AutomationTask reviewTask(TaskType type) => AutomationTask(
  id: 'synthetic-batch',
  type: type,
  customerIds: const [],
  createdAt: DateTime(2026),
  createdBy: 'synthetic-owner',
  status: TaskStatus.needsReview,
  items: [
    for (var i = 0; i < 13; i++) {'id': 'success-$i', 'status': 'SUCCEEDED'},
    for (var i = 0; i < 2; i++)
      {
        'id': 'review-$i',
        'status': 'NEEDS_REVIEW',
        'result_unknown': true,
        'submission_started_at': i == 0 ? null : '2026-10-28',
      },
  ],
);

Future<void> mount(
  WidgetTester tester,
  ManualRetryController controller, {
  TaskType type = TaskType.mdacRegistration,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: TaskRetryButton(
        task: reviewTask(type),
        repository: ManualRepository(controller),
      ),
    ),
  ),
);

void install(Future<http.Response> Function(http.Request) handler) {
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
          headers: response.headers,
          request: request,
        );
      }),
    ),
  );
}

void main() {
  tearDown(() async {
    await SupabaseGateway.client?.dispose();
    SupabaseGateway.useClientForTesting(null);
  });

  for (final type in TaskType.values) {
    testWidgets(
      '$type review-only batch exposes manual retry without auto calls',
      (tester) async {
        var previews = 0;
        var sends = 0;
        final controller = ManualRetryController(
          loadPreview: () async {
            previews++;
            return preview();
          },
          send: (_) async {
            sends++;
            throw StateError('must not run');
          },
        );
        await mount(tester, controller, type: type);
        await tester.pumpAndSettle();
        expect(find.text('重试未成功项 (2)'), findsOneWidget);
        expect(
          tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNotNull,
        );
        expect(previews, 0);
        expect(sends, 0);
      },
    );
  }

  for (final entry in {
    TaskType.mdacRegistration: 'MDAC_REGISTRATION',
    TaskType.registrationCheck: 'REGISTRATION_CHECK',
    TaskType.gmailPin: 'GMAIL_PIN',
    TaskType.visitPassCheck: 'VISIT_PASS_CHECK',
  }.entries) {
    testWidgets('${entry.key} sends only after manual confirmation', (
      tester,
    ) async {
      var previews = 0;
      final intents = <ManualRetryIntent>[];
      final controller = ManualRetryController(
        loadPreview: () async {
          previews++;
          return preview(type: entry.value, safe: 2, uncertain: 0);
        },
        newRequestId: () => requestId,
        send: (intent) async {
          intents.add(intent);
          return const ManualRetryResult(
            requestId: requestId,
            requeuedCount: 2,
            replayed: false,
          );
        },
      );
      await mount(tester, controller, type: entry.key);
      expect(previews, 0);
      expect(intents, isEmpty);
      await tester.tap(find.text('重试未成功项 (2)'));
      await tester.pumpAndSettle();
      expect(previews, 1);
      expect(intents, isEmpty);
      await tester.tap(find.text('确认重试 (2)'));
      await tester.pumpAndSettle();
      expect(intents, hasLength(1));
      expect(intents.single.includeUncertain, isFalse);
    });
  }

  testWidgets(
    'safe-only confirmation excludes 13 successes and uncertain item',
    (tester) async {
      final intents = <ManualRetryIntent>[];
      final controller = ManualRetryController(
        loadPreview: () async => preview(),
        newRequestId: () => requestId,
        send: (intent) async {
          intents.add(intent);
          return const ManualRetryResult(
            requestId: requestId,
            requeuedCount: 1,
            replayed: false,
          );
        },
      );
      await mount(tester, controller);
      await tester.tap(find.text('重试未成功项 (2)'));
      await tester.pumpAndSettle();
      expect(find.text('已成功 13 项将保留，不会重新执行。'), findsOneWidget);
      final include = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '仍重试全部 (2)'),
      );
      expect(include.onPressed, isNull);
      expect(intents, isEmpty);
      await tester.tap(find.text('仅重试安全项 (1)'));
      await tester.pumpAndSettle();
      expect(intents, hasLength(1));
      expect(intents.single.includeUncertain, isFalse);
    },
  );

  testWidgets(
    'including possibly submitted MDAC requires explicit risk acknowledgement',
    (tester) async {
      final intents = <ManualRetryIntent>[];
      final controller = ManualRetryController(
        loadPreview: () async => preview(),
        newRequestId: () => requestId,
        send: (intent) async {
          intents.add(intent);
          return const ManualRetryResult(
            requestId: requestId,
            requeuedCount: 2,
            replayed: false,
          );
        },
      );
      await mount(tester, controller);
      await tester.tap(find.text('重试未成功项 (2)'));
      await tester.pumpAndSettle();
      expect(intents, isEmpty);
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, '仍重试全部 (2)'),
            )
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.text('仍重试全部 (2)'));
      await tester.pumpAndSettle();
      expect(intents.single.includeUncertain, isTrue);
    },
  );

  testWidgets('blocked preview explains reason and never sends request', (
    tester,
  ) async {
    var sent = 0;
    final controller = ManualRetryController(
      loadPreview: () async => preview(status: 'BLOCKED'),
      send: (_) async {
        sent++;
        throw StateError('must not run');
      },
    );
    await mount(tester, controller);
    await tester.tap(find.text('重试未成功项 (2)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('任务正在执行或租约尚未结束'), findsOneWidget);
    expect(find.textContaining('LIVE_LEASE'), findsNothing);
    expect(sent, 0);
  });

  test('timeout retains exact intent and replay never refreshes into a new request', () async {
    var previews = 0;
    var uuids = 0;
    final intents = <ManualRetryIntent>[];
    final controller = ManualRetryController(
      loadPreview: () async {
        previews++;
        return preview();
      },
      newRequestId: () {
        uuids++;
        return requestId;
      },
      send: (intent) async {
        intents.add(intent);
        if (intents.length == 1) throw TimeoutException('response lost');
        return const ManualRetryResult(
          requestId: requestId,
          requeuedCount: 2,
          replayed: true,
        );
      },
    );
    final p = await controller.previewAfterTap();
    await expectLater(
      controller.confirmAfterTap(p, includeUncertain: true),
      throwsA(isA<TimeoutException>()),
    );
    expect(controller.pending, isNotNull);
    final replayPreview = await controller.previewAfterTap();
    final result = await controller.confirmAfterTap(
      replayPreview,
      includeUncertain: true,
    );
    expect(result.replayed, isTrue);
    expect(identical(intents.first, intents.last), isTrue);
    expect(previews, 1);
    expect(uuids, 1);
    expect(controller.pending, isNull);
  });

  test(
    'duplicate taps cannot submit while first request awaits server',
    () async {
      final pending = Completer<ManualRetryResult>();
      var calls = 0;
      final controller = ManualRetryController(
        loadPreview: () async => preview(),
        newRequestId: () => requestId,
        send: (_) {
          calls++;
          return pending.future;
        },
      );
      final p = await controller.previewAfterTap();
      final first = controller.confirmAfterTap(p, includeUncertain: false);
      await expectLater(
        controller.confirmAfterTap(p, includeUncertain: false),
        throwsA(isA<ManualRetryRejected>()),
      );
      expect(calls, 1);
      pending.complete(
        const ManualRetryResult(
          requestId: requestId,
          requeuedCount: 1,
          replayed: false,
        ),
      );
      await first;
    },
  );

  test('malformed or wrong request confirmation remains pending', () async {
    final controller = ManualRetryController(
      loadPreview: () async => preview(),
      newRequestId: () => requestId,
      send: (_) async => const ManualRetryResult(
        requestId: 'different',
        requeuedCount: 1,
        replayed: false,
      ),
    );
    final p = await controller.previewAfterTap();
    await expectLater(
      controller.confirmAfterTap(p, includeUncertain: false),
      throwsFormatException,
    );
    expect(controller.pending?.requestId, requestId);
  });

  test('known SQL rejection clears intent for a fresh user preview', () async {
    var previews = 0;
    final controller = ManualRetryController(
      loadPreview: () async {
        previews++;
        return preview();
      },
      send: (_) async => throw const ManualRetryRejected('stale'),
    );
    final p = await controller.previewAfterTap();
    await expectLater(
      controller.confirmAfterTap(p, includeUncertain: false),
      throwsA(isA<ManualRetryRejected>()),
    );
    expect(controller.pending, isNull);
    await controller.previewAfterTap();
    expect(previews, 2);
  });

  test('transport uses only generic preview/request RPCs with confirmation payload', () async {
    final calls = <http.Request>[];
    install((request) async {
      calls.add(request);
      expect(request.method, 'POST');
      if (calls.length == 1) {
        expect(
          request.url.path,
          '/rest/v1/rpc/preview_automation_manual_retry',
        );
        expect(jsonDecode(request.body), {'p_batch_id': 'synthetic-batch'});
        return http.Response(
          jsonEncode({
            'status': 'READY',
            'task_type': 'MDAC_REGISTRATION',
            'safe_count': 1,
            'uncertain_count': 1,
            'excluded_success_count': 13,
            'snapshot_token': 'server-snapshot',
          }),
          200,
        );
      }
      expect(request.url.path, '/rest/v1/rpc/request_automation_manual_retry');
      expect(jsonDecode(request.body), {
        'p_batch_id': 'synthetic-batch',
        'p_request_id': requestId,
        'p_snapshot_token': 'server-snapshot',
        'p_include_uncertain': true,
      });
      return http.Response(
        jsonEncode({
          'status': 'QUEUED',
          'request_id': requestId,
          'requeued_count': 2,
          'replayed': false,
        }),
        200,
      );
    });
    final p = await SupabaseGateway.previewAutomationManualRetry(
      'synthetic-batch',
    );
    await SupabaseGateway.requestAutomationManualRetry(
      'synthetic-batch',
      ManualRetryIntent(
        requestId: requestId,
        preview: p,
        includeUncertain: true,
      ),
    );
    expect(calls, hasLength(2));
  });

  test('missing new RPC reports upgrade needed and never falls back', () async {
    var calls = 0;
    install((_) async {
      calls++;
      return http.Response(
        '{"code":"PGRST202","message":"function missing"}',
        404,
      );
    });
    await expectLater(
      SupabaseGateway.previewAutomationManualRetry('synthetic-batch'),
      throwsA(
        isA<ManualRetryRejected>().having(
          (e) => e.message,
          'message',
          contains('升级'),
        ),
      ),
    );
    expect(calls, 1);
  });

  test('query or PIN preview cannot contain MDAC duplicate-registration uncertainty', () {
    for (final type in [
      'REGISTRATION_CHECK',
      'GMAIL_PIN',
      'VISIT_PASS_CHECK',
    ]) {
      expect(
        () => ManualRetryPreview.fromJson({
          'status': 'READY',
          'task_type': type,
          'snapshot_token': 'snapshot',
          'safe_count': 1,
          'uncertain_count': 1,
          'excluded_success_count': 13,
        }),
        throwsFormatException,
      );
    }
  });

  testWidgets(
    'partially ineligible items are explicitly excluded in confirmation',
    (tester) async {
      final controller = ManualRetryController(
        loadPreview: () async => const ManualRetryPreview(
          status: 'READY',
          taskType: 'MDAC_REGISTRATION',
          snapshotToken: 'snapshot',
          safeCount: 1,
          uncertainCount: 0,
          excludedSuccessCount: 13,
          ineligibleCount: 1,
        ),
        send: (_) async => throw StateError('not confirmed'),
      );
      await mount(tester, controller);
      await tester.tap(find.text('重试未成功项 (2)'));
      await tester.pumpAndSettle();
      expect(find.text('另有 1 项已达重试上限或不符合条件，不在此次重试范围。'), findsOneWidget);
      expect(find.text('确认重试 (1)'), findsOneWidget);
    },
  );

  test('ineligible count if present must be a nonnegative integer', () {
    expect(
      () => ManualRetryPreview.fromJson({
        'status': 'READY',
        'task_type': 'GMAIL_PIN',
        'snapshot_token': 'snapshot',
        'safe_count': 1,
        'uncertain_count': 0,
        'excluded_success_count': 0,
        'ineligible_count': -1,
      }),
      throwsFormatException,
    );
  });

  testWidgets(
    'lost response can be reconfirmed without selecting the risk again',
    (tester) async {
      var calls = 0;
      final controller = ManualRetryController(
        loadPreview: () async => preview(),
        newRequestId: () => requestId,
        send: (_) async {
          calls++;
          if (calls == 1) throw TimeoutException('response lost');
          return const ManualRetryResult(
            requestId: requestId,
            requeuedCount: 2,
            replayed: true,
          );
        },
      );
      await mount(tester, controller);
      await tester.tap(find.text('重试未成功项 (2)'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      await tester.tap(find.text('仍重试全部 (2)'));
      await tester.pumpAndSettle();
      expect(find.text('确认上次重试请求'), findsOneWidget);
      await tester.tap(find.text('确认上次重试请求'));
      await tester.pumpAndSettle();
      expect(find.byType(Checkbox), findsNothing);
      expect(find.text('确认同一请求'), findsOneWidget);
      await tester.tap(find.text('确认同一请求'));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(controller.pending, isNull);
    },
  );
}
