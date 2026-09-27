import 'package:flutter/foundation.dart';

/// 活跃排单批次模型 (对应 public.get_app_active_batches)
@immutable
class AppOperationalBatch {
  const AppOperationalBatch({
    required this.batchId,
    required this.batchName,
    required this.batchNo,
    required this.status,
    required this.createdAt,
    required this.totalCount,
    required this.completedCount,
    required this.pendingCount,
  });

  final String batchId;
  final String batchName;
  final String batchNo;
  final String status;
  final DateTime createdAt;
  final int totalCount;
  final int completedCount;
  final int pendingCount;

  bool get isOpen => status.toUpperCase() == 'OPEN';

  double get progressRatio {
    if (totalCount <= 0) return 0.0;
    return (completedCount / totalCount).clamp(0.0, 1.0);
  }

  factory AppOperationalBatch.fromMap(Map<String, dynamic> map) {
    return AppOperationalBatch(
      batchId: (map['batch_id'] ?? map['id'] ?? '').toString(),
      batchName: (map['batch_name'] ?? map['display_name'] ?? '未命名批次').toString(),
      batchNo: (map['batch_no'] ?? '').toString(),
      status: (map['status'] ?? 'OPEN').toString(),
      createdAt: DateTime.tryParse(map['created_at']?.toString() ?? '') ?? DateTime.now(),
      totalCount: int.tryParse(map['total_count']?.toString() ?? '') ?? 0,
      completedCount: int.tryParse(map['completed_count']?.toString() ?? '') ?? 0,
      pendingCount: int.tryParse(map['pending_count']?.toString() ?? '') ?? 0,
    );
  }
}

/// 批次内订单记录模型 (对应 public.get_app_batch_orders)
@immutable
class AppBatchOrder {
  const AppBatchOrder({
    required this.membershipId,
    required this.batchId,
    required this.orderId,
    required this.caseId,
    required this.orderNo,
    required this.customerId,
    this.passportId,
    required this.displayName,
    required this.passportNumber,
    required this.businessStatus,
    this.workflowStatus,
    required this.priority,
    required this.membershipStatus,
    this.arrivalDate,
    this.departureDate,
  });

  final String membershipId;
  final String batchId;
  /// 稳定的订单唯一主键 (即 customer_cases.id)，重试/跨批次流转均保持不变
  final String orderId;
  final String caseId;
  /// 人类可读订单编号
  final String orderNo;
  final String customerId;
  final String? passportId;
  final String displayName;
  final String passportNumber;
  final String businessStatus;
  final String? workflowStatus;
  final String priority;
  /// 成员状态 (ACTIVE / COMPLETED / RELEASED)
  final String membershipStatus;
  final String? arrivalDate;
  final String? departureDate;

  bool get isCompleted => membershipStatus.toUpperCase() == 'COMPLETED';
  bool get isActive => membershipStatus.toUpperCase() == 'ACTIVE';

  factory AppBatchOrder.fromMap(Map<String, dynamic> map) {
    final rawArrival = map['arrival_date']?.toString();
    final rawDeparture = map['departure_date']?.toString();

    return AppBatchOrder(
      membershipId: (map['membership_id'] ?? '').toString(),
      batchId: (map['batch_id'] ?? '').toString(),
      orderId: (map['order_id'] ?? map['case_id'] ?? '').toString(),
      caseId: (map['case_id'] ?? map['order_id'] ?? '').toString(),
      orderNo: (map['order_no'] ?? map['order_id'] ?? '').toString(),
      customerId: (map['customer_id'] ?? '').toString(),
      passportId: map['passport_id']?.toString(),
      displayName: (map['display_name'] ?? '未命名客户').toString(),
      passportNumber: (map['passport_number'] ?? '').toString(),
      businessStatus: (map['business_status'] ?? 'CURRENT').toString(),
      workflowStatus: map['workflow_status']?.toString(),
      priority: (map['priority'] ?? 'NORMAL').toString(),
      membershipStatus: (map['membership_status'] ?? 'ACTIVE').toString(),
      arrivalDate: rawArrival,
      departureDate: rawDeparture,
    );
  }
}

/// 订单单项执行上下文模型 (对应 public.get_app_order_execution_context)
@immutable
class AppOrderExecutionContext {
  const AppOrderExecutionContext({
    this.batchId,
    this.membershipId,
    required this.orderId,
    required this.caseId,
    required this.orderNo,
    required this.customerId,
    this.passportId,
    required this.fullName,
    required this.passportNumber,
    required this.nationality,
    this.dateOfBirth,
    this.gender,
    this.passportExpiryDate,
    this.arrivalDate,
    this.departureDate,
    required this.businessStatus,
    required this.workflowStatus,
    required this.priority,
    this.latestPinRecordId,
    this.latestPinStatus,
    this.latestRegistrationCheckId,
    this.latestRegistrationStatus,
    this.latestVisitPassCheckId,
    this.latestVisitPassStatus,
  });

  final String? batchId;
  final String? membershipId;
  final String orderId;
  final String caseId;
  final String orderNo;
  final String customerId;
  final String? passportId;
  final String fullName;
  final String passportNumber;
  final String nationality;
  final String? dateOfBirth;
  final String? gender;
  final String? passportExpiryDate;
  final String? arrivalDate;
  final String? departureDate;
  final String businessStatus;
  final String workflowStatus;
  final String priority;
  final String? latestPinRecordId;
  final String? latestPinStatus;
  final String? latestRegistrationCheckId;
  final String? latestRegistrationStatus;
  final String? latestVisitPassCheckId;
  final String? latestVisitPassStatus;

  factory AppOrderExecutionContext.fromMap(Map<String, dynamic> map) {
    return AppOrderExecutionContext(
      batchId: map['batch_id']?.toString(),
      membershipId: map['membership_id']?.toString(),
      orderId: (map['order_id'] ?? map['case_id'] ?? '').toString(),
      caseId: (map['case_id'] ?? map['order_id'] ?? '').toString(),
      orderNo: (map['order_no'] ?? '').toString(),
      customerId: (map['customer_id'] ?? '').toString(),
      passportId: map['passport_id']?.toString(),
      fullName: (map['full_name'] ?? '').toString(),
      passportNumber: (map['passport_number'] ?? '').toString(),
      nationality: (map['nationality'] ?? '').toString(),
      dateOfBirth: map['date_of_birth']?.toString(),
      gender: map['gender']?.toString(),
      passportExpiryDate: map['passport_expiry_date']?.toString(),
      arrivalDate: map['arrival_date']?.toString(),
      departureDate: map['departure_date']?.toString(),
      businessStatus: (map['business_status'] ?? '').toString(),
      workflowStatus: (map['workflow_status'] ?? '').toString(),
      priority: (map['priority'] ?? 'NORMAL').toString(),
      latestPinRecordId: map['latest_pin_record_id']?.toString(),
      latestPinStatus: map['latest_pin_status']?.toString(),
      latestRegistrationCheckId: map['latest_registration_check_id']?.toString(),
      latestRegistrationStatus: map['latest_registration_status']?.toString(),
      latestVisitPassCheckId: map['latest_visit_pass_check_id']?.toString(),
      latestVisitPassStatus: map['latest_visit_pass_status']?.toString(),
    );
  }
}
