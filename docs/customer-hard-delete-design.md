# Owner 手动永久删除客户设计

## 目标

Passport MDAC Desk 允许 Owner 直接选择客户并永久删除，但系统只放行没有进行中任务的客户。系统不会自动扫描、自动过期或自动删除；是否删除完全由 Owner 判断。

## 用户流程

```text
客户列表多选
  → 点击“永久删除”
  → 系统预览每位客户是否有进行中任务
  → 显示可删除数量、阻止删除数量和资料范围
  → Owner 二次确认
  → 创建不可变 purge job，并再次锁定/检查资格
  → App 删除该 job 列出的私有 Storage 对象
  → App 标记 Storage 已清理
  → Owner-only RPC 在数据库事务内删除关联资料和客户记录
  → 成功刷新客户列表；失败保留 job 供重试
```

## 删除资格

Owner-only 预览 RPC 会逐位客户检查关联任务。存在以下任一进行中状态时，客户不可删除：

| 数据范围 | 阻止状态 |
|---|---|
| `automation_items` | `QUEUED`、`CLAIMED`、`RUNNING`、`NEEDS_REVIEW` |
| `ocr_results` | `REVIEW_REQUIRED`、`READY_TO_CREATE` |
| `mdac_registrations` | `SUBMITTED`、`NEEDS_REVIEW`、`RESULT_UNKNOWN` |
| `email_pin_records` | `NEEDS_REVIEW` |
| `registration_checks` | `UNPARSED`、`NEEDS_REVIEW` |
| `visit_pass_checks` | `UNPARSED`、`NEEDS_REVIEW` |

没有进行中任务的客户可删除，包括尚未进入任何任务的客户，以及所有相关任务已经进入终态的客户。`FAILED`、`CANCELLED`、`SUCCEEDED`、`NOT_FOUND`、`PARSE_FAILED` 和 `PARSED` 不会阻止删除。

## 删除范围

系统会清理客户护照图片/PDF、OCR 批次文件、MDAC/Registration/Visit Pass 截图、OCR `raw_result`、OCR `extracted_data`、任务快照、Gmail PIN 记录、各模块结果、客户记录，以及与该客户关联的审计明细。最后只保留一条不含护照号、MRZ、姓名、联系方式、原图或 OCR 内容的最小事件，记录操作人、purge job ID、删除数量和时间。

Storage 路径由数据库在 Owner 确认时生成并冻结。Flutter 只能删除 RPC 返回的、属于私有 `passport-documents` bucket 的路径；不能根据客户输入拼接任意 Storage 路径。数据库完成删除前要求 App 先标记这些路径已经处理，避免误把“只删了数据库”报告为成功。

## 事务和失败恢复

Supabase 数据库事务和 Storage 对象删除不是同一个原子事务。因此系统先创建 `REQUESTED` purge job，再删除 Storage，最后调用 `complete_customer_hard_delete`。如果 App 在中途退出，客户数据库记录仍然存在，Owner 可以重新执行同一 job；已经不存在的 Storage 对象不会影响重试。只有数据库完成关联删除后，job 才进入 `COMPLETED`。

没有后台 Worker 或定时清理任务。只有 Owner 在 App 中明确点击并确认后，才会创建和执行 purge job。若 Storage 删除或数据库完成阶段失败，系统显示未完成状态，保留 job 信息用于重试，不删除其他客户。

## 并发和安全

所有预览、创建 job、标记 Storage 清理和数据库完成 RPC 都只允许 active OWNER。创建 job 和完成删除时会重新检查进行中任务；如果预览之后有新任务进入，完成 RPC 会拒绝删除。数据库删除在事务内按依赖顺序执行，避免当前关联表的 `ON DELETE RESTRICT` 阻止或留下业务孤儿记录。

普通 authenticated 用户不能执行永久删除，也不能直接删除客户行。Flutter 不持有 Service Role Key。私有 Storage 的 Owner delete policy 只由 App 按数据库冻结路径调用。

## 非目标

本功能不自动清理所有历史过期资料，不改变普通软删除行为，不允许 Operator 执行，不执行跨客户清理，不修改其他客户，不清理没有被客户记录引用的孤立 Storage 对象，也不保留完整删除前快照。孤立对象需要另行做管理员审计工具。
