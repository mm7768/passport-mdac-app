import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:passport_mdac_app/main.dart';
import 'package:passport_mdac_app/supabase_gateway.dart';

class RemoteRepository extends DemoRepository {
  @override
  bool get remoteMode => true;
}

class RetryRepository extends RemoteRepository {
  @override
  Future<String?> syncAutomationTasksFromSupabase() async => null;
  @override
  Future<String?> syncCustomersFromSupabase() async => null;
}

class WidgetRetryRepository extends RetryRepository {
  final pending = Completer<String?>();
  bool busy = false;
  int calls = 0;
  @override
  bool isRetryingBatch(String id) => busy;
  @override
  Future<String?> requeueFailedAutomationItems(String id, String actor) async {
    calls++;
    busy = true;
    notifyListeners();
    final result = await pending.future;
    busy = false;
    notifyListeners();
    return result;
  }
}

Map<String, dynamic> item(int i, String status) => {
  'id': 'item-$i', 'customer_id': 'customer-$i', 'case_id': 'case-$i',
  'status': status, 'attempt_count': 2,
  'result_unknown': status == 'NEEDS_REVIEW', 'submission_started_at': null,
};

Map<String, dynamic> batch(List<Map<String, dynamic>> items) => {
  'id': 'batch-test', 'task_type': 'MDAC_REGISTRATION', 'status': 'NEEDS_REVIEW',
  'created_at': '2026-10-27T00:00:00Z', 'created_by': 'owner',
  'total_count': 20, 'success_count': 20, 'failed_count': 0,
  'attempt_count': 1, 'lease_expires_at': null, 'items': items,
};

AutomationTask task(List<Map<String, dynamic>> items) => AutomationTask(
  id: 'batch-test', type: TaskType.mdacRegistration, customerIds: const [],
  createdAt: DateTime(2026), createdBy: 'owner',
  status: TaskStatus.needsReview, totalCountOverride: 20,
  successCount: 20, failedCount: 1, items: items,
);

void install(Future<http.Response> Function(http.Request) handler) {
  SupabaseGateway.useClientForTesting(SupabaseClient(
    'https://isolated.invalid', 'test-public-key',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
    httpClient: MockClient((request) async {
      final response = await handler(request);
      return http.Response(response.body, response.statusCode,
        headers: response.headers, request: request);
    }),
  ));
}

