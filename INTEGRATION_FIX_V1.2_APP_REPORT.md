# Integration Fix V1.2 — App & Worker Implementation Report

**版本**：V1.2 Case-aware Execution  
**仓库**：`mm7768/passport-mdac-app`  
**执行角色**：Antigravity (Flutter App & Automation Workers)  
**日期**：2026-09-28  

---

## 1. 概述与核心变更

根据《Integration Fix V1.2 — Case-aware Execution Contract》，本轮改造在 V1.1 稳定 `Order ID / Case ID` 绑定的基础上，补齐了「**从 Website Batch → App 页面 → Enqueue 校验与 Payload → Worker Runtime Input → 历史证据清理**」整条链路中的 Case-aware 一致性防护，彻底消除旧批次借用新排单执行的竞态风险以及同客户多订单间的跨 Case 串号/证据覆盖问题。

---

## 2. Flutter App 端改造详情

### 2.1 Enqueue Payload 补充 `membership_id` 与 `operational_batch_id`
- **文件**：`lib/supabase_gateway.dart` & `lib/main.dart`
- **实现细节**：
  在 `DemoRepository.createBatchDrivenTaskAsync()` 及 `SupabaseGateway` 的 4 个任务创建 RPC（MDAC、Gmail PIN、Registration Check、Visit Pass Check）中，每个 item 的 payload 从原有的仅 `customer_id` + `case_id` 扩充为包含完整排单隶属元组：
  ```json
  {
    "customer_id": "uuid",
    "case_id": "uuid",
    "membership_id": "uuid",
    "operational_batch_id": "uuid",
    "customer_snapshot": { ... }
  }
  ```
  数据源直接取自当前选中订单的 `order.membershipId` 与 `order.batchId`，与后端 `private.assert_enqueue_membership()` 校验严格对齐，保证请求只能在指定的活跃批次和会员状态下生效。

### 2.2 Pre-enqueue 二次校验 Execution Context（Section 10）
- **文件**：`lib/main.dart` & `lib/features/batches/batches_screen.dart`
- **防御机制**：
  用户点击触发 Worker 任务前，App 首先逐一调用 `get_app_order_execution_context(order.orderId)` 获取后端最新的订单执行上下文快照，核对以下四重条件：
  ```dart
  if (ctx == null ||
      ctx.caseId != order.caseId ||
      ctx.membershipId != order.membershipId ||
      ctx.batchId != order.batchId) {
    return '订单已被重新排单或当前批次状态已变化，请刷新后重试。';
  }
  ```
  如果任意字段不匹配（例如旧 Batch A 页面中订单已被 Website Release 并移入 Batch B），App 立即阻断 enqueue 操作，清空已失效的勾选状态，刷新批次订单并弹出提示，杜绝陈旧页面的非法请求。

### 2.3 网络错误与批次 Closed 状态严格分离（Section 11）
- **文件**：`lib/features/batches/batches_screen.dart`
- **问题修复**：
  原逻辑在网络超时或获取订单失败时调用 `syncActiveBatchesFromSupabase()`，若因网络断开同样返回失败或未取到列表，容易误将 `_isBatchClosed` 设为 `true` 并清空本地订单。
- **全新实现**：
  1. 只有在权威同步活跃批次成功（返回成功结果且 `activeBatches` 中确实不存在当前 `batchId`）时，才认定为 `_isBatchClosed = true` 并清空列表。
  2. 若遇到网络异常、请求超时或网络同步报错，设置 `_error = '无法确认批次当前状态，请检查网络后刷新'`：
     - **严禁设置 `_isBatchClosed = true`**。
     - **严禁清空本地已加载的 `_orders`**，原数据保留仅供离线核对查看。
     - **全链路禁用 enqueue 动作与全选复选框**，渲染醒目的橙色网络警告横幅与“重试刷新”按钮。

### 2.4 App Lifecycle Resume 自动刷新（Section 12）
- **文件**：`lib/features/batches/batches_screen.dart`
- **实现方案**：
  `_ActiveBatchesScreenState` 与 `_BatchDetailScreenState` 混入 `WidgetsBindingObserver`，并在 `didChangeAppLifecycleState` 监听生命周期：
  ```dart
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
  ```
  当操作员将 App 从后台切回前台时，自动同步活跃批次列表并重载当前批次订单，无需手动点击刷新即可感知 Website 端的关批或换批操作。

