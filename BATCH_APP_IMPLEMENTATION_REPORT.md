# Batch-Driven Execution Workbench: App Implementation Report

本报告记录了依照 `01_Batch_Integration_Contract.md` 及 Codex 交付契约对 App 端的改造落地情况。
App 正式转变为 **Active Batch 驱动的集中执行工作台**。

---

## 1. 修改与新增的页面及组件

| 模块 / 文件 | 类型 | 改动说明 |
| :--- | :--- | :--- |
| `lib/features/batches/batch_models.dart` | 新增模型 | 定义了 `AppOperationalBatch`（活跃批次）、`AppBatchOrder`（批次内有效订单）、`AppOrderExecutionContext`（订单执行上下文）。 |
| `lib/features/batches/batches_screen.dart` | 新增界面 | 实现了 `ActiveBatchesScreen`（活跃批次卡片首屏）、`_ActiveBatchCard`（单个批次进度卡片）、`BatchDetailScreen`（批次详情与自动化执行台）、`_ExecutionContextDialog`（单单执行记录快照）。 |
| `lib/supabase_gateway.dart` | 网关扩展 | 新增 `fetchAppActiveBatches()`、`fetchAppBatchOrders(batchId)`、`fetchAppOrderExecutionContext(orderId)` 对应远端共享 RPC。 |
| `lib/main.dart` | 核心路由与状态改造 | 1. `DemoRepository` 增加活跃批次状态管理及相关 fetch 方法。<br>2. 首页首屏路由切换为 `ActiveBatchesScreen`，无 Active Batch 时展示友好空状态，严禁 fallback 全量客户。<br>3. 原客户列表迁移至二级导航“客户总库 (历史查询)”，不再作为默认工作执行入口。<br>4. 自动化任务创建与会话恢复时自动触发活跃批次同步。 |
| `test/batch_integration_test.dart` | 新增单元测试 | 针对契约数据解析、稳定 Order ID 映射规则、进度计算、空批次防崩溃及仓库逻辑进行完整测试（7 项用例全部通过）。 |

---

## 2. 使用的 API / RPC 接口契约

App 严格按照 Codex 预备好的 Supabase 共享后端接口进行调用，**未私自修改或重新设计任何共享数据库表结构、外键或 RPC**：

1. **`public.get_app_active_batches()`**:
   - **调用方式**: `SupabaseGateway.fetchAppActiveBatches()`
   - **返回字段**: `batch_id`, `batch_name`, `batch_no`, `status`, `created_at`, `total_count`, `completed_count`, `pending_count`
   - **用途**: 驱动首页 **Active Batch Cards** 渲染。只展示 `status = 'OPEN'` 的批次。
2. **`public.get_app_batch_orders(p_batch_id uuid)`**:
   - **调用方式**: `SupabaseGateway.fetchAppBatchOrders(batchId)`
   - **返回字段**: `membership_id`, `batch_id`, `order_id`, `case_id`, `order_no`, `customer_id`, `passport_id`, `display_name`, `passport_number`, `business_status`, `workflow_status`, `priority`, `membership_status`, `arrival_date`, `departure_date`
   - **用途**: 批次详情中呈现当前有效的 Membership Orders（由后端过滤已排除了 `released_at is not null` 的历史释放项）。
3. **`public.get_app_order_execution_context(p_order_id uuid)`**:
   - **调用方式**: `SupabaseGateway.fetchAppOrderExecutionContext(orderId)`
   - **返回字段**: 包含客户身份（全名、护照号、出生日期、国籍、性别等）、行程日期、最新 PIN 记录与状态、最新 Registration 检查记录与状态、最新 Visit Pass 检查记录与状态。
   - **用途**: 批次内点击单个订单“上下文”图标，弹出完整的执行记录快照。

---

## 3. Batch Card 数据来源与生命周期

- **卡片展示数据**:
  - 批次名称 (`batch_name`) 与编号 (`batch_no`)
  - 批次状态 (`status`：OPEN · 进行中)
  - 订单总数 (`total_count`)
  - 完成数量 (`completed_count` / Done) 与 待办数量 (`pending_count` / Pending)
  - 线性进度条 (`progressRatio = completedCount / totalCount`)
  - 创建时间 (`created_at`)
  - “打开批次”操作按钮
