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

/// 自动化四阶段通用显示状态
enum AutomationDisplayState {
  none, // 未开始 / 暂无记录 (—)
  running, // 处理中 / 已入队 (Running)
  done, // 成功完成 (Done)
  notFound, // 未查到记录 (Not Found, 专用于 Visit Pass)
  review, // 需要关注 / 人工审核 (Review)
  failed, // 失败 (Failed)
}

/// 单个阶段的结构化展示结果
@immutable
class AutomationStageBadge {
  const AutomationStageBadge({
    required this.stage,
    required this.state,
    required this.text,
  });

  final String stage; // 'MDAC', 'PIN', 'REG', 'VP'
  final AutomationDisplayState state;
  final String text; // e.g. 'MDAC Done', 'VP Not Found', 'REG Review'
}

/// 业务归一化状态映射器 (解耦底层 enum，避免将原始 technical enum 直接暴露给业务用户)
class AutomationStatusMapper {
  static AutomationStageBadge mapMdac(String? status) {
    final s = status?.trim().toUpperCase();
    if (s == null || s.isEmpty) {
      return const AutomationStageBadge(
        stage: 'MDAC',
        state: AutomationDisplayState.none,
        text: 'MDAC —',
      );
    }
    if (s == 'SUCCEEDED') {
      return const AutomationStageBadge(
        stage: 'MDAC',
        state: AutomationDisplayState.done,
        text: 'MDAC Done',
      );
    }
    if (s == 'FAILED') {
      return const AutomationStageBadge(
        stage: 'MDAC',
        state: AutomationDisplayState.failed,
        text: 'MDAC Failed',
      );
    }
    if (s == 'NEEDS_REVIEW') {
      return const AutomationStageBadge(
        stage: 'MDAC',
        state: AutomationDisplayState.review,
        text: 'MDAC Review',
      );
    }
    if (s == 'QUEUED' || s == 'CLAIMED' || s == 'RUNNING' || s == 'SUBMITTED') {
      return const AutomationStageBadge(
        stage: 'MDAC',
        state: AutomationDisplayState.running,
        text: 'MDAC Running',
      );
    }
    return AutomationStageBadge(
      stage: 'MDAC',
      state: AutomationDisplayState.none,
      text: 'MDAC $status',
    );
  }

  static AutomationStageBadge mapPin(String? status) {
    final s = status?.trim().toUpperCase();
    if (s == null || s.isEmpty) {
      return const AutomationStageBadge(
        stage: 'PIN',
        state: AutomationDisplayState.none,
        text: 'PIN —',
      );
    }
    if (s == 'RECEIVED') {
      return const AutomationStageBadge(
        stage: 'PIN',
        state: AutomationDisplayState.done,
        text: 'PIN Done',
      );
    }
    if (s == 'FAILED') {
      return const AutomationStageBadge(
        stage: 'PIN',
        state: AutomationDisplayState.failed,
        text: 'PIN Failed',
      );
    }
    if (s == 'QUEUED' || s == 'CLAIMED' || s == 'RUNNING') {
      return const AutomationStageBadge(
        stage: 'PIN',
        state: AutomationDisplayState.running,
        text: 'PIN Running',
      );
    }
    return AutomationStageBadge(
      stage: 'PIN',
      state: AutomationDisplayState.none,
      text: 'PIN $status',
    );
  }