---

## 3. Worker 端改造详情 (Visit Pass & Related Workers)

### 3.1 Visit Pass Check Worker — Case-aware 运行时输入（Section 5 & 6）
- **文件**：`services/visit-pass-check-worker/worker.py`
- **实现细节**：
  1. `get_runtime_input(item_id)` 优先通过 RPC `get_visit_pass_check_runtime_input` 获取运行时输入，且解析提取返回的 `entry_date` 和 `case_id`。
  2. 在本地 fallback 路径中，若当前 item 具备 `case_id`：
     - **PIN 获取**：严格按 `case_id = eq.{case_id}` 从 `email_pin_records` 获取最新 `RECEIVED` 状态的 PIN，**严禁回退至 `customer_id` 级别的最新 PIN**。
     - **Entry Date 获取**：新增 `get_case_entry_date(case_id)`，严格通过 `mdac_registrations.case_id = eq.{case_id}` 查询该订单成功的入境日期。
  3. 保留针对无 `case_id` 的旧 Legacy items 的 `customer_id` 兼容查询。

### 3.2 Visit Pass 历史证据清理严格限制在当前 Case（Section 8）
- **文件**：`services/visit-pass-check-worker/worker.py`
- **重构方法**：
  - 新增 `delete_case_old_visit_pass_evidence(self, case_id: str, current_screenshot_path: str | None = None)`。
  - 仅查询并清理 `visit_pass_checks.case_id = eq.{case_id}` 的历史截图文件与数据行。
  - **严禁删除同 `customer_id` 下其他 Case / Order 的截图证据**，确保多订单场景下每个 Case 的历史凭证独立保全。
  - 旧方法 `delete_customer_old_visit_pass_screenshots` 保留仅作为 Legacy 兼容。

### 3.3 Registration Check & Gmail PIN Workers
- **文件**：`services/registration-check-worker/worker.py` & `services/gmail-pin-worker/worker.py`
- 结构验证：
  - Registration Check Worker 直接通过 case-aware 的 `get_registration_check_runtime_input` 获取该 Case 绑定的 PIN。
  - Gmail PIN Worker 在认领与处理 item 时，将 `case_id` 贯穿传递至结构化日志与事件上报，与后端最新 case 驱动历史过滤保持一致。

---

## 4. 验证与测试结果

### 4.1 Flutter 测试套件（`test/batch_integration_test.dart`）
针对 V1.2 Section 15 新增 5 项专项测试，全部通过（16 / 16 passed）：
1. **Test 1: Payload 字段校验**：验证 `createBatchDrivenTaskAsync` 构造的数据包完整包含 `customer_id`、`case_id`、`membership_id`、`operational_batch_id`。
2. **Test 2: 竞态与跨批次阻断**：验证旧 Batch A 页面在后台 context 属于 Batch B 时被准确拦截，并提示“订单已被重新排单或当前批次状态已变化”。
3. **Test 3: 网络错误隔离**：验证网络错误时不会将批次标记为 CLOSED，不清除本地订单。
4. **Test 4: 权威关批识别**：验证在权威活跃列表响应且缺少目标 `batchId` 时，准确标记 CLOSED。
5. **Test 5: Resume 自动刷新**：验证 App Lifecycle resumed 状态下准确触发活跃批次与详情刷新。

### 4.2 Python Worker 测试套件
- `services/visit-pass-check-worker/test_worker.py`：新增 `test_get_case_entry_date_queries_by_case_id` 与 `test_delete_case_old_visit_pass_evidence_scoped_to_case_id`，共 18 / 18 测试全部通过。
- `services/registration-check-worker/test_worker.py`：11 / 11 测试全部通过。
- `services/mdac-fill-preview/test_worker.py`：11 / 11 测试全部通过。

### 4.3 静态代码分析
- 执行 `flutter analyze --no-fatal-infos`：**0 error, 0 fatal warning**。
