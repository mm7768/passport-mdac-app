import 'dart:math';

import 'package:flutter/material.dart';

/// A server preview is authoritative; current client counters only show the button.
class ManualRetryPreview {
  const ManualRetryPreview({
    required this.status,
    required this.taskType,
    required this.snapshotToken,
    required this.safeCount,
    required this.uncertainCount,
    required this.excludedSuccessCount,
    this.ineligibleCount = 0,
    this.blockedReason,
  });

  final String status;
  final String taskType;
  final String snapshotToken;
  final int safeCount;
  final int uncertainCount;
  final int excludedSuccessCount;
  final int ineligibleCount;
  final String? blockedReason;
  int get totalCount => safeCount + uncertainCount;
  bool get canRequest => status == 'READY' && totalCount > 0;

  factory ManualRetryPreview.fromJson(Map<String, dynamic> json) {
    final status = json['status'];
    final type = json['task_type'];
    final token = json['snapshot_token'];
    if (!const ['READY', 'BLOCKED', 'EMPTY'].contains(status) ||
        !const [
          'MDAC_REGISTRATION',
          'REGISTRATION_CHECK',
          'GMAIL_PIN',
          'VISIT_PASS_CHECK',
        ].contains(type) ||
        (status == 'READY' && (token is! String || token.isEmpty))) {
      throw const FormatException('服务器未返回有效的手动重试预览。');
    }
    final safe = _count(json, 'safe_count');
    final uncertain = _count(json, 'uncertain_count');
    if ((type != 'MDAC_REGISTRATION' && uncertain != 0) ||
        (status == 'READY' && safe + uncertain == 0)) {
      throw const FormatException('服务器返回的任务重试分类不一致。');
    }
    return ManualRetryPreview(
      status: status as String,
      taskType: type as String,
      snapshotToken: token is String ? token : '',
      safeCount: safe,
      uncertainCount: uncertain,
      excludedSuccessCount: _count(json, 'excluded_success_count'),
      ineligibleCount: json.containsKey('ineligible_count')
          ? _count(json, 'ineligible_count')
          : 0,
      blockedReason: json['blocked_reason']?.toString(),
    );
  }
}

int _count(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! int || value < 0) {
    throw FormatException('服务器未返回有效的重试数量：$key');
  }
  return value;
}

class ManualRetryResult {
  const ManualRetryResult({
    required this.requestId,
    required this.requeuedCount,
    required this.replayed,
  });

  final String requestId;
  final int requeuedCount;
  final bool replayed;

  factory ManualRetryResult.fromJson(Map<String, dynamic> json) {
    if (json['status'] != 'QUEUED' ||
        json['request_id'] is! String ||
        (json['request_id'] as String).isEmpty ||
        json['replayed'] is! bool) {
      throw const FormatException('重试响应未确认，请再次确认同一请求。');
    }
    return ManualRetryResult(
      requestId: json['request_id'] as String,
      requeuedCount: _count(json, 'requeued_count'),
      replayed: json['replayed'] as bool,
    );
  }
}

/// A known server rejection means its transaction did not change a task.
class ManualRetryRejected implements Exception {
  const ManualRetryRejected(this.message);
  final String message;
  @override
  String toString() => message;
}

class ManualRetryIntent {
  const ManualRetryIntent({
    required this.requestId,
    required this.preview,
    required this.includeUncertain,
  });
  final String requestId;
  final ManualRetryPreview preview;
  final bool includeUncertain;
}

typedef LoadManualRetryPreview = Future<ManualRetryPreview> Function();
typedef SendManualRetry = Future<ManualRetryResult> Function(
  ManualRetryIntent intent,
);

/// Holds one manual intent across widgets and ambiguous network responses.
/// Constructing/listening/building this controller never invokes the API.
class ManualRetryController extends ChangeNotifier {
  ManualRetryController({
    required LoadManualRetryPreview loadPreview,
    required SendManualRetry send,
    String Function()? newRequestId,
  }) : _loadPreview = loadPreview,
       _send = send,
       _newRequestId = newRequestId ?? _uuidV4;

