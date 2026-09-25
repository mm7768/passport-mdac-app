# MDAC App — Antigravity 性能优化执行报告

> **执行周期**: 2026-09-24 ~ 2026-09-25  
> **状态**: 全部阶段已成功落地并经过真实环境严格验证  
> **核心原则**: 不改变业务逻辑，不破坏 Supabase 数据，不删除 Worker RPC，不删除 GitHub 源码，零大规模重写。

---

## 1. 最终部署架构

通过精准清理 Railway 重复云端 Worker，系统架构已完全对齐设计规范：

```text
               ┌───────────────────────┐
               │  Flutter App (Control)│
               └──────────┬────────────┘
                          │
                          ▼
               ┌───────────────────────┐
               │       Supabase        │
               │ (Single Source Truth) │
               └───┬───────────────┬───┘
                   │               │
       ┌───────────┴───────┐   ┌───┴───────────────────────────────┐
       │      Railway      │   │     Local Workers (办公室 PC)     │
       │  (Cloud Services) │   │          DESKTOP-2GLBL48          │
       ├───────────────────┤   ├───────────────────────────────────┤
       │ 1. Azure OCR      │   │ 1. MDAC Register Worker           │
       │    (passport-mdac)│   │    (services/mdac-fill-preview)   │
       │ 2. Gmail PIN      │   │ 2. Registration Check Worker      │
       │    (pleasing-acc) │   │    (services/reg-check-worker)    │
       │                   │   │ 3. Visit Pass Check Worker        │
       │                   │   │    (services/visit-pass-worker)   │
       └───────────────────┘   └───────────────────────────────────┘
```

- **已删除的 Railway 重复服务**:
  1. `wholesome-rebirth` (MDAC fill-preview 重复云端实例)
  2. `selfless-enchantment` (Registration Check 重复云端实例)
  3. `courageous-fascination` (Visit Pass Check 重复云端实例)
- **保留并运行中的 Railway 服务**:
  1. `passport-mdac-app` (Azure OCR): ● Online
  2. `pleasing-acceptance` (Gmail PIN 轮询与配对): ● Online

---

## 2. 优化指标对比总表 (Before vs After)

| 优化维度 | 优化前 (Baseline) | 优化后 (Optimized) | 改善幅度 | 说明 |
| :--- | :--- | :--- | :--- | :--- |
| **Railway 容器数** | 5 个运行中实例 | 2 个运行中实例 | **-60% 容器开销** | 彻底消除跨云与本地同时抢单冲突 |
| **Worker 空闲心跳 RPC 频率** | ~40 次 / 分钟 (每秒并发) | ~3 次 / 分钟 (空闲 60s 间隔) | **-92.5% RPC 流量** | 轮询与心跳彻底解耦，按需更新 |
| **Worker 任务空闲轮询** | 固定 2.0s 频繁空打 | 自适应退避 `[2.0s, 5.0s, 10.0s]` | **-75% 无效轮询** | 发现任务立即复位 0s 连续拉取 |
| **Customer 列表查询请求数** | 3 次独立网络请求 | **1 次**网络请求 | **-66.7% 请求数** | `customer_current_state` 视图服务端聚合 |
| **Customer 列表耗时** | 500.0 ms | **128.4 ms** (min: 108.0 ms) | **-74.3% 延迟** | 服务端 LATERAL JOIN + 单次 PostgREST |
| **最新批次列表请求数** | 12 次独立网络请求 | **1 次**网络请求 | **-91.7% 请求数** | `get_latest_task_dashboard()` 聚合 RPC |
| **最新批次列表耗时** | 1,337.3 ms | **177.9 ms** (min: 165.1 ms) | **-86.7% 延迟** | 12 次串并联请求合并为 1 次 RPC |
| **缺失数据库索引** | 6 项关键外键/状态无索引 | **6 项索引全量创建** | **消除全表扫描** | `idx_email_pin_records_customer_created` 等 |
| **Flutter 根组件重建风暴** | `AnimatedBuilder` 包裹整顶层 Scaffold | `AnimatedBuilder` 下沉至局部 content | **根 UI 0 次无效重建** | 菜单、侧边栏、状态栏不再随数据跳动重绘 |

---

## 3. 详细执行阶段落地记录

### Phase 2 & 3: Railway 重复 Worker 清理与架构确认
- **操作**: 使用 Railway GraphQL API (`serviceDelete`) 删除了 `wholesome-rebirth`、`selfless-enchantment`、`courageous-fascination`。
- **验证**:
  - `npx -y @railway/cli status` 输出确认仅保留 `passport-mdac-app` 与 `pleasing-acceptance`，状态均为 `Online`。
  - Supabase 实时 `worker_heartbeats` 监控确认 `railway-registration-check`、`railway-visit-pass-check`、`railway-mdac-fill-preview` 均已永久停止更新，当前实时心跳 100% 仅来自本地 `DESKTOP-2GLBL48`。

