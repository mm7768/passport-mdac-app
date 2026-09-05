# Customer / Case 重构审计基线

日期：2026-09-02  
分支：`feat/mdac-human-review`  
Supabase：`passport-mdac-desk`

## 结论

采用兼容式迁移：先新增 Customer / Passport / Case / Customer MDAC Profile，
保留现有 `customer_id`、Customer Passport 字段和 `business_status`，再通过双写逐模块切换。

生产库当前业务量较小：4 位 Customer、6 条 OCR Result；Automation Batch、
Automation Item、MDAC Registration、Email PIN、Registration Check 和 Visit Pass
均为 0 条。这是建立新结构和回填默认 Case 的低风险窗口。

## 当前依赖

| 模块 | 当前主关联 | 当前状态写入 | 迁移要求 |
|---|---|---|---|
| Flutter 建档 | Customer | customers.business_status | 双写 Customer + Passport + Case |
| OCR | ocr_results.created_customer_id | OCR status | 增加 passport_id / case_id 来源关联 |
| Automation | automation_items.customer_id | item/batch status | 新增 nullable case_id，兼容 customer_id |
| MDAC | customer_snapshot + customer_id | customers.business_status | 结果改写 customer_cases.case_status |
| Gmail PIN | customer_id | customers.business_status | 历史保留，当前 PIN 移至私有 Profile |
| Registration | customer_id | customers.business_status | 结果改为 case_id |
| Visit Pass | customer_id | customers.business_status | 结果改为 case_id |
| 删除 | Customer 级硬删除 | 多表清理 | 增加 Case 归档/清理，A 客户禁止随 Case 删除 |

## 数据库发现

- 所有核心 public 表已启用 RLS。
- 当前 RLS 主要基于“active user”，并非逐客户 ownership 隔离。
- `email_pin_records` 当前允许 authenticated 用户 SELECT，不能作为长期可复用
  PIN 的最终存储边界。
- 多个创建/完成 RPC 直接查询 `customer_id` 并更新
  `customers.business_status`。
- MDAC Worker 使用队列中的 customer snapshot，迁移时可以先增加 case snapshot，
  无需立即重写浏览器填表部分。
- Gmail、Registration、Visit Pass Worker 都从 Automation Item 读取
  `customer_id`，需要兼容期。

## Supabase / 安全约束

- 新 public 表必须显式 GRANT；不能依赖自动暴露到 Data API。
- public 表必须启用 RLS，并同时验证 table grant 与 policy。
- 可复用 PIN 放入 private schema，通过受控 RPC/Worker 访问，不允许 Flutter
  普通 SELECT 明文。
- 新外键全部建立覆盖索引。
- SECURITY DEFINER 仅用于确有必要的受控入口，内部函数放 private schema，
  固定 search_path，并撤销 PUBLIC EXECUTE。

## 第一批迁移边界

第一批只做以下可兼容变更：

1. 新增 `passports`、`customer_cases`。
2. 新增私有 `customer_mdac_profiles`。
3. Customer 新增 customer_type、retention_policy、last_active_at、
   customer_status。
4. Automation Item、MDAC、Registration、Visit Pass 增加 nullable
   `case_id`；旧 `customer_id` 保留。
5. 为现有 4 位 Customer 回填一个 Active Passport 和一个 Legacy Case。
6. 添加验证查询；不删除或重命名任何旧字段。

## 已知存量问题

- 6 条 OCR Result 均为 CREATED，但 created_customer_id 为空；不能无依据自动归入
  现有 Customer/Case。
- 当前没有业务结果记录，因此第一次回填不需要猜测历史 MDAC/PIN/Check Case。
- Supabase Advisor 报告若干既存 SECURITY DEFINER 提示及未索引外键；本次迁移
  不扩大这些权限，新增结构必须不产生新的告警。

## 验证门槛

- 每个现有 Customer 恰好生成一个默认 Passport 和一个默认 Case。
- 每位 Customer 最多一个 Active Passport。
- 所有新增 public 表 RLS 开启且授权明确。
- Flutter v9 和现有 Worker 在不认识新字段时仍能正常运行。
- 迁移前后现有表行数及关键业务字段保持不变。

