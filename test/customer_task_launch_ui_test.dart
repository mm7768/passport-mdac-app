import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:passport_mdac_app/features/batches/batch_models.dart';
import 'package:passport_mdac_app/features/tasks/customer_task_launch.dart';
import 'package:passport_mdac_app/main.dart';

Customer customer(int i) => Customer(
  id: 'customer-$i',
  fullName: 'SYNTHETIC CUSTOMER $i',
  passportNumber: 'TEST$i',
  dateOfBirth: '01/01/1990',
  placeOfBirth: 'TEST',
  nationality: 'CHN',
  gender: '男',
  passportExpiryDate: '01/01/2035',
  businessStatus: 'PENDING',
  createdAt: DateTime(2026, 10, 28),
  createdBy: 'Synthetic owner',
  pin: '123456',
);

CustomerTaskOrderChoice order(int i, {String? caseId, String? orderNo}) =>
    CustomerTaskOrderChoice(
      customerId: 'customer-$i',
      caseId: caseId ?? 'case-$i',
      orderNo: orderNo ?? 'ORD-$i',
      passportId: 'passport-$i',
      businessStatus: 'CURRENT',
      arrivalDate: '2026-10-28',
      departureDate: '2026-10-30',
    );

class LaunchCoordinator extends CustomerTaskLaunchCoordinator {
  LaunchCoordinator(this.choices);
  final List<CustomerTaskOrderChoice> choices;
  int reads = 0;
  int prepares = 0;
  List<CustomerTaskOrderChoice> prepared = [];
  @override
  Future<List<CustomerTaskOrderChoice>> loadOrders(
    List<String> customerIds,
  ) async {
    reads++;
    return choices.where((o) => customerIds.contains(o.customerId)).toList();
  }

  @override
  Future<List<CustomerTaskLaunchGroup>> prepareSelectedOrders(
    List<CustomerTaskOrderChoice> choices, {
    String? batchName,
  }) async {
    prepares++;
    prepared = choices;
    return [
      CustomerTaskLaunchGroup(
        batchId: 'explicit-batch',
        orders: choices
            .map(
              (o) => AppBatchOrder(
                membershipId: 'member-${o.caseId}',
                batchId: 'explicit-batch',
                orderId: o.caseId,
                caseId: o.caseId,
                orderNo: o.orderNo,
                customerId: o.customerId,
                passportId: o.passportId,
                displayName: 'Synthetic',
                passportNumber: 'TEST',
                businessStatus: 'CURRENT',
                priority: 'NORMAL',
                membershipStatus: 'ACTIVE',
              ),
            )
            .toList(),
      ),
    ];
  }
}

class LaunchRepository extends DemoRepository {
  LaunchRepository(int count) {
    customers
      ..clear()
      ..addAll(List.generate(count, customer));
    tasks.clear();
  }
  int legacyCalls = 0;
  final launchedTypes = <TaskType>[];
  final launchedOrders = <AppBatchOrder>[];
  @override
  bool get remoteMode => true;
  @override
  Future<String?> syncMdacBatchMembershipsFromSupabase() async => null;
  @override
  Future<String?> syncAutomationTasksFromSupabase() async => null;
  @override
  Future<String?> createTaskAsync({
    required TaskType type,
    required List<String> customerIds,
    required String actor,
    DateTime? entryDate,
    DateTime? exitDate,
  }) async {
    legacyCalls++;
    return 'Legacy enqueue must not run';
  }

  @override
  Future<String?> createBatchDrivenTaskAsync({
    required TaskType type,
    required String batchId,
    required List<AppBatchOrder> orders,
    required String actor,
    DateTime? entryDate,
    DateTime? exitDate,
  }) async {
    launchedTypes.add(type);
    launchedOrders.addAll(orders);
    return null;
  }
}

