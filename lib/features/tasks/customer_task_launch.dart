import 'package:supabase_flutter/supabase_flutter.dart';

import '../../supabase_gateway.dart';
import '../batches/batch_models.dart';

bool _isUuid(String? value) =>
    value != null &&
    RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    ).hasMatch(value);

class CustomerTaskLaunchException implements Exception {
  const CustomerTaskLaunchException(this.message);
  final String message;
  @override
  String toString() => message;
}

class CustomerTaskOrderChoice {
  const CustomerTaskOrderChoice({
    required this.customerId,
    required this.caseId,
    required this.orderNo,
    this.passportId,
    this.arrivalDate,
    this.departureDate,
    this.caseStatus = '',
    this.businessStatus,
  });

  final String customerId;
  final String caseId;
  final String orderNo;
  final String? passportId;
  final String? arrivalDate;
  final String? departureDate;
  final String caseStatus;
  final String? businessStatus;

  bool get isCurrent =>
      businessStatus == null ||
      businessStatus!.trim().isEmpty ||
      businessStatus!.toUpperCase() == 'CURRENT';

  factory CustomerTaskOrderChoice.fromMap(Map<String, dynamic> row) =>
      CustomerTaskOrderChoice(
        customerId: (row['customer_id'] ?? '').toString(),
        caseId: (row['id'] ?? '').toString(),
        orderNo: (row['order_no'] ?? '').toString(),
        passportId: row['passport_id']?.toString(),
        arrivalDate: row['arrival_date']?.toString(),
        departureDate: row['departure_date']?.toString(),
        caseStatus: (row['case_status'] ?? '').toString(),
        businessStatus: row['business_status']?.toString(),
      );
}

class CustomerTaskLaunchGroup {
  CustomerTaskLaunchGroup({
    required this.batchId,
    required List<AppBatchOrder> orders,
  }) : orders = List<AppBatchOrder>.unmodifiable(orders);
  final String batchId;
  final List<AppBatchOrder> orders;
}

typedef CustomerTaskOrderRowsLoader =
    Future<List<Map<String, dynamic>>> Function(List<String> customerIds);
typedef CustomerTaskContextLoader = Future<Map<String, dynamic>?> Function(
  String caseId,
);
typedef CustomerTaskBatchCreator = Future<Map<String, dynamic>> Function(
  List<String> orderIds, {
  String? batchName,
});
typedef CustomerTaskBatchOrdersLoader =
    Future<List<Map<String, dynamic>>> Function(String batchId);

/// Coordinates only explicit user-confirmed task preparation. Reads never create
/// Cases, memberships, or tasks. Actual enqueue stays in createBatchDrivenTaskAsync,
/// which revalidates the open Batch and exact membership again before writing.
class CustomerTaskLaunchCoordinator {
  CustomerTaskLaunchCoordinator({
    CustomerTaskOrderRowsLoader? loadOrderRows,
    CustomerTaskContextLoader? loadContext,
    CustomerTaskBatchCreator? createBatch,
    CustomerTaskBatchOrdersLoader? loadBatchOrders,
    Future<List<Map<String, dynamic>>> Function()? loadActiveBatches,
  }) : _loadOrderRows =
           loadOrderRows ?? SupabaseGateway.fetchCustomerTaskOrderChoices,
       _loadContext =
           loadContext ??
           SupabaseGateway.fetchCustomerTaskOrderExecutionContext,
       _createBatch =
           createBatch ?? SupabaseGateway.createCustomerTaskOperationalBatch,
       _loadBatchOrders =
           loadBatchOrders ?? SupabaseGateway.fetchAppBatchOrders,
       _loadActiveBatches =
           loadActiveBatches ?? SupabaseGateway.fetchAppActiveBatches;

  final CustomerTaskOrderRowsLoader _loadOrderRows;
  final CustomerTaskContextLoader _loadContext;
  final CustomerTaskBatchCreator _createBatch;
  final CustomerTaskBatchOrdersLoader _loadBatchOrders;
  final Future<List<Map<String, dynamic>>> Function() _loadActiveBatches;
  bool _preparing = false;

  Future<List<CustomerTaskOrderChoice>> loadOrders(
    List<String> customerIds,
  ) async {
    final ids = customerIds.toSet();
    if (ids.isEmpty || ids.length > 100 || ids.any((id) => !_isUuid(id))) {
      throw const CustomerTaskLaunchException('请选择 1 至 100 位有效客户。');
    }
    final rows = await _loadOrderRows(ids.toList(growable: false));
    final cases = <String, CustomerTaskOrderChoice>{};
    for (final row in rows) {
      final choice = CustomerTaskOrderChoice.fromMap(row);
      if (!_isUuid(choice.caseId) ||
          !ids.contains(choice.customerId) ||
          choice.orderNo.isEmpty) {
        throw const CustomerTaskLaunchException('订单资料不完整或与所选客户不符，请刷新。');
      }
      if (cases.containsKey(choice.caseId)) {
        throw const CustomerTaskLaunchException('订单列表出现重复记录，请刷新后重试。');
      }
      cases[choice.caseId] = choice;
    }
    final choices = cases.values.toList(growable: false)
      ..sort((a, b) => a.orderNo.compareTo(b.orderNo));
    // Missing/multiple Cases remain visible as missing/multiple choices. No
    // latest-order guess, automatic Case creation, or queue fallback exists.
    return choices;
  }

