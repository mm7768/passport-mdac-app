import 'package:flutter/material.dart';

import '../../main.dart';
import 'customer_task_launch.dart';

class CustomerTaskLaunchSelection {
  const CustomerTaskLaunchSelection({
    required this.orders,
    this.entryDate,
    this.exitDate,
  });

  final List<CustomerTaskOrderChoice> orders;
  final DateTime? entryDate;
  final DateTime? exitDate;
}

/// Picking customers never starts work. The explicit confirmation returns Cases.
class CustomerTaskLaunchDialog extends StatefulWidget {
  const CustomerTaskLaunchDialog({
    required this.type,
    required this.customers,
    required this.orderChoices,
    super.key,
  });

  final TaskType type;
  final List<Customer> customers;
  final List<CustomerTaskOrderChoice> orderChoices;

  @override
  State<CustomerTaskLaunchDialog> createState() =>
      _CustomerTaskLaunchDialogState();
}

class _CustomerTaskLaunchDialogState extends State<CustomerTaskLaunchDialog> {
  final Map<String, CustomerTaskOrderChoice> _selected = {};
  DateTime? _entryDate;
  DateTime? _exitDate;

  List<CustomerTaskOrderChoice> _choices(String customerId) => widget
      .orderChoices
      .where((order) => order.customerId == customerId && order.isCurrent)
      .toList(growable: false);

  @override
  void initState() {
    super.initState();
    for (final customer in widget.customers) {
      final choices = _choices(customer.id);
      if (choices.length == 1) _selected[customer.id] = choices.single;
    }
    if (_selected.length == widget.customers.length && _selected.isNotEmpty) {
      final entryDates = _selected.values.map((o) => o.arrivalDate).toSet();
      final exitDates = _selected.values.map((o) => o.departureDate).toSet();
      if (entryDates.length == 1)
        _entryDate = DateTime.tryParse(entryDates.single ?? '');
      if (exitDates.length == 1)
        _exitDate = DateTime.tryParse(exitDates.single ?? '');
    }
  }

  bool get _datesValid =>
      widget.type != TaskType.mdacRegistration ||
      (_entryDate != null &&
          _exitDate != null &&
          !_exitDate!.isBefore(_entryDate!));

  @override
  Widget build(BuildContext context) {
    final missing = widget.customers
        .where((c) => _choices(c.id).isEmpty)
        .length;
    final selectedAll = _selected.length == widget.customers.length;
    return AlertDialog(
      title: Text('发起${taskTypeLabel(widget.type)}'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('已选 ${widget.customers.length} 位客户，请确认本次办理的订单。'),
              const SizedBox(height: 8),
              const Text('每位客户使用所选订单；不会自动创建或猜测新订单。'),
              if (missing > 0) ...[
                const SizedBox(height: 8),
                Text(
                  '$missing 位客户尚无可执行订单，请先完成护照审核建档。',
                  style: const TextStyle(color: AppTheme.danger),
                ),
              ],
              const SizedBox(height: 12),
              for (final customer in widget.customers) ...[
                Text(
                  customer.fullName,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                if (_choices(customer.id).isEmpty)
                  const Text(
                    '没有可执行订单',
                    style: TextStyle(color: AppTheme.danger),
                  )
                else if (_choices(customer.id).length == 1)
                  Text('订单：${_choices(customer.id).single.orderNo}')
                else
                  DropdownButtonFormField<String>(
                    key: ValueKey('task-case-${customer.id}'),
                    initialValue: _selected[customer.id]?.caseId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '选择本次订单'),
                    items: _choices(customer.id)
                        .map(
                          (order) => DropdownMenuItem(
                            value: order.caseId,
                            child: Text(
                              '${order.orderNo} · ${order.arrivalDate ?? '未设日期'}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: (id) => setState(() {
                      if (id == null) return;
                      _selected[customer.id] = _choices(customer.id)
                          .singleWhere((o) => o.caseId == id);
                    }),
                  ),
                const Divider(height: 20),
              ],
              if (widget.type == TaskType.mdacRegistration) ...[
                DateField(
                  label: '入境日期',
                  value: _entryDate,
                  onTap: () async {
                    final date = await pickDate(context, _entryDate);
                    if (date != null && mounted)
                      setState(() => _entryDate = date);
                  },
                ),
                const SizedBox(height: 10),
                DateField(
                  label: '出境日期',
                  value: _exitDate,
                  onTap: () async {
                    final date = await pickDate(
                      context,
                      _exitDate ?? _entryDate,
                    );
                    if (date != null && mounted)
                      setState(() => _exitDate = date);
                  },
                ),
                if (_entryDate != null && _exitDate != null && !_datesValid)
                  const Text(
                    '出境日期不能早于入境日期。',
                    style: TextStyle(color: AppTheme.danger),
                  ),
              ],
              const SizedBox(height: 12),
              Text(
                widget.type == TaskType.mdacRegistration
                    ? '确认后将为这些订单排队 MDAC 注册，由办公室 Worker 执行。'
                    : '确认后将为这些订单排队${taskTypeLabel(widget.type)}，不会重新提交 MDAC 注册。',
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: missing > 0 || !selectedAll || !_datesValid
              ? null
              : () {
                  Navigator.pop(
                    context,
                    CustomerTaskLaunchSelection(
                      orders: widget.customers
                          .map((c) => _selected[c.id]!)
                          .toList(growable: false),
                      entryDate: _entryDate,
                      exitDate: _exitDate,
                    ),
                  );
                },
          icon: const Icon(Icons.rocket_launch_rounded, size: 16),
          label: Text('确认发起 (${widget.customers.length})'),
        ),
      ],
    );
  }
}
