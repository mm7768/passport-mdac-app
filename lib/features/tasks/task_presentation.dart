import 'package:flutter/material.dart';

import 'task_models.dart';

String taskTypeLabel(TaskType type) {
  switch (type) {
    case TaskType.mdacRegistration:
      return 'MDAC 批量注册';
    case TaskType.gmailPin:
      return 'Gmail PIN 获取';
    case TaskType.registrationCheck:
      return 'Check Registration';
    case TaskType.visitPassCheck:
      return 'Check Visit Pass';
  }
}

IconData taskTypeIcon(TaskType type) {
  switch (type) {
    case TaskType.mdacRegistration:
      return Icons.flight_takeoff_rounded;
    case TaskType.gmailPin:
      return Icons.mark_email_read_outlined;
    case TaskType.registrationCheck:
      return Icons.manage_search_rounded;
    case TaskType.visitPassCheck:
      return Icons.badge_outlined;
  }
}

Color taskTypeColor(TaskType type) {
  switch (type) {
    case TaskType.mdacRegistration:
      return const Color(0xFFF3A25E);
    case TaskType.gmailPin:
      return const Color(0xFF6B78D6);
    case TaskType.registrationCheck:
      return const Color(0xFF138A8A);
    case TaskType.visitPassCheck:
      return const Color(0xFF6D8EAC);
  }
}

String taskStatusLabel(TaskStatus status) {
  switch (status) {
    case TaskStatus.queued:
      return '排队中';
    case TaskStatus.running:
      return '执行中';
    case TaskStatus.succeeded:
      return '已完成';
    case TaskStatus.partialSuccess:
      return '部分成功';
    case TaskStatus.failed:
      return '失败';
    case TaskStatus.needsReview:
      return '待确认';
  }
}

Color taskStatusColor(TaskStatus status) {
  switch (status) {
    case TaskStatus.queued:
      return const Color(0xFF5D85AD);
    case TaskStatus.running:
      return const Color(0xFFF3A25E);
    case TaskStatus.succeeded:
      return const Color(0xFF138A8A);
    case TaskStatus.partialSuccess:
      return const Color(0xFFE3A228);
    case TaskStatus.failed:
      return const Color(0xFFD9635D);
    case TaskStatus.needsReview:
      return const Color(0xFF7B67AF);
  }
}