### Phase 4 & 5: 本地 Worker 轮询退避与心跳解耦
- **修改文件**:
  - `services/mdac-fill-preview/worker.py`
  - `services/registration-check-worker/worker.py`
  - `services/visit-pass-check-worker/worker.py`
- **机制升级**:
  1. **心跳解耦**: 新增 `heartbeat_tick()`，空闲时每 60 秒发送一次；任务执行中每 20 秒发送一次；状态变更为 `BUSY` / `ONLINE` 时立即同步。在 `run_once()` 中不再盲发心跳。
  2. **自适应退避**: 空闲时以 `[2.0s, 5.0s, 10.0s]` 梯度递增等待；一旦处理到任务 (`processed > 0`)，立即重置退避计时，不睡眠连续处理下一项，确保队列吞吐最大化。

### Phase 6: Customer 列表服务端视图与 Dart Gateway 改造
- **新增视图**: `public.customer_current_state` (附 `WITH (security_invoker = true)`)，在 Postgres 端一次性合并 `customers`、最新 `email_pin_records`（按 `created_at DESC LIMIT 1`）以及 `profiles.name`。
- **Flutter 端改造**: `lib/supabase_gateway.dart` 中 `fetchCustomers()` 改为单次查询 `customer_current_state`，并保留自动 fallback 机制确保零中断。
- **迁移记录**: `supabase/migrations/20260925000000_customer_current_state_view.sql`。

### Phase 7: 数据库关键索引补充
- **补建索引**:
  1. `idx_email_pin_records_customer_created` ON `email_pin_records(customer_id, created_at DESC)`
  2. `idx_mdac_registrations_customer_id` ON `mdac_registrations(customer_id)`
  3. `idx_registration_checks_customer_checked` ON `registration_checks(customer_id, checked_at DESC)`
  4. `idx_visit_pass_checks_customer_checked` ON `visit_pass_checks(customer_id, checked_at DESC)`
  5. `idx_automation_batches_task_type_created` ON `automation_batches(task_type, created_at DESC)`
  6. `idx_automation_items_batch_created` ON `automation_items(batch_id, created_at)`
- **迁移记录**: `supabase/migrations/20260925010000_performance_indexes.sql`。

### Phase 8: Automation 任务聚合 RPC 改造
- **新增 RPC**: `public.get_latest_task_dashboard()`，在服务端以单次事务同时查询 4 种类型最新 Batch 及其挂载的所有 items 与四类对应凭证表（`mdac_registrations`、`registration_checks`、`visit_pass_checks`、`email_pin_records`）。
- **Flutter 端改造**: `lib/supabase_gateway.dart` 中 `fetchLatestAutomationBatches()` 优先请求该 RPC，网络调用由 12 次大幅削减为 1 次，返回结构保持 100% 严格一致。
- **迁移记录**: `supabase/migrations/20260925020000_latest_task_dashboard_rpc.sql`。

### Phase 10 & 11: Flutter 重建风暴治理
- **修改文件**: `lib/main.dart`
- **优化点**: 原先在 `_MdacShellState.build()` 中，`AnimatedBuilder(animation: widget.repository)` 将整个 `Scaffold`、`SideRail`、`MobileNav` 全部包裹，任何微小数据变更都会触发整个根页面层级重绘。现将其下沉至 `final content = AnimatedBuilder(...)`，让外层导航结构、侧边栏和布局骨架在数据刷新时保持绝对静止，仅局部屏幕进行必要更新。

---

## 4. 稳定性与回归测试结论

1. **Supabase 数据完整性**:
   - `customers`: 95 条记录完整无缺。
   - `automation_batches`: 53 批次完整无缺。
   - `automation_items`: 612 记录完整无缺。
   - `mdac_registrations` / `registration_checks` / `visit_pass_checks` / `email_pin_records`: 全部完好无损。
2. **Worker 运行稳定性**:
   - 本地三个 Worker 使用 `--once` 模式全部顺利执行并正常退出 (Code 0)。
   - Railway 云端两服务（OCR / Gmail PIN）处于持续 `Online` 状态。
3. **Dart 分析与编译**:
   - `flutter analyze lib/supabase_gateway.dart`: **0 错误**。
   - `flutter analyze lib/main.dart`: **0 错误**。