void main() {
  tearDown(() async {
    await SupabaseGateway.client?.dispose();
    SupabaseGateway.useClientForTesting(null);
  });

  test('actual main model counts 19 success and 1 review once, ignoring attempts', () {
    final rows = [for (var i=0; i<19; i++) item(i, 'SUCCEEDED'), item(19, 'NEEDS_REVIEW')];
    rows[0]['attempt_count'] = 5;
    final t=task([...rows, rows.first]);
    expect(t.totalCount, 20);
    expect(t.successCount, 19);
    expect(t.failedCount, 0);
    expect(t.needsReviewCount, 1);
    expect(t.completedCount, 19);
    expect(t.progress, .95);
    expect(t.retryableCount, 0);
  });

  test('latest and historical repository paths ignore stale overlapping counters', () async {
    final rows=[for(var i=0;i<19;i++) item(i,'SUCCEEDED'),item(19,'NEEDS_REVIEW')];
    install((request) async {
      expect(request.method, anyOf('POST', 'GET'));
      return http.Response(jsonEncode([batch(rows)]),200,headers:{'content-type':'application/json'});
    });
    final repo=RemoteRepository();
    expect(await repo.syncAutomationTasksFromSupabase(),isNull);
    await repo.fetchBatchHistory(refresh:true);
    for(final t in [repo.tasks.single,repo.historyTasks.single]) {
      expect(t.totalCount,20); expect(t.successCount,19);
      expect(t.failedCount,0); expect(t.completedCount,19);
      expect(t.needsReviewCount,1);
    }
    expect(repo.historyTasks.single.detailsLoaded,isFalse);
  });

  test('retry uses only authorized RPC with batch ID, no table PATCH', () async {
    final calls=<http.Request>[];
    install((request) async {
      calls.add(request);
      expect(request.method,'POST');
      expect(request.url.path,'/rest/v1/rpc/requeue_automation_batch');
      expect(jsonDecode(request.body),{'p_batch_id':'batch-test'});
      return http.Response('{"id":"batch-test","status":"QUEUED"}',200);
    });
    await SupabaseGateway.requeueFailedItems('batch-test');
    expect(calls,hasLength(1));
  });

  test('opening lightweight history details reloads results and consistent counts', () async {
    final rows=[for(var i=0;i<19;i++) item(i,'SUCCEEDED'),item(19,'NEEDS_REVIEW')];
    install((request) async {
      final body = request.url.path.endsWith('/automation_items') ? rows
          : request.url.path.endsWith('/automation_batches') ? batch(rows) : [];
      return http.Response(jsonEncode(body),200);
    });
    final history=AutomationTask(id:'batch-test',type:TaskType.mdacRegistration,
      customerIds:const [],createdAt:DateTime(2026),createdBy:'owner',
      status:TaskStatus.needsReview,successCount:20,failedCount:1,
      items:rows,detailsLoaded:false,totalCountOverride:20);
    final loaded=await RemoteRepository().loadTaskDetailOnDemand(history);
    expect(loaded.detailsLoaded,isTrue);
    expect(loaded.completedCount,19); expect(loaded.successCount,19);
    expect(loaded.failedCount,0); expect(loaded.needsReviewCount,1);
  });

  test('RPC denial has no fallback and preserves the original error', () async {
    var calls=0;
    install((request) async {
      calls++;
      return http.Response('{"code":"42501","message":"Only the batch owner may retry it","details":null,"hint":null}',403);
    });
    await expectLater(SupabaseGateway.requeueFailedItems('batch-test'),throwsA(isA<PostgrestException>()));
    expect(calls,1);
  });

  test('unconfirmed or wrong batch reply never becomes success', () async {
    install((_) async => http.Response('{"id":"other-batch"}',200));
    await expectLater(SupabaseGateway.requeueFailedItems('batch-test'),throwsFormatException);
  });

  test('both repository retry entry points share the in-flight guard', () async {
    final pending=Completer<http.Response>(); var calls=0;
    install((_) {calls++; return pending.future;});
    final repo=RetryRepository();
    final first=repo.requeueFailedAutomationItems('batch-test','owner');
    expect(repo.isRetryingBatch('batch-test'),isTrue);
    expect(await repo.requeueAutomationTask('batch-test','owner'),isNotNull);
    pending.complete(http.Response('{"id":"batch-test"}',200));
    expect(await first,isNull); expect(calls,1);
    expect(repo.isRetryingBatch('batch-test'),isFalse);
  });

  testWidgets('real retry button waits for RPC and disables repeat taps', (tester) async {
    final repo=WidgetRetryRepository();
    await tester.pumpWidget(MaterialApp(home:Scaffold(body:TaskRetryButton(
      task:task([item(1,'FAILED')]),repository:repo,
    ))));
    await tester.tap(find.text('重试失败项 (1)')); await tester.pump();
    expect(find.text('正在重新排队…'),findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,isNull);
    repo.pending.complete(null);
    await tester.pumpAndSettle(); expect(repo.calls,1);
  });

  testWidgets('unknown review cannot trigger an automatic retry', (tester) async {
    final repo=WidgetRetryRepository();
    await tester.pumpWidget(MaterialApp(home:Scaffold(body:TaskRetryButton(
      task:task([item(1,'NEEDS_REVIEW')]),repository:repo,
    ))));
    expect(find.text('需先核查执行结果'),findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,isNull);
    expect(repo.calls,0);
  });
}