Future<void> mount(
  WidgetTester tester,
  LaunchRepository repo,
  LaunchCoordinator coordinator, {
  VoidCallback? onTaskCreated,
}) async {
  tester.view.physicalSize = const Size(360, 780);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        bottomNavigationBar: MobileNav(
          current: AppSection.customers,
          onSelect: (_) {},
        ),
        body: CustomersScreen(
          repository: repo,
          actor: 'Synthetic owner',
          role: UserRole.owner,
          initialSelectedCustomerIds: repo.customers.map((c) => c.id).toList(),
          taskLaunchCoordinator: coordinator,
          onTaskCreated: onTaskCreated,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder launchChip(String text) => find.descendant(
  of: find.byKey(const ValueKey('customer-task-launch-actions')),
  matching: find.widgetWithText(ActionChip, text),
);

void main() {
  testWidgets(
    '19 selected remote customers show all four reachable launch actions above nav',
    (tester) async {
      final repo = LaunchRepository(19);
      final coordinator = LaunchCoordinator(List.generate(19, order));
      await mount(tester, repo, coordinator);
      for (final title in [
        'MDAC 注册',
        '获取 PIN',
        '查 Registration',
        '查 Visit Pass',
      ]) {
        final chip = launchChip(title);
        expect(chip, findsOneWidget);
        await tester.ensureVisible(chip);
        await tester.pumpAndSettle();
        expect(tester.widget<ActionChip>(chip).onPressed, isNotNull);
        expect(
          tester.getRect(chip).bottom,
          lessThanOrEqualTo(tester.getRect(find.byType(MobileNav)).top),
        );
      }
      expect(coordinator.reads, 0);
      expect(coordinator.prepares, 0);
      expect(repo.launchedTypes, isEmpty);
      expect(repo.legacyCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  for (final entry in {
    'MDAC 注册': TaskType.mdacRegistration,
    '获取 PIN': TaskType.gmailPin,
    '查 Registration': TaskType.registrationCheck,
    '查 Visit Pass': TaskType.visitPassCheck,
  }.entries) {
    testWidgets(
      '${entry.key} confirms explicit Cases then uses strict batch enqueue',
      (tester) async {
        final repo = LaunchRepository(1);
        final coordinator = LaunchCoordinator([order(0)]);
        var navigated = false;
        await mount(
          tester,
          repo,
          coordinator,
          onTaskCreated: () => navigated = true,
        );
        await tester.ensureVisible(launchChip(entry.key));
        await tester.tap(launchChip(entry.key));
        await tester.pumpAndSettle();
        expect(find.text('订单：ORD-0'), findsOneWidget);
        expect(coordinator.prepares, 0);
        expect(repo.launchedTypes, isEmpty);
        await tester.tap(find.text('确认发起 (1)'));
        await tester.pumpAndSettle();
        expect(coordinator.prepared.single.caseId, 'case-0');
        expect(repo.launchedTypes, [entry.value]);
        expect(repo.launchedOrders.single.membershipId, 'member-case-0');
        expect(repo.launchedOrders.single.caseId, 'case-0');
        expect(repo.legacyCalls, 0);
        expect(navigated, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('cancel after dates were prefilled never prepares or enqueues', (
    tester,
  ) async {
    final repo = LaunchRepository(1);
    final coordinator = LaunchCoordinator([order(0)]);
    await mount(tester, repo, coordinator);
    await tester.ensureVisible(launchChip('MDAC 注册'));
    await tester.tap(launchChip('MDAC 注册'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(coordinator.prepares, 0);
    expect(repo.launchedTypes, isEmpty);
    expect(repo.legacyCalls, 0);
  });

  testWidgets(
    'multiple Cases require explicit choice instead of latest-Case guess',
    (tester) async {
      final repo = LaunchRepository(1);
      final coordinator = LaunchCoordinator([
        order(0, caseId: 'case-A', orderNo: 'ORD-A'),
        order(0, caseId: 'case-B', orderNo: 'ORD-B'),
      ]);
      await mount(tester, repo, coordinator);
      await tester.ensureVisible(launchChip('获取 PIN'));
      await tester.tap(launchChip('获取 PIN'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '确认发起 (1)'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('task-case-customer-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ORD-B · 2026-10-28').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认发起 (1)'));
      await tester.pumpAndSettle();
      expect(coordinator.prepared.single.caseId, 'case-B');
      expect(repo.launchedOrders.single.caseId, 'case-B');
      expect(repo.legacyCalls, 0);
    },
  );

  testWidgets('missing Case blocks launch without auto-creating an order', (
    tester,
  ) async {
    final repo = LaunchRepository(1);
    final coordinator = LaunchCoordinator([]);
    await mount(tester, repo, coordinator);
    await tester.ensureVisible(launchChip('获取 PIN'));
    await tester.tap(launchChip('获取 PIN'));
    await tester.pumpAndSettle();
    expect(find.textContaining('尚无可执行订单'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '确认发起 (1)'))
          .onPressed,
      isNull,
    );
    expect(coordinator.prepares, 0);
    expect(repo.legacyCalls, 0);
  });
}