  static AutomationStageBadge mapRegistration({
    String? resultStatus,
    String? normalizedStatus,
  }) {
    final norm = normalizedStatus?.trim().toUpperCase();
    final res = resultStatus?.trim().toUpperCase();

    if ((norm == null || norm.isEmpty) && (res == null || res.isEmpty)) {
      return const AutomationStageBadge(
        stage: 'REG',
        state: AutomationDisplayState.none,
        text: 'REG —',
      );
    }
    // 优先依据业务归一化状态判断
    if (norm == 'FOUND') {
      return const AutomationStageBadge(
        stage: 'REG',
        state: AutomationDisplayState.done,
        text: 'REG Done',
      );
    }
    if (res == 'NEEDS_REVIEW' || norm == 'QUERY_TIMEOUT' || norm == 'REVIEW') {
      return const AutomationStageBadge(
        stage: 'REG',
        state: AutomationDisplayState.review,
        text: 'REG Review',
      );
    }
    if (res == 'FAILED' || res == 'PARSE_FAILED' || norm == 'FAILED') {
      return const AutomationStageBadge(
        stage: 'REG',
        state: AutomationDisplayState.failed,
        text: 'REG Failed',
      );
    }
    if (res == 'QUEUED' || res == 'CLAIMED' || res == 'RUNNING') {
      return const AutomationStageBadge(
        stage: 'REG',
        state: AutomationDisplayState.running,
        text: 'REG Running',
      );
    }
    // 兼容历史或 mock (若无 normalized_status 但有 CONFIRMED / VERIFIED)
    if (norm == null || norm.isEmpty) {
      if (res == 'CONFIRMED' || res == 'VERIFIED' || res == 'SUCCEEDED') {
        return const AutomationStageBadge(
          stage: 'REG',
          state: AutomationDisplayState.done,
          text: 'REG Done',
        );
      }
    }
    // 若 result_status 为 PARSED 但没有明确 FOUND，绝不向用户展示 'REG PARSED'
    if (res == 'PARSED') {
      return const AutomationStageBadge(
        stage: 'REG',
        state: AutomationDisplayState.review,
        text: 'REG Review',
      );
    }
    return AutomationStageBadge(
      stage: 'REG',
      state: AutomationDisplayState.none,
      text: 'REG ${norm ?? res}',
    );
  }

