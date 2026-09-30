# APP ORDER INTAKE V1.3 交付报告

- **交付日期**: 2026-09-30
- **版本规范**: MDAC V1.2.1 / V1.3 Development Handoff (Gate 2)
- **对应提交分支**: `main`

---

## 1. 概述与核心变更

根据 `MDAC_V1.2.1_V1.3_Development_Handoff.md` 的规范，在 V1.3 Gate 2 阶段，Flutter 客户端全面废除了旧版 OCR 录入逻辑（原 `create_customer_with_case` 仅建空 Customer 而未建 Case/Passport，且需前置调用 `markOcrResultCreated`），改用后端原子 RPC 函数 `public.create_order_from_ocr(...)`。

### 核心达成目标
1. **原子进单**：一次 RPC 调用完成 Customer、Passport、Order（含 `order_no`，格式 `AAyymmddxxxx`）以及 Draft 标记状态更新。
2. **彻底废除 `markOcrResultCreated`**：由后端 RPC 在事务中内联执行状态标记，前端不再发起独立的标记请求。
3. **无订单不建客户（No Business Customer without Order）**：
   - 远程模式下移除/屏蔽纯手工“新建客户”入口，业务客户统一由 OCR 进单或订单入口生成；
   - 杜绝孤立 Customer（0 Case、0 Passport、0 Order）的产生。
4. **客户与护照复用（Customer Reuse）**：
   - 相同国家与护照号码再次录入时，后端自动复用既有 Customer 与 Passport，仅派生新的 Order；
   - 前端放开 OCR 确认时的本地重复护照拦截，允许客户复用。
5. **用户界面反馈**：
   - 进单成功后弹窗明确展示生成的订单号（例如 `AA2609300001`）及客户状态（新客户 / 已复用老客户）；
   - 移动端排版优化，修复批次列表空状态下的 136px 溢出问题。

---

## 2. 关键代码改造明细

### 2.1 SupabaseGateway 网关改造 (`lib/supabase_gateway.dart`)
- **新增 `createOrderFromOcr` 方法**：
  - 调用 RPC：`public.create_order_from_ocr`；
  - 参数包含：`p_ocr_result_id`, `p_full_name`, `p_passport_number`, `p_nationality`, `p_sex`, `p_birth_date`, `p_expiry_date`, `p_raw_payload`；
  - 严格校验后端返回结构：断言 `order_id`、`order_no`、`customer_id`、`passport_id` 必须非空且有效，否则抛出异常回滚状态；
  - 支持测试 Handler 注入：`testCreateOrderFromOcrHandler`，便于单元测试与集成测试模拟各种原子返回及异常场景；
  - 日期解析强化：`_toIsoDate` 支持 ISO 格式（`YYYY-MM-DD`）以及常用证件格式（`DD/MM/YYYY`）。

### 2.2 DemoRepository 录入工作流改造 (`lib/main.dart`)
- **改造 `confirmOcrWithSync`**：
  - 将旧版两阶段调用（`markOcrResultCreated` + `createCustomerWithCase`）替换为单一 `SupabaseGateway.createOrderFromOcr` 调用；
  - 成功后自动更新本地缓存并触发 `syncActiveBatchesFromSupabase` 与 `refreshCustomers`；
  - 保存 `lastConfirmedOrderSummary`，便于界面提示订单编号；
  - 调整 `_validateCustomerValues`：增加 `bool checkDuplicate = true` 参数，在 OCR 进单流程中传入 `checkDuplicate: false`，确保复用客户时不会被前端本地校验错误拦截。

### 2.3 业务约束与 UI 交互防护 (`lib/main.dart`, `lib/features/batches/batches_screen.dart`)
- **屏蔽远程无订单建客**：在 Supabase 远程直连模式下，隐藏手工单建客户按钮，提示通过进单创建，满足“无订单不建客户”的合规硬约束；
- **批次界面移动端适配**：在 `batches_screen.dart` 的 `_buildEmptyState` 中将固定宽度的 `Row` 替换为响应式 `Wrap`，修复 360px 宽度屏幕上的 136px 溢出问题。

---

## 3. 测试验证明细 (Tests A ~ E)

在 `test/app_order_intake_test.dart` 中实现了完整的 V1.3 Gate 2 自动化测试套件：

| 测试用例编号 | 测试目标与断言 | 结果 |
| :--- | :--- | :--- |
| **Test A: 首次 OCR 进单** | 调用 `create_order_from_ocr`，返回 `order_id`, `order_no`, `customer_id`, `passport_id`，customer_action 为 `created`，本地成功刷新 | **PASS** |
| **Test B: 同护照复用进单** | 相同护照号码再次进单，返回相同的 `customer_id` 与 `passport_id`，新的 `order_no`，customer_action 为 `reused` | **PASS** |
| **Test C: 后端失败原子回滚** | RPC 抛出错误时，前端不增加新客户与订单，准确向用户提示错误信息 | **PASS** |
| **Test D: 订单号展示与无孤立建客** | UI 显示 `lastConfirmedOrderSummary`（含订单号及新/老客户标签），远程模式下禁止独立手工创建客户 | **PASS** |
| **Test E: 废弃 markOcrResultCreated** | 确认在整个 OCR 确认进单流程中完全没有调用旧的 `markOcrResultCreated` 接口 | **PASS** |

### 测试执行结果

#### 1. Flutter 自动化测试
```
$ flutter test test/batch_integration_test.dart test/app_order_intake_test.dart
00:06 +22: All tests passed!
```
- `test/batch_integration_test.dart`: 17/17 全部通过（含 V1.2.1 Test D 批次断网保护）
- `test/app_order_intake_test.dart`: 5/5 全部通过（V1.3 Gate 2 Tests A~E）

#### 2. Python Worker 测试
- `services/visit-pass-check-worker/test_worker.py`: 20/20 全部通过（含 V1.2.1 Tests A, B, C）
- `services/registration-check-worker/test_worker.py`: 11/11 全部通过
- `services/mdac-fill-preview/test_worker.py`: 11/11 全部通过

---

## 4. 非目标说明 (Non-Goals)

根据 handoff 规范，本阶段（Gate 2）严格界定以下内容为非目标，保留至后续阶段：
1. **自动化 Worker 消费订单队列**：本阶段 Worker 仍按已绑定的 Task / Item 消费，不直接拉取 Order 级调度；
2. **Order 财务与支付结算状态**：进单仅生成初始状态订单，未接入支付流；
3. **离线 Mock 模式全面改造**：本地 Mock 模式保留基础单机体验，主要架构升级集中在真实 Supabase 生产路径。
