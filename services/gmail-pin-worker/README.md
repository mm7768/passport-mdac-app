# Gmail PIN Worker

这是 Passport MDAC Desk 的独立 Gmail PIN 获取服务。它从受保护的 Gmail 邮箱只读读取来自 `mdac@imi.gov.my` 的邮件，按客户快照中的护照号进行唯一匹配，把最小必要结果写入 Supabase `email_pin_records`，并同步自动化任务和客户业务状态。

## 当前 MVP 边界

Worker 使用 IMAP App Password 方案作为第一版认证方式。Gmail 地址由 Flutter App 管理，保存到受 RLS 保护的 Supabase 设置表，并在创建任务时复制到批次快照；Gmail App Password 只能保存到 Railway Secret Variables，不能写入 GitHub、APK、聊天或日志。服务使用 `INBOX` 的只读打开方式和 `BODY.PEEK`，不会发送、删除、移动或标记邮件为已读；同一邮箱建议只用于 MDAC PIN，并由公司管理员控制访问权限。

Google 官方更推荐对私人 Gmail 数据使用 OAuth 2.0；后续可以将认证层替换为 Gmail API 只读 OAuth，而不改变 Supabase 任务契约。当前为了复用旧版 IMAP 流程和尽快完成 MVP，必须明确设置 `GMAIL_AUTH_MODE=IMAP_APP_PASSWORD`。

## 任务流程

```text
Flutter 设置 Gmail 地址并选择客户
  → App 地址写入批次快照
  → create_gmail_pin_batch RPC
  → 客户快照与 Gmail 地址快照保存到 automation_batches / automation_items
  → Worker 原子领取批次/项目
  → 使用 Railway Secret 中的 App Password 只读扫描最近邮件
  → 护照号唯一匹配 Name / Passport No. / PIN
  → finish_gmail_pin_item RPC
  → email_pin_records + 客户状态 + 审计日志
```

PIN 值不写入日志，邮件正文不存储。PIN 只在唯一护照号匹配、且邮件中成功解析到非空 PIN 时写入 `email_pin_records.pin_value`，并将客户业务状态更新为 `PIN_RECEIVED`。PIN 的清理规则只去除首尾空白，保留中间空格和连续空格；全空白值视为未获取。

没有匹配邮件的单次轮询使用 `NOT_FOUND` 并在达到最大尝试次数前回到队列。多封匹配、无法解析、护照号缺失、Gmail 认证失败或 refresh/credential 失效都不能标记成功；达到上限后转 `NEEDS_REVIEW` 或 `ACTION_REQUIRED`，保留错误代码和不含敏感内容的摘要。

## Railway 配置

Root Directory 设置为：

```text
services/gmail-pin-worker
```

Branch 使用 `main`。必须配置以下变量；空值只允许出现在 `.env.example`，不能出现在正式 Service：

```text
SUPABASE_URL
SUPABASE_SERVICE_ROLE_KEY
GMAIL_WORKER_ID
GMAIL_AUTH_MODE=IMAP_APP_PASSWORD
GMAIL_APP_PASSWORD
GMAIL_SENDER_FILTER=mdac@imi.gov.my
GMAIL_IMAP_HOST=imap.gmail.com
GMAIL_IMAP_FOLDER=INBOX
GMAIL_LOOKBACK_DAYS=7
GMAIL_POLL_SECONDS=30
GMAIL_LEASE_SECONDS=900
GMAIL_MAX_ATTEMPTS=5
GMAIL_MARK_SEEN=false
SUPABASE_REQUEST_TIMEOUT_SECONDS=30
LOG_LEVEL=INFO
```

`SUPABASE_SERVICE_ROLE_KEY` 和 `GMAIL_APP_PASSWORD` 只能由用户在 Railway 的受保护界面输入。`GMAIL_ADDRESS` 不再是 Railway 变量，由 Flutter App 设置并在任务快照中传给 Worker；App 不保存或读取 App Password。

## 本地离线测试

```bash
python3 -m unittest discover -s services/gmail-pin-worker -p 'test_*.py'
python3 -m py_compile services/gmail-pin-worker/worker.py
```

离线测试不得连接真实 Gmail、Supabase 或使用真实客户资料。一次端到端验收应使用专用测试邮箱、脱敏护照快照和一封脱敏测试邮件；验收重点是唯一匹配、PIN 空白规则、去重、回写状态、重试、人工审核和日志不泄露。

## 参考资料

- Gmail API Guide: https://developers.google.com/workspace/gmail/api/guides
- Google OAuth 2.0: https://developers.google.com/identity/protocols/oauth2
- Gmail App Passwords: https://support.google.com/mail/answer/185833?hl=en
- Gmail IMAP XOAUTH2: https://developers.google.com/workspace/gmail/imap/xoauth2-protocol