  static AutomationStageBadge mapVisitPass({
    String? resultStatus,
    String? normalizedStatus,
  }) {
    final norm = normalizedStatus?.trim().toUpperCase();
    final res = resultStatus?.trim().toUpperCase();

    if ((norm == null || norm.isEmpty) && (res == null || res.isEmpty)) {
      return const AutomationStageBadge(
        stage: 'VP',
        state: AutomationDisplayState.none,
        text: 'VP —',
      );
    }
    // 优先依据业务归一化状态判断
    if (norm == 'FOUND') {
      return const AutomationStageBadge(
        stage: 'VP',
        state: AutomationDisplayState.done,
        text: 'VP Done',
      );
    }
    if (norm == 'NO_RECORD') {
      return const AutomationStageBadge(
        stage: 'VP',
        state: AutomationDisplayState.notFound,
        text: 'VP Not Found',
      );
    }
    if (res == 'NEEDS_REVIEW' || norm == 'QUERY_TIMEOUT' || norm == 'REVIEW') {
      return const AutomationStageBadge(
        stage: 'VP',
        state: AutomationDisplayState.review,
        text: 'VP Review',
      );
    }
    if (res == 'FAILED' || res == 'PARSE_FAILED' || norm == 'FAILED') {
      return const AutomationStageBadge(
        stage: 'VP',
        state: AutomationDisplayState.failed,
        text: 'VP Failed',
      );
    }
    if (res == 'QUEUED' || res == 'CLAIMED' || res == 'RUNNING') {
      return const AutomationStageBadge(
        stage: 'VP',
        state: AutomationDisplayState.running,
        text: 'VP Running',
      );
    }
    // 兼容历史或 mock (若无 normalized_status 但有 CONFIRMED / VERIFIED)
    if (norm == null || norm.isEmpty) {
      if (res == 'CONFIRMED' || res == 'VERIFIED' || res == 'SUCCEEDED') {
        return const AutomationStageBadge(
          stage: 'VP',
          state: AutomationDisplayState.done,
          text: 'VP Done',
        );
      }
    }
    // 若 result_status 为 PARSED 但没有明确 FOUND 或 NO_RECORD，绝不向用户展示 'VP PARSED'
    if (res == 'PARSED') {
      return const AutomationStageBadge(
        stage: 'VP',
        state: AutomationDisplayState.review,
        text: 'VP Review',
      );
    }
    return AutomationStageBadge(
      stage: 'VP',
      state: AutomationDisplayState.none,
      text: 'VP ${norm ?? res}',
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
    this.latestMdacStatus,
    this.latestPinStatus,
    this.latestRegistrationStatus,
    this.latestVisitPassStatus,
    this.latestRegistrationResultStatus,
    this.latestRegistrationNormalizedStatus,
    this.latestVisitPassResultStatus,
    this.latestVisitPassNormalizedStatus,
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

  /// 四段式流程状态 (MDAC / PIN / Registration Check / Visit Pass Check)
  final String? latestMdacStatus;
  final String? latestPinStatus;
  final String? latestRegistrationStatus;
  final String? latestVisitPassStatus;

  /// 归一化与底层结果状态 (V1.3 规范)
  final String? latestRegistrationResultStatus;
  final String? latestRegistrationNormalizedStatus;
  final String? latestVisitPassResultStatus;
  final String? latestVisitPassNormalizedStatus;

  bool get isCompleted => membershipStatus.toUpperCase() == 'COMPLETED';
  bool get isActive => membershipStatus.toUpperCase() == 'ACTIVE';

  AutomationStageBadge get mdacBadge => AutomationStatusMapper.mapMdac(latestMdacStatus);
  AutomationStageBadge get pinBadge => AutomationStatusMapper.mapPin(latestPinStatus);
  AutomationStageBadge get registrationBadge => AutomationStatusMapper.mapRegistration(
        resultStatus: latestRegistrationResultStatus ?? latestRegistrationStatus,
        normalizedStatus: latestRegistrationNormalizedStatus,
      );
  AutomationStageBadge get visitPassBadge => AutomationStatusMapper.mapVisitPass(
        resultStatus: latestVisitPassResultStatus ?? latestVisitPassStatus,
        normalizedStatus: latestVisitPassNormalizedStatus,
      );

  AppBatchOrder copyWith({
    String? membershipId,
    String? batchId,
    String? orderId,
    String? caseId,
    String? orderNo,
    String? customerId,
    String? passportId,
    String? displayName,
    String? passportNumber,
    String? businessStatus,
    String? workflowStatus,
    String? priority,
    String? membershipStatus,
    String? arrivalDate,
    String? departureDate,
    String? latestMdacStatus,
    String? latestPinStatus,
    String? latestRegistrationStatus,
    String? latestVisitPassStatus,
    String? latestRegistrationResultStatus,
    String? latestRegistrationNormalizedStatus,
    String? latestVisitPassResultStatus,
    String? latestVisitPassNormalizedStatus,
  }) {
    return AppBatchOrder(
      membershipId: membershipId ?? this.membershipId,
      batchId: batchId ?? this.batchId,
      orderId: orderId ?? this.orderId,
      caseId: caseId ?? this.caseId,
      orderNo: orderNo ?? this.orderNo,
      customerId: customerId ?? this.customerId,
      passportId: passportId ?? this.passportId,
      displayName: displayName ?? this.displayName,
      passportNumber: passportNumber ?? this.passportNumber,
      businessStatus: businessStatus ?? this.businessStatus,
      workflowStatus: workflowStatus ?? this.workflowStatus,
      priority: priority ?? this.priority,
      membershipStatus: membershipStatus ?? this.membershipStatus,
      arrivalDate: arrivalDate ?? this.arrivalDate,
      departureDate: departureDate ?? this.departureDate,
      latestMdacStatus: latestMdacStatus ?? this.latestMdacStatus,
      latestPinStatus: latestPinStatus ?? this.latestPinStatus,
      latestRegistrationStatus: latestRegistrationStatus ?? this.latestRegistrationStatus,
      latestVisitPassStatus: latestVisitPassStatus ?? this.latestVisitPassStatus,
      latestRegistrationResultStatus:
          latestRegistrationResultStatus ?? this.latestRegistrationResultStatus,
      latestRegistrationNormalizedStatus:
          latestRegistrationNormalizedStatus ?? this.latestRegistrationNormalizedStatus,
      latestVisitPassResultStatus:
          latestVisitPassResultStatus ?? this.latestVisitPassResultStatus,
      latestVisitPassNormalizedStatus:
          latestVisitPassNormalizedStatus ?? this.latestVisitPassNormalizedStatus,
    );
  }

  factory AppBatchOrder.fromMap(Map<String, dynamic> map) {
    final rawArrival = map['arrival_date']?.toString();
    final rawDeparture = map['departure_date']?.toString();
    final regResult = map['latest_registration_result_status']?.toString();
    final regNorm = map['latest_registration_normalized_status']?.toString() ??
        map['normalized_status']?.toString();
    final vpResult = map['latest_visit_pass_result_status']?.toString();
    final vpNorm = map['latest_visit_pass_normalized_status']?.toString();

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
      latestMdacStatus: map['latest_mdac_status']?.toString(),
      latestPinStatus: map['latest_pin_status']?.toString(),
      latestRegistrationStatus: regNorm ?? map['latest_registration_status']?.toString() ?? regResult,
      latestVisitPassStatus: vpNorm ?? map['latest_visit_pass_status']?.toString() ?? vpResult,
      latestRegistrationResultStatus: regResult ?? map['latest_registration_status']?.toString(),
      latestRegistrationNormalizedStatus: regNorm,
      latestVisitPassResultStatus: vpResult ?? map['latest_visit_pass_status']?.toString(),
      latestVisitPassNormalizedStatus: vpNorm,
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
    this.latestMdacRegistrationId,
    this.latestMdacStatus,
    this.latestPinRecordId,
    this.latestPinStatus,
    this.latestRegistrationCheckId,
    this.latestRegistrationStatus,
    this.latestVisitPassCheckId,
    this.latestVisitPassStatus,
    this.latestRegistrationResultStatus,
    this.latestRegistrationNormalizedStatus,
    this.latestVisitPassResultStatus,
    this.latestVisitPassNormalizedStatus,
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
  final String? latestMdacRegistrationId;
  final String? latestMdacStatus;
  final String? latestPinRecordId;
  final String? latestPinStatus;
  final String? latestRegistrationCheckId;
  final String? latestRegistrationStatus;
  final String? latestVisitPassCheckId;
  final String? latestVisitPassStatus;

  /// 归一化与底层结果状态 (V1.3 规范)
  final String? latestRegistrationResultStatus;
  final String? latestRegistrationNormalizedStatus;
  final String? latestVisitPassResultStatus;
  final String? latestVisitPassNormalizedStatus;

  AutomationStageBadge get mdacBadge => AutomationStatusMapper.mapMdac(latestMdacStatus);
  AutomationStageBadge get pinBadge => AutomationStatusMapper.mapPin(latestPinStatus);
  AutomationStageBadge get registrationBadge => AutomationStatusMapper.mapRegistration(
        resultStatus: latestRegistrationResultStatus ?? latestRegistrationStatus,
        normalizedStatus: latestRegistrationNormalizedStatus,
      );
  AutomationStageBadge get visitPassBadge => AutomationStatusMapper.mapVisitPass(
        resultStatus: latestVisitPassResultStatus ?? latestVisitPassStatus,
        normalizedStatus: latestVisitPassNormalizedStatus,
      );

  factory AppOrderExecutionContext.fromMap(Map<String, dynamic> map) {
    final regResult = map['latest_registration_result_status']?.toString();
    final regNorm = map['latest_registration_normalized_status']?.toString() ??
        map['normalized_status']?.toString();
    final vpResult = map['latest_visit_pass_result_status']?.toString();
    final vpNorm = map['latest_visit_pass_normalized_status']?.toString();

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
      latestMdacRegistrationId: map['latest_mdac_registration_id']?.toString(),
      latestMdacStatus: map['latest_mdac_status']?.toString(),
      latestPinRecordId: map['latest_pin_record_id']?.toString(),
      latestPinStatus: map['latest_pin_status']?.toString(),
      latestRegistrationCheckId: map['latest_registration_check_id']?.toString(),
      latestRegistrationStatus: regNorm ?? map['latest_registration_status']?.toString() ?? regResult,
      latestVisitPassCheckId: map['latest_visit_pass_check_id']?.toString(),
      latestVisitPassStatus: vpNorm ?? map['latest_visit_pass_status']?.toString() ?? vpResult,
      latestRegistrationResultStatus: regResult ?? map['latest_registration_status']?.toString(),
      latestRegistrationNormalizedStatus: regNorm,
      latestVisitPassResultStatus: vpResult ?? map['latest_visit_pass_status']?.toString(),
      latestVisitPassNormalizedStatus: vpNorm,
    );
  }
}
