import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../main.dart';
import 'batch_models.dart';

/// 活跃排单批次工作台 (App 核心首页)
class ActiveBatchesScreen extends StatefulWidget {
  const ActiveBatchesScreen({
    required this.repository,
    required this.userName,
    required this.role,
    required this.onNavigate,
    super.key,
  });

  final DemoRepository repository;
  final String userName;
  final UserRole role;
  final ValueChanged<AppSection> onNavigate;

  @override
  State<ActiveBatchesScreen> createState() => _ActiveBatchesScreenState();
}

class _ActiveBatchesScreenState extends State<ActiveBatchesScreen>
    with WidgetsBindingObserver {
  AppOperationalBatch? _selectedBatch;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.repository.syncActiveBatchesFromSupabase();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      widget.repository.syncActiveBatchesFromSupabase();
    }
  }

  void _openBatch(AppOperationalBatch batch) {
    setState(() {
      _selectedBatch = batch;
    });
  }

  void _closeBatchDetail() {
    setState(() {
      _selectedBatch = null;
    });
    widget.repository.syncActiveBatchesFromSupabase();
  }

  @override
  Widget build(BuildContext context) {
    if (_selectedBatch != null) {
      return BatchDetailScreen(
        batch: _selectedBatch!,
        repository: widget.repository,
        actor: widget.userName,
        role: widget.role,
        onBack: _closeBatchDetail,
      );
    }

    final repo = widget.repository;
    final batches = repo.activeBatches;
    final isLoading = repo.activeBatchesLoading;
    final error = repo.activeBatchesError;

    return AppPage(
      eyebrow: 'BATCH EXECUTION WORKSPACE · 批次工作台',
      title: '活跃排单批次',
      subtitle: '管理后台决定排单范围，App 负责集中执行与状态回传。',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '刷新活跃批次',
            icon: isLoading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
            onPressed: isLoading
                ? null
                : () => widget.repository.syncActiveBatchesFromSupabase(),
          ),
          const SizedBox(width: 8),
          WorkerStatus(repository: widget.repository),
        ],
      ),
      child: RefreshIndicator(
        onRefresh: () => widget.repository.syncActiveBatchesFromSupabase(),
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(28, 0, 28, 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (error != null) ...[
                _buildErrorBanner(context, error),
                const SizedBox(height: 20),
              ],
              if (isLoading && batches.isEmpty)
                _buildLoadingState()
              else if (batches.isEmpty)
                _buildEmptyState(context)
              else
                _buildBatchesGrid(context, batches),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildErrorBanner(BuildContext context, String error) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFECEB),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFF09893)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, color: Color(0xFFC7362E)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '加载活跃批次失败：$error',
              style: const TextStyle(
                color: Color(0xFF7A1C16),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton.icon(
            icon: const Icon(Icons.replay_rounded, size: 16),
            label: const Text('重试'),
            onPressed: () => widget.repository.syncActiveBatchesFromSupabase(),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingState() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: 80),
        child: Column(
          children: [
            CircularProgressIndicator(strokeWidth: 2.5),
            SizedBox(height: 16),
            Text(
              '正在获取进行中的排单批次...',
              style: TextStyle(color: AppTheme.muted, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 580),
        margin: const EdgeInsets.symmetric(vertical: 40),
        padding: const EdgeInsets.all(36),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppTheme.line),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: AppTheme.mint.withValues(alpha: 0.3),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.all_inbox_rounded,
                color: AppTheme.teal,
                size: 32,
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              '暂无进行中的排单批次',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: AppTheme.ink,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              '管理后台（Website）当前没有 OPEN 状态的排单批次。\n'
              '本工作台严格按排单批次驱动，不显示无批次待处理订单。\n'
              '当管理后台完成排单并开启批次后，批次卡片将在此实时呈现。',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppTheme.muted,
                fontSize: 14,
                height: 1.55,
              ),
            ),
            const SizedBox(height: 26),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 14,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('刷新批次'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.teal,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 14,
                    ),
                  ),
                  onPressed: () =>
                      widget.repository.syncActiveBatchesFromSupabase(),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.history_rounded, size: 18),
                  label: const Text('客户总库 / 历史查询'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 14,
                    ),
                  ),
                  onPressed: () => widget.onNavigate(AppSection.customers),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBatchesGrid(
    BuildContext context,
    List<AppOperationalBatch> batches,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cardWidth = constraints.maxWidth < 720
            ? constraints.maxWidth
            : (constraints.maxWidth - 20) / 2;

        return Wrap(
          spacing: 20,
          runSpacing: 20,
          children: batches.map((batch) {
            return SizedBox(
              width: cardWidth,
              child: _ActiveBatchCard(
                batch: batch,
                onOpen: () => _openBatch(batch),
              ),
            );
          }).toList(),
        );
      },
    );
  }
}

/// 活跃批次卡片组件 (严格符合 03_Antigravity_App_Task.md 第 3 节规范)
class _ActiveBatchCard extends StatelessWidget {
  const _ActiveBatchCard({
    required this.batch,
    required this.onOpen,
  });