- **无 Active Batch 场景**:
  - 当 Website 未排单或没有 OPEN 批次时，App 首页呈现 Empty State 卡片（提示“暂无进行中的排单批次，管理后台当前没有处于 OPEN 状态的排单批次”）。
  - **严格限制**: 不 fallback 到全部客户/Case 列表。
- **Batch 关闭 / 失效场景**:
  - 若用户在打开批次详情后，Website 在管理后台 Close 了该批次或将未完成订单 Release，App 刷新后检测到批次关闭将展示显著告警横幅（`当前批次已在管理后台关闭或归档！不可继续执行自动化任务`），禁用 Worker 执行按钮，引导操作员返回活跃批次列表。

---

## 4. Order ID 使用规则

App 严格遵守契约的第一原则：
- **Order 是业务实体，Batch 是处理容器**:
  - `order_id` 与 `case_id` 始终绑定稳定的订单主键 UUID（即 `customer_cases.id`）。
  - `order_no` 保持为人类可读的稳定业务编号（例如 `AA0010`）。
- **重试与重新排单不新建 Order**:
  - 同一个 Order AA0010 无论经历 Batch A 失败释放，还是后续进入 Batch B，其 `order_id`、`case_id` 和 `order_no` 始终保持绝对一致。
  - App 界面严禁因为重新进入批次、打开批次或失败重试而生成新的 Order / Case。

---

## 5. Worker 与 Order 的绑定方式

- 在 `BatchDetailScreen` 中，操作员勾选订单后支持触发：
  1. **MDAC fill-preview 注册**: 自动带入所选订单在批次中的入境/出境日期，调用 `createTaskAsync(type: TaskType.mdacRegistration)`。
  2. **获取 Gmail PIN**: 调用 `createTaskAsync(type: TaskType.gmailPin)`。
  3. **核对 Registration 状态**: 调用 `createTaskAsync(type: TaskType.registrationCheck)`。
  4. **核对 Visit Pass 状态**: 调用 `createTaskAsync(type: TaskType.visitPassCheck)`。
- **绑定机制**:
  - Worker 执行提交至 `automation_batches` 和 `automation_items` 时，以该订单绑定的已有 `customer_id` 为核心载荷，不破坏 `customer_cases` 与 `operational_batch_items` 的映射关系。
  - 允许单个 Order 拥有多次执行尝试（Attempt 1 Failed -> Attempt 2 Success），而不创建新 Order。

---

## 6. 数据刷新机制 (Refresh Policy)

遵循 Contract V1 明确指定的显式与按需刷新机制：
1. **页面进入与会话初始化**: 用户打开 App、登录或恢复 Session 时，自动拉取活跃批次。
2. **Pull-to-Refresh**: 活跃批次工作台支持下拉或点击右上角刷新按钮拉取最新 OPEN 批次。
3. **批次详情按需刷新**: `BatchDetailScreen` 顶部提供即时刷新按钮。
4. **Worker 提交后回显刷新**: 每次向 Worker 派发任务成功后，App 会在本地立即重刷批次订单状态及活跃批次进度。

---

## 7. App 原有客户页面的调整

- 原 `CustomersScreen`（全量客户档案与 OCR 审核归档）不再作为 App 首页和工作执行入口。
- 在侧边栏导航（SideRail）及移动端底部导航（MobileNav）中，将其重命名为 **“客户总库 (历史)”**，作为次级入口保留，供操作员/管理员进行历史客户资料排查与 OCR 审核存档，保证业务底层模型与历史审计功能不受影响。

---

## 8. 尚未完成项与后端字段评估

- **当前契约满足度**:
  - Codex 预备的 3 个共享 RPC (`get_app_active_batches`, `get_app_batch_orders`, `get_app_order_execution_context`) 字段完整，完全覆盖了 App 端展示与执行工作台的所有需求。
  - **目前无需 Backend 补充额外字段**。
- **后续优化建议 (V2)**:
  - 待 Website 侧排单功能上线后，可考虑开启 Supabase Realtime 监听 `operational_batches` 表的 `UPDATE` 事件，实现批次完成或关闭时的实时无感通知。
