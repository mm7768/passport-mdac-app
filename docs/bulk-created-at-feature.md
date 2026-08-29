# 批量修改客户系统 created_at

## 功能流程

在客户档案页选择多个活跃客户后，OWNER 会在底部批量操作栏看到“修改创建时间”。选择新的日期和时间，系统会显示二次确认对话框，确认后直接修改 Supabase `public.customers.created_at`。成功后重新同步客户列表，录入日期筛选和按创建时间排序会立即使用新值。

## 权限与数据保护

批量修改通过 `public.bulk_update_customer_created_at(uuid[], timestamptz)` 专用 RPC 执行。RPC 要求当前账号同时是 active user 和 OWNER，一次最多修改 200 位客户，并拒绝不存在、重复或已软删除的客户。普通 authenticated 客户更新路径不能直接改写 `created_at`；数据库触发器会阻止绕过专用 RPC 的直写。

每位被修改客户各写入一条 `audit_logs` 记录，包含操作人、客户 ID、批次 ID、批次数量、原始 `created_at` 和新 `created_at`。审计 metadata 不包含护照号码或护照文件内容。

## 日期规则

客户端和 RPC 都限制时间不早于 2000-01-01；客户端选择器不允许选择未来日期，数据库额外允许最多一天的时钟偏差保护范围。客户端向 Supabase 发送 UTC ISO 8601 时间，列表显示按照设备本地时间格式化。

## 文件改动

- `lib/main.dart`：客户页面 OWNER-only 批量入口、日期时间选择、二次确认、本地/远程同步。
- `lib/supabase_gateway.dart`：新增批量 created_at RPC 调用。
- `supabase/migrations/20260827_bulk_customer_created_at.sql`：RPC、审计、权限和直写保护触发器。
- `test/demo_repository_test.dart`：批量成功、空选择、软删除和时间边界测试。
- `test/app_widget_test.dart`：多选后入口显示和页面布局测试。

## 验证记录

- Supabase 迁移 `bulk_customer_created_at` 已应用，版本 `20260827135448`。
- 生产核对确认 RPC 为 `SECURITY DEFINER`，`authenticated` 具备执行权限。
- 生产核对确认 `customers_prevent_created_at_change` 触发器已启用。
- `flutter analyze`：通过。
- `flutter test`：23 项通过。
- Debug APK：`build/app/outputs/flutter-apk/app-debug.apk`，约 174 MB。
- SHA-256：`09001804948158984dcebf556f1980bc493b3202b5001a08c41a3cd506e7283f`。

## 已知边界

当前 APK 是 Debug 测试包，不是签名 Release APK。源码改动尚未推送到 GitHub，等待明确的推送指示。Supabase 安全顾问会对允许 authenticated 调用的 SECURITY DEFINER RPC 产生提示；本 RPC 的公开调用是设计所需，并通过 active user、OWNER、数量、客户状态和时间范围进行限制。