  final AppOperationalBatch batch;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final progress = batch.progressRatio;
    final isDone = batch.totalCount > 0 && batch.completedCount == batch.totalCount;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: isDone
              ? const Color(0xFF35B778).withValues(alpha: 0.4)
              : AppTheme.line,
          width: isDone ? 1.5 : 1.0,
        ),
      ),
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          batch.batchName,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: AppTheme.ink,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (batch.batchNo.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: AppTheme.canvas,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: AppTheme.line),
                            ),
                            child: Text(
                              batch.batchNo,
                              style: const TextStyle(
                                fontSize: 11,
                                fontFamily: 'monospace',
                                color: AppTheme.muted,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: batch.isOpen
                          ? const Color(0xFFE8F6EF)
                          : const Color(0xFFEFEFEF),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: batch.isOpen
                            ? const Color(0xFF35B778).withValues(alpha: 0.4)
                            : const Color(0xFFCCCCCC),
                      ),
                    ),
                    child: Text(
                      batch.isOpen ? 'OPEN · 进行中' : batch.status,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: batch.isOpen
                            ? const Color(0xFF1E7E4E)
                            : Colors.black54,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${batch.totalCount} 订单 (Orders)',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.ink,
                    ),
                  ),
                  Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: Color(0xFF35B778),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        'Done ${batch.completedCount}',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF1E7E4E),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: Color(0xFFE08A28),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        'Pending ${batch.pendingCount}',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFFB36712),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 8,
                  backgroundColor: const Color(0xFFF0F0F0),
                  valueColor: AlwaysStoppedAnimation<Color>(
                    isDone ? const Color(0xFF35B778) : AppTheme.teal,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              const Divider(height: 1),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '创建于 ${_formatDate(batch.createdAt)}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTheme.muted,
                    ),
                  ),
                  FilledButton.icon(
                    icon: const Icon(Icons.arrow_forward_rounded, size: 16),
                    label: const Text('打开批次'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.teal,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onPressed: onOpen,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}

/// 批次详情页面 (展示有效 Membership Orders 及执行工作台)
class BatchDetailScreen extends StatefulWidget {
  const BatchDetailScreen({
    required this.batch,
    required this.repository,
    required this.actor,
    required this.role,
    required this.onBack,
    super.key,
  });

  final AppOperationalBatch batch;
  final DemoRepository repository;
  final String actor;
  final UserRole role;
  final VoidCallback onBack;

  @override
  State<BatchDetailScreen> createState() => _BatchDetailScreenState();
}

class _BatchDetailScreenState extends State<BatchDetailScreen>
    with WidgetsBindingObserver {
  List<AppBatchOrder> _orders = [];
  bool _isLoading = true;
  String? _error;
  bool _isBatchClosed = false;

  final Set<String> _selectedOrderIds = {};
  String _searchQuery = '';
  String _statusFilter = 'ALL'; // ALL, ACTIVE, COMPLETED, ACTION_REQUIRED

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadBatchOrders();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      widget.repository.syncActiveBatchesFromSupabase().then((_) {
        if (mounted) {
          _loadBatchOrders();
        }
      });
    }
  }

  Future<void> _loadBatchOrders() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final orders =
          await widget.repository.fetchBatchOrders(widget.batch.batchId);
      if (!mounted) return;

      if (orders.isNotEmpty) {
        setState(() {
          _orders = orders;
          _isLoading = false;
          _isBatchClosed = false;
          _error = null;
        });
      } else {
        // Backend 合约：Closed Batch 的 get_app_batch_orders() 返回空列表，不一定抛异常
        // 因此返回空列表时，权威刷新 get_app_active_batches() 判定是否仍 OPEN
        final syncErr = await widget.repository.syncActiveBatchesFromSupabase();
        if (!mounted) return;

        if (syncErr != null) {
          // 网络同步失败，无法确认批次权威状态：严禁判定为 CLOSED，不清空 orders，禁止 enqueue
          setState(() {
            _isLoading = false;
            _error = '无法确认批次当前状态，请检查网络后刷新';
          });
          return;
        }

        final isStillActive = widget.repository.activeBatches.any(
          (b) => b.batchId == widget.batch.batchId,
        );

        if (!isStillActive) {
          // 仅在权威收到成功 response 且 batchId 不在活跃列表时，判定已被 Closed
          setState(() {
            _orders = [];
            _selectedOrderIds.clear();
            _isBatchClosed = true;
            _error = null;
            _isLoading = false;
          });
        } else {
          // 批次仍在 active 列表中，只是此时有效订单为 0
          setState(() {
            _orders = [];
            _isBatchClosed = false;
            _error = null;
            _isLoading = false;
          });
        }
      }
    } catch (e) {
      if (!mounted) return;
      // 网络请求异常/超时：
      // 必须严格遵守 V1.2 Section 11:
      // - 不设置 _isBatchClosed = true
      // - 不清空本地 Orders（保留原页面数据仅供查看）
      // - 显示：无法确认批次当前状态，请检查网络后刷新
      setState(() {
        _isLoading = false;
        _error = '无法确认批次当前状态，请检查网络后刷新';
      });
    }
  }

  List<AppBatchOrder> get _filteredOrders {
    var result = _orders;

    if (_searchQuery.trim().isNotEmpty) {
      final q = _searchQuery.trim().toLowerCase();
      result = result.where((o) {
        return o.displayName.toLowerCase().contains(q) ||
            o.passportNumber.toLowerCase().contains(q) ||
            o.orderNo.toLowerCase().contains(q) ||
            o.orderId.toLowerCase().contains(q);
      }).toList();
    }

    if (_statusFilter == 'ACTIVE') {
      result = result.where((o) => o.isActive).toList();
    } else if (_statusFilter == 'COMPLETED') {
      result = result.where((o) => o.isCompleted).toList();
    } else if (_statusFilter == 'ACTION_REQUIRED') {
      result = result.where((o) => o.businessStatus == 'ACTION_REQUIRED').toList();
    }

    return result;
  }

  void _toggleSelectAll() {
    setState(() {
      if (_selectedOrderIds.length == _filteredOrders.length) {
        _selectedOrderIds.clear();
      } else {
        _selectedOrderIds
          ..clear()
          ..addAll(_filteredOrders.map((o) => o.orderId));
      }
    });
  }

  void _selectOnlyActive() {
    setState(() {
      _selectedOrderIds
        ..clear()
        ..addAll(_filteredOrders.where((o) => o.isActive).map((o) => o.orderId));
    });
  }

  void _toggleOrderSelection(String orderId) {
    setState(() {
      if (_selectedOrderIds.contains(orderId)) {
        _selectedOrderIds.remove(orderId);
      } else {
        _selectedOrderIds.add(orderId);
      }
    });
  }

  Future<void> _showExecutionContextDialog(AppBatchOrder order) async {
    showDialog(
      context: context,
      builder: (ctx) => _ExecutionContextDialog(
        order: order,
        repository: widget.repository,
      ),
    );
  }

  Future<void> _startMdacRegistration() async {
    if (_selectedOrderIds.isEmpty) return;
    if (_isBatchClosed) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('批次已关闭，不可触发 Worker 执行。')),
      );
      return;
    }
    if (_error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('无法确认批次当前状态，请检查网络后刷新'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final selectedOrders =
        _orders.where((o) => _selectedOrderIds.contains(o.orderId)).toList();

    DateTime? defaultEntry;
    DateTime? defaultExit;
    for (final o in selectedOrders) {
      if (o.arrivalDate != null) {
        defaultEntry ??= DateTime.tryParse(o.arrivalDate!);
      }
      if (o.departureDate != null) {
        defaultExit ??= DateTime.tryParse(o.departureDate!);
      }
    }
    defaultEntry ??= DateTime.now().add(const Duration(days: 3));
    defaultExit ??= defaultEntry.add(const Duration(days: 7));

    DateTime entry = defaultEntry;
    DateTime exit = defaultExit;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          title: Text('启动 MDAC 注册 (${selectedOrders.length} 单)'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '选中的订单将以既有稳定 Case ID / Customer ID 提交至自动化队列，不创建新订单。',
                style: TextStyle(fontSize: 13, color: AppTheme.muted),
              ),
              const SizedBox(height: 16),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.flight_land_rounded),
                title: const Text('入境日期 (Entry Date)'),
                subtitle: Text(
                  '${entry.year}-${entry.month.toString().padLeft(2, '0')}-${entry.day.toString().padLeft(2, '0')}',
                ),
                trailing: TextButton(
                  child: const Text('更改'),
                  onPressed: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: entry,
                      firstDate: DateTime.now(),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                    );
                    if (picked != null) {
                      setDlgState(() {
                        entry = picked;
                        if (exit.isBefore(entry)) {
                          exit = entry.add(const Duration(days: 3));
                        }
                      });
                    }
                  },
                ),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.flight_takeoff_rounded),
                title: const Text('出境日期 (Exit Date)'),
                subtitle: Text(
                  '${exit.year}-${exit.month.toString().padLeft(2, '0')}-${exit.day.toString().padLeft(2, '0')}',
                ),
                trailing: TextButton(
                  child: const Text('更改'),
                  onPressed: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: exit,
                      firstDate: entry,
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                    );
                    if (picked != null) {
                      setDlgState(() => exit = picked);
                    }
                  },
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppTheme.teal),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确认启动'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true || !mounted) return;

    // 执行前二次确认当前批次有效性 (Pre-enqueue Revalidation)
    await _loadBatchOrders();
    if (!mounted) return;
    if (_isBatchClosed) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('批次已被管理后台关闭或归档，无法继续执行！'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    if (_error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('无法确认批次当前状态，请检查网络后刷新'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final err = await widget.repository.createBatchDrivenTaskAsync(
      type: TaskType.mdacRegistration,
      batchId: widget.batch.batchId,
      orders: selectedOrders,
      actor: widget.actor,
      entryDate: entry,
      exitDate: exit,
    );

    if (!mounted) return;
    if (err != null) {
      if (err.contains('重新排单') ||
          err.contains('状态已变化') ||
          err.contains('不再属于当前批次')) {
        _selectedOrderIds.clear();
        await _loadBatchOrders();
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(err), backgroundColor: Colors.red),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已为 ${selectedOrders.length} 单创建 MDAC 任务并推送 Worker'),
          backgroundColor: AppTheme.teal,
        ),
      );
      _selectedOrderIds.clear();
      await _loadBatchOrders();
      await widget.repository.syncActiveBatchesFromSupabase();
    }
  }

  Future<void> _startQueryTask(TaskType type) async {
    if (_selectedOrderIds.isEmpty) return;
    if (_isBatchClosed) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('批次已关闭，不可触发 Worker 执行。')),
      );
      return;
    }
    if (_error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('无法确认批次当前状态，请检查网络后刷新'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    // 执行前二次确认当前批次有效性 (Pre-enqueue Revalidation)
    await _loadBatchOrders();
    if (!mounted) return;
    if (_isBatchClosed) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('批次已被管理后台关闭或归档，无法继续执行！'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    if (_error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('无法确认批次当前状态，请检查网络后刷新'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final selectedOrders =
        _orders.where((o) => _selectedOrderIds.contains(o.orderId)).toList();

    final err = await widget.repository.createBatchDrivenTaskAsync(
      type: type,
      batchId: widget.batch.batchId,
      orders: selectedOrders,
      actor: widget.actor,
    );

    if (!mounted) return;
    if (err != null) {
      if (err.contains('重新排单') ||
          err.contains('状态已变化') ||
          err.contains('不再属于当前批次')) {
        _selectedOrderIds.clear();
        await _loadBatchOrders();
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(err), backgroundColor: Colors.red),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已为 ${selectedOrders.length} 单加入 ${taskTypeLabel(type)} 队列'),
          backgroundColor: AppTheme.teal,
        ),
      );
      _selectedOrderIds.clear();
      await _loadBatchOrders();
      await widget.repository.syncActiveBatchesFromSupabase();
    }
  }

  @override
  Widget build(BuildContext context) {
    final batch = widget.batch;
    final filtered = _filteredOrders;

    return AppPage(
      eyebrow: 'BATCH DETAIL · 批次工作区',
      title: batch.batchName,
      subtitle: '批次编号: ${batch.batchNo.isNotEmpty ? batch.batchNo : batch.batchId}',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          OutlinedButton.icon(
            icon: const Icon(Icons.arrow_back_rounded, size: 18),
            label: const Text('返回批次列表'),
            onPressed: widget.onBack,
          ),
          const SizedBox(width: 10),
          IconButton(
            tooltip: '刷新本批次订单',
            icon: _isLoading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
            onPressed: _isLoading ? null : _loadBatchOrders,
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isCompact = constraints.maxWidth < 640;
          return Column(
            children: [
              if (_isBatchClosed)
                Container(
                  margin: EdgeInsets.fromLTRB(isCompact ? 16 : 28, 0, isCompact ? 16 : 28, 16),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFECEB),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFF09893)),
                  ),
                  child: isCompact
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.warning_amber_rounded, color: Color(0xFFC7362E)),
                                const SizedBox(width: 8),
                                const Expanded(
                                  child: Text(
                                    '当前批次已在管理后台关闭或归档！',
                                    style: TextStyle(
                                      color: Color(0xFF7A1C16),
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              '不可继续执行自动化任务。已 Release 的订单已回到后台 Master List。',
                              style: TextStyle(color: Color(0xFF7A1C16), fontSize: 12),
                            ),
                            const SizedBox(height: 10),
                            FilledButton(
                              onPressed: widget.onBack,
                              style: FilledButton.styleFrom(backgroundColor: const Color(0xFFC7362E)),
                              child: const Text('退出详情'),
                            ),
                          ],
                        )
                      : Row(
                          children: [
                            const Icon(Icons.warning_amber_rounded, color: Color(0xFFC7362E)),
                            const SizedBox(width: 12),
                            const Expanded(
                              child: Text(
                                '当前批次已在管理后台（Website）关闭或归档！不可继续执行自动化任务。已 Release 的订单已回到后台 Master List。',
                                style: TextStyle(
                                  color: Color(0xFF7A1C16),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            FilledButton(
                              onPressed: widget.onBack,
                              style: FilledButton.styleFrom(backgroundColor: const Color(0xFFC7362E)),
                              child: const Text('退出详情'),
                            ),
                          ],
                        ),
                ),
              if (_error != null && !_isBatchClosed)
                Container(
                  margin: EdgeInsets.fromLTRB(isCompact ? 16 : 28, 0, isCompact ? 16 : 28, 16),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF7ED),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFFDBA74)),
                  ),
                  child: isCompact
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.wifi_off_rounded, color: Color(0xFFC2410C)),
                                const SizedBox(width: 8),
                                const Expanded(
                                  child: Text(
                                    '无法确认批次当前状态，请检查网络后刷新',
                                    style: TextStyle(
                                      color: Color(0xFF9A3412),
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              '已暂停自动化任务执行，原数据仅供离线查看。',
                              style: TextStyle(color: Color(0xFF9A3412), fontSize: 12),
                            ),
                            const SizedBox(height: 10),
                            OutlinedButton.icon(
                              onPressed: _loadBatchOrders,
                              icon: const Icon(Icons.refresh, size: 16),
                              label: const Text('重试刷新'),
                            ),
                          ],
                        )
                      : Row(
                          children: [
                            const Icon(Icons.wifi_off_rounded, color: Color(0xFFC2410C)),
                            const SizedBox(width: 12),
                            const Expanded(
                              child: Text(
                                '无法确认批次当前状态，请检查网络后刷新。已暂停自动化任务执行，原数据仅供离线查看。',
                                style: TextStyle(
                                  color: Color(0xFF9A3412),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            OutlinedButton.icon(
                              onPressed: _loadBatchOrders,
                              icon: const Icon(Icons.refresh, size: 16),
                              label: const Text('重试刷新'),
                            ),
                          ],
                        ),
                ),
              // 统计指标与过滤栏
              Padding(
                padding: EdgeInsets.symmetric(horizontal: isCompact ? 16 : 28),
                child: isCompact
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TextField(
                            decoration: InputDecoration(
                              hintText: '搜索客户姓名、护照号、订单编号...',
                              prefixIcon: const Icon(Icons.search_rounded),
                              filled: true,
                              fillColor: Colors.white,
                              contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: const BorderSide(color: AppTheme.line),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: const BorderSide(color: AppTheme.line),
                              ),
                            ),
                            onChanged: (val) => setState(() => _searchQuery = val),
                          ),
                          const SizedBox(height: 10),
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: SegmentedButton<String>(
                              segments: const [
                                ButtonSegment(value: 'ALL', label: Text('全部')),
                                ButtonSegment(value: 'ACTIVE', label: Text('进行中')),
                                ButtonSegment(value: 'COMPLETED', label: Text('已完成')),
                                ButtonSegment(value: 'ACTION_REQUIRED', label: Text('需关注')),
                              ],
                              selected: {_statusFilter},
                              onSelectionChanged: (val) =>
                                  setState(() => _statusFilter = val.first),
                            ),
                          ),
                        ],
                      )
                    : Row(
                        children: [
                          Expanded(
                            child: TextField(
                              decoration: InputDecoration(
                                hintText: '搜索客户姓名、护照号、订单编号...',
                                prefixIcon: const Icon(Icons.search_rounded),
                                filled: true,
                                fillColor: Colors.white,
                                contentPadding: const EdgeInsets.symmetric(vertical: 12),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: const BorderSide(color: AppTheme.line),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: const BorderSide(color: AppTheme.line),
                                ),
                              ),
                              onChanged: (val) => setState(() => _searchQuery = val),
                            ),
                          ),
                          const SizedBox(width: 14),
                          SegmentedButton<String>(
                            segments: const [
                              ButtonSegment(value: 'ALL', label: Text('全部')),
                              ButtonSegment(value: 'ACTIVE', label: Text('进行中')),
                              ButtonSegment(value: 'COMPLETED', label: Text('已完成')),
                              ButtonSegment(value: 'ACTION_REQUIRED', label: Text('需关注')),
                            ],
                            selected: {_statusFilter},
                            onSelectionChanged: (val) =>
                                setState(() => _statusFilter = val.first),
                          ),
                        ],
                      ),
              ),
              const SizedBox(height: 14),
              // 订单列表主体
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : _orders.isEmpty && _error != null && !_isBatchClosed
                        ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Text(
                                  '无法确认批次当前状态，请检查网络后刷新',
                                  style: TextStyle(color: Color(0xFF9A3412)),
                                ),
                                const SizedBox(height: 12),
                                ElevatedButton(
                                  onPressed: _loadBatchOrders,
                                  child: const Text('重新加载'),
                                ),
                              ],
                            ),
                          )
                        : filtered.isEmpty
                            ? Center(
                                child: Text(
                                  _searchQuery.isNotEmpty
                                      ? '没有匹配的订单'
                                      : '本批次当前无有效订单记录（或已全部 Release）',
                                  style: const TextStyle(color: AppTheme.muted),
                                ),
                              )
                            : ListView.separated(
                                padding: EdgeInsets.fromLTRB(
                                  isCompact ? 16 : 28,
                                  0,
                                  isCompact ? 16 : 28,
                                  isCompact ? 130 : 90,
                                ),
                                itemCount: filtered.length,
                                separatorBuilder: (ctx, i) => const SizedBox(height: 10),
                                itemBuilder: (ctx, idx) {
                                  final order = filtered[idx];
                                  final isSelected =
                                      _selectedOrderIds.contains(order.orderId);
                                  return _BatchOrderRow(
                                    order: order,
                                    isSelected: isSelected,
                                    onSelectChanged: (_isBatchClosed || _error != null)
                                        ? null
                                        : (val) => _toggleOrderSelection(order.orderId),
                                    onOpenContext: () =>
                                        _showExecutionContextDialog(order),
                                  );
                                },
                              ),
              ),
              // 底部操作栏 (悬浮浮层)
              if (!_isBatchClosed)
                _buildBottomActionBar(context, isCompact: isCompact),
            ],
          );
        },
      ),
    );
  }

  Widget _buildBottomActionBar(BuildContext context, {required bool isCompact}) {
    final count = _selectedOrderIds.length;
    final isBlocked = _isBatchClosed || _error != null;
    final isNarrow = isCompact || MediaQuery.of(context).size.width < 1050;

    if (isNarrow) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: AppTheme.line)),
          boxShadow: [
            BoxShadow(
              color: Color(0x0F000000),
              blurRadius: 10,
              offset: Offset(0, -3),
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Checkbox(
                    value: _selectedOrderIds.isNotEmpty &&
                        _selectedOrderIds.length == _filteredOrders.length,
                    tristate: _selectedOrderIds.isNotEmpty &&
                        _selectedOrderIds.length < _filteredOrders.length,
                    onChanged: isBlocked ? null : (val) => _toggleSelectAll(),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    count > 0 ? '已选 $count 单' : '全选待办',
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                  ),
                  if (count > 0) ...[
                    const SizedBox(width: 8),
                    TextButton(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: isBlocked ? null : _selectOnlyActive,
                      child: const Text('仅未完成', style: TextStyle(fontSize: 12)),
                    ),
                    TextButton(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: () => setState(() => _selectedOrderIds.clear()),
                      child: const Text('取消全选', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    FilledButton.icon(
                      icon: const Icon(Icons.flight_takeoff_rounded, size: 16),
                      label: const Text('启动 MDAC 注册'),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.teal,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: (count == 0 || isBlocked) ? null : _startMdacRegistration,
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.pin_rounded, size: 16),
                      label: const Text('获取 PIN'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed:
                          (count == 0 || isBlocked) ? null : () => _startQueryTask(TaskType.gmailPin),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.assignment_turned_in_rounded, size: 16),
                      label: const Text('核对 Registration'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: (count == 0 || isBlocked)
                          ? null
                          : () => _startQueryTask(TaskType.registrationCheck),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.fact_check_rounded, size: 16),
                      label: const Text('核对 Visit Pass'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: (count == 0 || isBlocked)
                          ? null
                          : () => _startQueryTask(TaskType.visitPassCheck),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: AppTheme.line)),
        boxShadow: [
          BoxShadow(
            color: Color(0x0F000000),
            blurRadius: 10,
            offset: Offset(0, -3),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              Checkbox(
                value: _selectedOrderIds.isNotEmpty &&
                    _selectedOrderIds.length == _filteredOrders.length,
                tristate: _selectedOrderIds.isNotEmpty &&
                    _selectedOrderIds.length < _filteredOrders.length,
                onChanged: isBlocked ? null : (val) => _toggleSelectAll(),
              ),
              Text(
                count > 0 ? '已选 $count 单' : '全选待办',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              if (count > 0) ...[
                const SizedBox(width: 8),
                TextButton(
                  onPressed: isBlocked ? null : _selectOnlyActive,
                  child: const Text('仅选中未完成项'),
                ),
                TextButton(
                  onPressed: () => setState(() => _selectedOrderIds.clear()),
                  child: const Text('取消全选'),
                ),
              ],
              const SizedBox(width: 24),
              FilledButton.icon(
                icon: const Icon(Icons.flight_takeoff_rounded, size: 18),
                label: const Text('启动 MDAC 注册'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.teal,
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                ),
                onPressed: (count == 0 || isBlocked) ? null : _startMdacRegistration,
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                icon: const Icon(Icons.pin_rounded, size: 18),
                label: const Text('获取 PIN'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
                onPressed:
                    (count == 0 || isBlocked) ? null : () => _startQueryTask(TaskType.gmailPin),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                icon: const Icon(Icons.assignment_turned_in_rounded, size: 18),
                label: const Text('核对 Registration'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
                onPressed: (count == 0 || isBlocked)
                    ? null
                    : () => _startQueryTask(TaskType.registrationCheck),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                icon: const Icon(Icons.fact_check_rounded, size: 18),
                label: const Text('核对 Visit Pass'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
                onPressed: (count == 0 || isBlocked)
                    ? null
                    : () => _startQueryTask(TaskType.visitPassCheck),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 批次内单笔订单卡片
class _BatchOrderRow extends StatelessWidget {
  const _BatchOrderRow({
    required this.order,
    required this.isSelected,
    required this.onSelectChanged,
    required this.onOpenContext,
  });

  final AppBatchOrder order;
  final bool isSelected;
  final ValueChanged<bool?>? onSelectChanged;
  final VoidCallback onOpenContext;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: isSelected ? const Color(0xFFF0F7F6) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isSelected ? AppTheme.teal : AppTheme.line,
          width: isSelected ? 1.5 : 1.0,
        ),
      ),
      padding: const EdgeInsets.all(14),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isCompact = constraints.maxWidth < 600;
          if (isCompact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Top row: Checkbox, OrderNo, Priority, Spacer, Info button
                Row(
                  children: [
                    Checkbox(
                      value: isSelected,
                      onChanged: onSelectChanged,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                    const SizedBox(width: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.teal.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        order.orderNo,
                        style: const TextStyle(
                          color: AppTheme.teal,
                          fontWeight: FontWeight.w800,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    if (order.priority.toUpperCase() == 'URGENT') ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFECEB),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          '加急',
                          style: TextStyle(
                            color: Color(0xFFC7362E),
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                    const Spacer(),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      tooltip: '查看订单执行上下文 (PIN/核对结果)',
                      icon: const Icon(Icons.info_outline_rounded, color: AppTheme.teal, size: 20),
                      onPressed: onOpenContext,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // Middle row: Customer name & Status Chips
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        order.displayName,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                          color: AppTheme.ink,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    _buildStatusChip(order.businessStatus),
                    const SizedBox(width: 4),
                    _buildMembershipChip(order.membershipStatus),
                  ],
                ),
                const SizedBox(height: 6),
                // Third row: Passport & Dates
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '护照: ${order.passportNumber}',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: AppTheme.muted,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        order.arrivalDate != null
                            ? '抵达: ${order.arrivalDate}${order.departureDate != null ? ' · 离开: ${order.departureDate}' : ''}'
                            : '无行程日期',
                        style: const TextStyle(fontSize: 12, color: AppTheme.muted),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 7),
                // Fourth row: Automation Progress (MDAC / PIN / REG / VP)
                _buildAutomationStepsRow(order),
                const SizedBox(height: 6),
                // Fifth row: Order ID
                Tooltip(
                  message: '稳定 Order / Case ID: ${order.orderId}',
                  child: Text(
                    'ID: ${order.orderId.length > 8 ? order.orderId.substring(0, 8) : order.orderId}...',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: AppTheme.muted,
                    ),
                  ),
                ),
              ],
            );
          }

          // Desktop multi-column row
          return Row(
            children: [
              Checkbox(
                value: isSelected,
                onChanged: onSelectChanged,
              ),
              const SizedBox(width: 8),
              // 订单编号 & 稳定 Case ID 标识
              Expanded(
                flex: 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: AppTheme.teal.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            order.orderNo,
                            style: const TextStyle(
                              color: AppTheme.teal,
                              fontWeight: FontWeight.w800,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        if (order.priority.toUpperCase() == 'URGENT') ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFECEB),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              '加急',
                              style: TextStyle(
                                color: Color(0xFFC7362E),
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Tooltip(
                      message: '稳定 Order / Case ID: ${order.orderId}',
                      child: Text(
                        'ID: ${order.orderId.length > 8 ? order.orderId.substring(0, 8) : order.orderId}...',
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          color: AppTheme.muted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // 客户全名 & 证件号
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      order.displayName,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: AppTheme.ink,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '护照: ${order.passportNumber}',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: AppTheme.muted,
                      ),
                    ),
                  ],
                ),
              ),
              // 行程日期
              Expanded(
                flex: 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      order.arrivalDate != null
                          ? '抵达: ${order.arrivalDate}'
                          : '无行程日期',
                      style: const TextStyle(fontSize: 12, color: AppTheme.ink),
                    ),
                    if (order.departureDate != null)
                      Text(
                        '离开: ${order.departureDate}',
                        style: const TextStyle(fontSize: 11, color: AppTheme.muted),
                      ),
                  ],
                ),
              ),
              // 状态标签与自动化进度
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        _buildStatusChip(order.businessStatus),
                        _buildMembershipChip(order.membershipStatus),
                      ],
                    ),
                    const SizedBox(height: 6),
                    _buildAutomationStepsRow(order),
                  ],
                ),
              ),
              // 操作按钮: 查看执行上下文
              IconButton(
                tooltip: '查看订单执行上下文 (PIN/核对结果)',
                icon: const Icon(Icons.info_outline_rounded, color: AppTheme.teal),
                onPressed: onOpenContext,
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildAutomationStepsRow(AppBatchOrder order) {
    return Wrap(
      spacing: 5,
      runSpacing: 4,
      children: [
        _buildAutomationBadge('MDAC', order.latestMdacStatus),
        _buildAutomationBadge('PIN', order.latestPinStatus),
        _buildAutomationBadge('REG', order.latestRegistrationStatus),
        _buildAutomationBadge('VP', order.latestVisitPassStatus),
      ],
    );
  }

  Widget _buildAutomationBadge(String label, String? status) {
    String text;
    Color bg;
    Color fg;

    final s = status?.trim().toUpperCase();
    if (s == null || s.isEmpty) {
      text = '$label —';
      bg = const Color(0xFFF2F4F7);
      fg = const Color(0xFF98A2B3);
    } else if (s == 'SUCCEEDED' || s == 'CONFIRMED' || s == 'VERIFIED' || s == 'RECEIVED') {
      text = '$label Done';
      bg = const Color(0xFFE8F6EF);
      fg = const Color(0xFF1E7E4E);
    } else if (s == 'FAILED' || s == 'PARSE_FAILED' || s == 'INVALID') {
      text = '$label Failed';
      bg = const Color(0xFFFFECEB);
      fg = const Color(0xFFC7362E);
    } else if (s == 'SUBMITTED' || s == 'RUNNING' || s == 'QUEUED') {
      text = '$label Running';
      bg = const Color(0xFFEBF3FB);
      fg = const Color(0xFF155EEF);
    } else if (s == 'NEEDS_REVIEW' || s == 'RESULT_UNKNOWN' || s == 'NOT_FOUND') {
      text = '$label Review';
      bg = const Color(0xFFFEF6EE);
      fg = const Color(0xFFB36712);
    } else {
      text = '$label $status';
      bg = const Color(0xFFF2F4F7);
      fg = const Color(0xFF475467);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: fg,
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _buildStatusChip(String status) {
    Color bg = const Color(0xFFF2F4F7);
    Color fg = const Color(0xFF475467);

    switch (status.toUpperCase()) {
      case 'COMPLETED':
      case 'SUBMITTED':
        bg = const Color(0xFFE8F6EF);
        fg = const Color(0xFF1E7E4E);
        break;
      case 'PENDING':
      case 'CURRENT':
        bg = const Color(0xFFFEF6EE);
        fg = const Color(0xFFB36712);
        break;
      case 'ACTION_REQUIRED':
      case 'FAILED':
        bg = const Color(0xFFFFECEB);
        fg = const Color(0xFFC7362E);
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        status,
        style: TextStyle(
          color: fg,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _buildMembershipChip(String status) {
    final isDone = status.toUpperCase() == 'COMPLETED';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: isDone ? const Color(0xFFE8F6EF) : const Color(0xFFEBF3FB),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        isDone ? 'DONE' : 'ACTIVE',
        style: TextStyle(
          color: isDone ? const Color(0xFF1E7E4E) : const Color(0xFF1D6DB2),
          fontSize: 10,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

/// 执行上下文详情弹窗 (对应 get_app_order_execution_context)
class _ExecutionContextDialog extends StatefulWidget {
  const _ExecutionContextDialog({
    required this.order,
    required this.repository,
  });

  final AppBatchOrder order;
  final DemoRepository repository;

  @override
  State<_ExecutionContextDialog> createState() =>
      _ExecutionContextDialogState();
}

class _ExecutionContextDialogState extends State<_ExecutionContextDialog> {
  AppOrderExecutionContext? _context;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await widget.repository.fetchOrderExecutionContext(widget.order.orderId);
      if (mounted) {
        setState(() {
          _context = res;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.order;
    return AlertDialog(
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: AppTheme.teal.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              o.orderNo,
              style: const TextStyle(
                color: AppTheme.teal,
                fontWeight: FontWeight.w800,
                fontSize: 14,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${o.displayName} 执行上下文',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 540,
        child: _loading
            ? const Center(
                heightFactor: 3,
                child: CircularProgressIndicator(),
              )
            : _error != null
                ? Text('获取上下文失败: $_error', style: const TextStyle(color: Colors.red))
                : _context == null
                    ? const Text('未找到该订单的上下文信息。')
                    : _buildContent(_context!),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _buildContent(AppOrderExecutionContext ctx) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildInfoRow('稳定 Order ID', ctx.orderId, isMono: true, copyable: true),
          _buildInfoRow('Case ID', ctx.caseId, isMono: true),
          _buildInfoRow('Customer ID', ctx.customerId, isMono: true),
          const Divider(height: 24),
          const Text(
            '客户身份与证件快照',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
          ),
          const SizedBox(height: 8),
          _buildInfoRow('姓名 (Full Name)', ctx.fullName),
          _buildInfoRow('护照号码', ctx.passportNumber, isMono: true),
          _buildInfoRow('国籍 (Nationality)', ctx.nationality),
          _buildInfoRow('出生日期 (DOB)', ctx.dateOfBirth ?? '未填'),
          _buildInfoRow('性别 (Gender)', ctx.gender ?? '未填'),
          _buildInfoRow('护照到期日', ctx.passportExpiryDate ?? '未填'),
          const Divider(height: 24),
          const Text(
            '自动化执行最新记录 (Latest Worker Attempts)',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
          ),
          const SizedBox(height: 8),
          _buildInfoRow(
            'MDAC 注册状态',
            ctx.latestMdacStatus ?? '未注册 / 无记录',
            badgeColor: ctx.latestMdacStatus == 'SUCCEEDED'
                ? const Color(0xFFE8F6EF)
                : ctx.latestMdacStatus == 'FAILED'
                    ? const Color(0xFFFFECEB)
                    : null,
          ),
          if (ctx.latestMdacRegistrationId != null)
            _buildInfoRow('MDAC 注册记录 ID', ctx.latestMdacRegistrationId!, isMono: true, copyable: true),
          _buildInfoRow(
            '最新 PIN 状态',
            ctx.latestPinStatus ?? '无 PIN 记录',
            badgeColor: ctx.latestPinStatus != null ? const Color(0xFFE8F6EF) : null,
          ),
          _buildInfoRow(
            'Registration Check 结果',
            ctx.latestRegistrationStatus ?? '尚未核对',
            badgeColor: ctx.latestRegistrationStatus == 'CONFIRMED'
                ? const Color(0xFFE8F6EF)
                : null,
          ),
          _buildInfoRow(
            'Visit Pass Check 结果',
            ctx.latestVisitPassStatus ?? '尚未核对',
            badgeColor: ctx.latestVisitPassStatus == 'CONFIRMED'
                ? const Color(0xFFE8F6EF)
                : null,
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(
    String label,
    String value, {
    bool isMono = false,
    bool copyable = false,
    Color? badgeColor,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 170,
            child: Text(
              label,
              style: const TextStyle(
                color: AppTheme.muted,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Container(
                    padding: badgeColor != null
                        ? const EdgeInsets.symmetric(horizontal: 6, vertical: 2)
                        : EdgeInsets.zero,
                    decoration: badgeColor != null
                        ? BoxDecoration(
                            color: badgeColor,
                            borderRadius: BorderRadius.circular(4),
                          )
                        : null,
                    child: Text(
                      value,
                      style: TextStyle(
                        fontFamily: isMono ? 'monospace' : null,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.ink,
                      ),
                    ),
                  ),
                ),
                if (copyable) ...[
                  const SizedBox(width: 6),
                  InkWell(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: value));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('已复制到剪贴板'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    },
                    child: const Icon(Icons.copy_rounded, size: 14, color: AppTheme.teal),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