  final LoadManualRetryPreview _loadPreview;
  final SendManualRetry _send;
  final String Function() _newRequestId;
  bool _busy = false;
  ManualRetryIntent? _pending;
  bool get busy => _busy;
  ManualRetryIntent? get pending => _pending;

  Future<ManualRetryPreview> previewAfterTap() async {
    if (_busy) throw const ManualRetryRejected('该批次正在处理，请稍候。');
    // A timeout may have happened after commit. Reconfirm exactly the old intent.
    if (_pending != null) return _pending!.preview;
    _busy = true;
    notifyListeners();
    try {
      return await _loadPreview();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<ManualRetryResult> confirmAfterTap(
    ManualRetryPreview preview, {
    required bool includeUncertain,
  }) async {
    if (_busy) throw const ManualRetryRejected('该批次正在处理，请稍候。');
    if (!preview.canRequest || (!includeUncertain && preview.safeCount == 0)) {
      throw const ManualRetryRejected('没有可按此选择重试的未成功项。');
    }
    final previous = _pending;
    if (previous != null &&
        (previous.preview.snapshotToken != preview.snapshotToken ||
            previous.includeUncertain != includeUncertain)) {
      throw const ManualRetryRejected('请先确认上一次重试请求，不能另建请求。');
    }
    final intent =
        previous ??
        ManualRetryIntent(
          requestId: _newRequestId(),
          preview: preview,
          includeUncertain: includeUncertain,
        );
    _pending = intent;
    _busy = true;
    notifyListeners();
    try {
      final result = await _send(intent);
      if (result.requestId != intent.requestId || result.requeuedCount <= 0) {
        throw const FormatException('重试响应未确认，请再次确认同一请求。');
      }
      _pending = null;
      return result;
    } on ManualRetryRejected {
      _pending = null;
      rethrow;
    } finally {
      // Transport failures and malformed responses deliberately retain _pending.
      _busy = false;
      notifyListeners();
    }
  }
}

String _uuidV4() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((n) => n.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

class ManualTaskRetryButton extends StatefulWidget {
  const ManualTaskRetryButton({
    required this.controller,
    required this.unfinishedCount,
    required this.onConfirmed,
    super.key,
  });

  final ManualRetryController controller;
  final int unfinishedCount;
  final Future<void> Function() onConfirmed;

  @override
  State<ManualTaskRetryButton> createState() => _ManualTaskRetryButtonState();
}

class _ManualTaskRetryButtonState extends State<ManualTaskRetryButton> {
  bool _opening = false;

  void _message(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _open() async {
    if (_opening || widget.controller.busy) return;
    setState(() => _opening = true);
    try {
      final preview = await widget.controller.previewAfterTap();
      if (!mounted) return;
      if (!preview.canRequest) {
        _message(
          preview.status == 'EMPTY'
              ? preview.ineligibleCount > 0
                    ? '未成功项已达重试上限或不符合重试条件，成功项不会重试。'
                    : '没有未成功项；成功任务不会重试。'
              : '当前暂不能重试：${manualRetryBlockedMessage(preview.blockedReason)}',
        );
        return;
      }
      final pending = widget.controller.pending;
      final choice = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _ManualRetryDialog(preview: preview, pending: pending),
      );
      if (choice == null) return;
      final result = await widget.controller.confirmAfterTap(
        preview,
        includeUncertain: choice,
      );
      _message(
        '已${result.replayed ? '确认原请求' : '手动重新排队'} '
        '${result.requeuedCount} 项；成功项未重试。',
      );
      try {
        await widget.onConfirmed();
      } catch (_) {
        _message('重试已确认，列表刷新失败，请手动刷新。');
      }
    } on ManualRetryRejected catch (error) {
      _message(error.message);
    } catch (_) {
      _message(
        widget.controller.pending != null
            ? '重试请求尚未确认；请点“确认上次重试请求”，不会另建任务。'
            : '无法获取重试预览，请稍后重试。',
      );
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (_, _) {
      final busy = _opening || widget.controller.busy;
      final pending = widget.controller.pending != null;
      return FilledButton.tonalIcon(
        onPressed: busy ? null : _open,
        icon: const Icon(Icons.refresh_rounded, size: 14),
        label: Text(
          busy
              ? '正在处理重试请求…'
              : pending
              ? '确认上次重试请求'
              : '重试未成功项 (${widget.unfinishedCount})',
        ),
      );
    },
  );
}

String manualRetryBlockedMessage(String? reason) => switch (reason) {
  'LIVE_LEASE' ||
  'ACTIVE_LEASE' ||
  'BATCH_ACTIVE' ||
  'ACTIVE_WORK' ||
  'BATCH_RUNNING' ||
  'ITEM_ACTIVE' ||
  'ACTIVE_TASK' => '任务正在执行或租约尚未结束，请稍后再试。',
  'ATTEMPT_LIMIT' || 'MAX_ATTEMPTS' || 'ATTEMPT_LIMIT_REACHED' => '已达到重试次数上限。',
  'OTHER_ACTIVE_TASK' ||
  'CUSTOMER_ACTIVE' ||
  'CUSTOMER_CONFLICT' => '客户还有其他执行中的任务，请待其完成。',
  'NOT_OWNER' || 'FORBIDDEN' || 'INACTIVE_USER' => '当前账号没有重试该批次的权限。',
  'NO_RETRYABLE_ITEMS' || 'NO_UNFINISHED_ITEMS' || 'EMPTY' => '没有可重试的未成功项。',
  'STALE_SNAPSHOT' || 'SNAPSHOT_CHANGED' => '任务状态已变化，请刷新后重新选择。',
  _ => '任务状态暂不允许重试，请刷新后再试。',
};

class _ManualRetryDialog extends StatefulWidget {
  const _ManualRetryDialog({required this.preview, required this.pending});
  final ManualRetryPreview preview;
  final ManualRetryIntent? pending;
  @override
  State<_ManualRetryDialog> createState() => _ManualRetryDialogState();
}

class _ManualRetryDialogState extends State<_ManualRetryDialog> {
  bool _acknowledged = false;

  @override
  Widget build(BuildContext context) {
    final preview = widget.preview;
    final pending = widget.pending;
    return AlertDialog(
      title: Text(pending == null ? '手动重试未成功项' : '确认上次重试请求'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('已成功 ${preview.excludedSuccessCount} 项将保留，不会重新执行。'),
            if (pending != null)
              const Text('上次响应未确认，将使用同一请求编号确认结果，不另建请求。')
            else
              Text('可安全重试 ${preview.safeCount} 项。'),
            if (preview.taskType != 'MDAC_REGISTRATION')
              const Text('本次仅重新查询或读取 PIN，不会再次提交 MDAC 注册。'),
            if (preview.ineligibleCount > 0)
              Text('另有 ${preview.ineligibleCount} 项已达重试上限或不符合条件，不在此次重试范围。'),
            if (preview.uncertainCount > 0) ...[
              Text('${preview.uncertainCount} 项可能已经提交注册；再次执行可能重复注册。'),
              if (pending == null)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _acknowledged,
                  onChanged: (value) =>
                      setState(() => _acknowledged = value == true),
                  title: const Text('我理解重复注册风险，仍手动重试这些项'),
                ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        if (pending != null)
          FilledButton(
            onPressed: () => Navigator.pop(context, pending.includeUncertain),
            child: const Text('确认同一请求'),
          )
        else ...[
          if (preview.safeCount > 0)
            FilledButton.tonal(
              onPressed: () => Navigator.pop(context, false),
              child: Text(
                preview.uncertainCount > 0
                    ? '仅重试安全项 (${preview.safeCount})'
                    : '确认重试 (${preview.safeCount})',
              ),
            ),
          if (preview.uncertainCount > 0)
            FilledButton(
              onPressed: _acknowledged
                  ? () => Navigator.pop(context, true)
                  : null,
              child: Text('仍重试全部 (${preview.totalCount})'),
            ),
        ],
      ],
    );
  }
}