  Map<String, dynamic> _validateContext(
    CustomerTaskOrderChoice choice,
    Map<String, dynamic> context,
  ) {
    final caseId = (context['case_id'] ?? context['order_id'])?.toString();
    if (caseId != choice.caseId ||
        context['order_id']?.toString() != choice.caseId ||
        context['customer_id']?.toString() != choice.customerId ||
        !_isUuid(context['batch_id']?.toString()) ||
        !_isUuid(context['membership_id']?.toString()) ||
        (context['released_at'] != null) ||
        (context['batch_status'] != null &&
            context['batch_status'] != 'OPEN')) {
      throw const CustomerTaskLaunchException('订单已被重新排单或原批次已关闭，请刷新后重试。');
    }
    return context;
  }

  Future<List<CustomerTaskLaunchGroup>> prepareSelectedOrders(
    List<CustomerTaskOrderChoice> choices, {
    String? batchName,
  }) async {
    if (_preparing) {
      throw const CustomerTaskLaunchException('正在准备任务，请勿重复点击。');
    }
    if (choices.isEmpty ||
        choices.length > 100 ||
        choices.map((c) => c.customerId).toSet().length != choices.length ||
        choices.map((c) => c.caseId).toSet().length != choices.length) {
      throw const CustomerTaskLaunchException('请为每位客户明确选择一个订单，一次最多 100 单。');
    }
    _preparing = true;
    try {
      final fresh = await loadOrders(choices.map((c) => c.customerId).toList());
      final byCase = {for (final c in fresh) c.caseId: c};
      for (final choice in choices) {
        final current = byCase[choice.caseId];
        if (current == null ||
            current.customerId != choice.customerId ||
            !current.isCurrent ||
            current.passportId != choice.passportId ||
            !_isUuid(current.passportId)) {
          throw const CustomerTaskLaunchException(
            '所选订单已归档、结束、换证或缺少证件，请刷新后重新选择。',
          );
        }
      }
      final contexts = <String, Map<String, dynamic>>{};
      final unassigned = <CustomerTaskOrderChoice>[];
      for (final choice in choices) {
        final context = await _loadContext(choice.caseId);
        if (context == null) {
          unassigned.add(choice);
        } else {
          contexts[choice.caseId] = _validateContext(choice, context);
        }
      }
      String? createdBatchId;
      if (unassigned.isNotEmpty) {
        var recoverFromAmbiguousResponse = false;
        try {
          final created = await _createBatch(
            unassigned.map((c) => c.caseId).toList(growable: false),
            batchName: batchName,
          );
          createdBatchId = created['id']?.toString();
          if (!_isUuid(createdBatchId)) {
            throw const FormatException('排单响应缺少有效批次编号。');
          }
        } on PostgrestException catch (error) {
          // A concurrent operator may already have assigned the Cases. Recover
          // only by reads; permission/business errors are never hidden.
          if (error.code != '23505') rethrow;
          recoverFromAmbiguousResponse = true;
        } catch (_) {
          recoverFromAmbiguousResponse = true;
        }
        // Exactly one context-read recovery pass, including a lost HTTP response.
        // Never issue a second create RPC or guess an unrelated/latest batch.
        for (final choice in unassigned) {
          final recovered = await _loadContext(choice.caseId);
          if (recovered == null) {
            throw const CustomerTaskLaunchException(
              '无法确认排单结果，请刷新后重试；系统未重复创建批次。',
            );
          }
          final valid = _validateContext(choice, recovered);
          if (!recoverFromAmbiguousResponse &&
              valid['batch_id']?.toString() != createdBatchId) {
            throw const CustomerTaskLaunchException('订单排单归属已变化，请刷新后重试。');
          }
          contexts[choice.caseId] = valid;
        }
      }
      final open = await _loadActiveBatches();
      final openIds = open
          .map((b) => b['batch_id']?.toString() ?? b['id']?.toString())
          .toSet();
      final byBatch = <String, List<CustomerTaskOrderChoice>>{};
      for (final choice in choices) {
        final id = contexts[choice.caseId]!['batch_id'].toString();
        if (!openIds.contains(id)) {
          throw const CustomerTaskLaunchException('所选订单的排单批次已关闭，请刷新后重试。');
        }
        byBatch.putIfAbsent(id, () => []).add(choice);
      }
      final groups = <CustomerTaskLaunchGroup>[];
      for (final entry in byBatch.entries) {
        final rows = await _loadBatchOrders(entry.key);
        final orders = rows.map(AppBatchOrder.fromMap).toList(growable: false);
        final selected = <AppBatchOrder>[];
        for (final choice in entry.value) {
          final matches = orders
              .where((o) => o.caseId == choice.caseId)
              .toList();
          if (matches.length != 1) {
            throw const CustomerTaskLaunchException('所选订单已被释放或不在当前批次，请刷新后重试。');
          }
          final order = matches.single;
          final expected = contexts[choice.caseId]!;
          if (order.batchId != entry.key ||
              order.orderId != choice.caseId ||
              order.customerId != choice.customerId ||
              order.passportId != choice.passportId ||
              order.membershipId != expected['membership_id']?.toString() ||
              !(order.isActive || order.isCompleted)) {
            throw const CustomerTaskLaunchException('订单成员关系发生变化，请刷新后重试。');
          }
          selected.add(order);
        }
        groups.add(
          CustomerTaskLaunchGroup(batchId: entry.key, orders: selected),
        );
      }
      return List<CustomerTaskLaunchGroup>.unmodifiable(groups);
    } finally {
      _preparing = false;
    }
  }
}
