# Gmail PIN 凭证管理设计

## 目标

Gmail 地址和 Gmail App Password 都可以由授权用户在 Flutter App 中维护，但 Gmail App Password 不能进入 APK、普通 Supabase 配置表、日志或 GitHub。Supabase Service Role Key 仍然只保留在 Railway Secret Variables。

## 当前方案与后续安全方案

当前 Gmail 地址已由 Flutter App 管理，并在创建 `GMAIL_PIN` 批次时复制到 `automation_batches.gmail_settings_snapshot`。Gmail App Password 当前暂时仍使用 Railway Secret Variables，作为尚未完成服务端密钥托管前的安全运行方案。

目标方案使用 Supabase Vault 保存加密凭证。Vault 在磁盘和备份中保存加密数据，解密视图必须限制访问权限；普通 `authenticated` 客户端只调用带审计的设置 RPC，不能直接读取 Vault 解密视图。Supabase Service Role Worker 通过受限制的服务端 RPC 获取运行时凭证，RPC 不把密码写回客户端、任务快照或日志。

## 数据流

```text
Flutter 设置页
  → TLS
  → 受 RLS/角色限制的 save_gmail_credentials RPC
  → Vault 加密保存 Gmail App Password
  → gmail_settings 保存非秘密状态和 Vault secret UUID
  → App 只得到 address + configured=true
  → Gmail Worker 通过 service-role-only runtime RPC 获取凭证
  → IMAP 只读读取 PIN 邮件
```

## 禁止事项

不能把 `GMAIL_APP_PASSWORD` 明文写入 `gmail_settings`、`automation_batches`、`automation_items`、Flutter SharedPreferences、APK、GitHub、Railway 日志或审计 metadata。不能让普通 `authenticated` 用户查询 `vault.decrypted_secrets`。不能在审计日志中记录密码、邮件正文或 PIN。

## 权限和审计

只有 active OWNER/OPERATOR 可以通过 App 保存地址和更新密码；是否限制为 OWNER 需要在最终权限确认时决定。保存、轮换、撤销和 Worker 读取事件只记录时间、操作者、邮箱域、凭证是否已配置和结果状态，不记录密钥内容。Worker 读取 RPC 应只授予 `service_role`，并且必须校验 Worker 调用上下文和有效任务。

## 当前未完成

当前仓库的 Gmail Worker 仍从 Railway `GMAIL_APP_PASSWORD` 读取密码。下一阶段需要先确认目标 Supabase 项目已启用 Vault，再新增最小权限 RPC 和 Worker runtime 读取接口；完成单元测试、权限测试和脱敏端到端测试后，才移除 Railway 中的 `GMAIL_APP_PASSWORD`。

## 参考资料

- [Supabase Vault 官方文档](https://supabase.com/docs/guides/database/vault)
- [Supabase Vault 官方介绍](https://supabase.com/blog/supabase-vault)
