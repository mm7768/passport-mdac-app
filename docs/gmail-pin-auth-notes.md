# Gmail PIN Worker 认证与读取设计依据

更新时间：2026-08-26

## 官方资料

1. Gmail API Guide: https://developers.google.com/workspace/gmail/api/guides
   - Gmail API 支持已授权的邮箱访问，官方列出的适用场景包括只读邮件提取、索引和备份。
   - Gmail API 也支持 mailbox push notifications through Google Cloud Pub/Sub, but the first MVP may use controlled polling.

2. Google OAuth 2.0: https://developers.google.com/identity/protocols/oauth2
   - 访问私人 Gmail 数据需要 OAuth 2.0 授权。
   - 基本流程是取得 OAuth 客户端凭证、取得 access token、核对已授权 scopes、用 Authorization header 调用 API，并在需要时用 refresh token 更新 access token。
   - Refresh token 可能因用户撤销、策略、会话控制或其他原因失效；Worker 必须把失效视为 NEEDS_REVIEW/配置错误，不把它当作 PIN 不存在。

3. Gmail App Passwords: https://support.google.com/mail/answer/185833?hl=en
   - App Password 是 16 位密码，可用于不能使用 OAuth 的应用/设备。
   - 账号必须启用 2-Step Verification；工作/学校/组织账号、Advanced Protection 或仅安全密钥等情况可能无法使用 App Password。
   - App Password 只能作为 Railway 受保护变量保存，不得放在聊天、代码、GitHub 或 APK。

4. Gmail IMAP XOAUTH2: https://developers.google.com/workspace/gmail/imap/xoauth2-protocol
   - Gmail IMAP 支持 XOAUTH2。
   - IMAP full-mail scope 是 https://mail.google.com/；官方建议如果不需要完整邮件范围，应迁移到 Gmail API 使用更细粒度 scope。
   - 旧版脚本使用 imaplib.IMAP4_SSL、发件人 mdac@imi.gov.my 过滤、Message-ID 去重，并提取 Name、Passport No.、PIN。

## 当前设计决定

- Gmail PIN Worker 是独立 Railway 服务，不使用 Flutter APK 读取 Gmail，也不把 Gmail 凭证存到 Supabase。
- 首选 Gmail API OAuth 只读方案；若为了 MVP 采用 IMAP App Password，必须明确其权限较宽且只能由用户在 Railway Secret Variables 粘贴。
- 邮件读取范围限制为 Inbox 中来自 mdac@imi.gov.my 的邮件；只读取必要 headers/body，不删除、移动或发送邮件。
- PIN 处理规则：PIN 为空或仅空白表示未获取；清理首尾空白，保留中间空格和连续空格；不要把 PIN 写入日志。
- 每封邮件使用 email_message_id 唯一去重；成功匹配护照号后写入 email_pin_records，并将 automation item 标为 SUCCEEDED、客户业务状态改为 PIN_RECEIVED。
- 找不到匹配客户、无法解析 PIN、认证失败、邮箱授权失效或匹配不唯一时，不标成功；使用 NEEDS_REVIEW/PARSE_FAILED/NOT_FOUND 等语义并写入审计摘要。
- 任务成功/失败/待审核必须由 Supabase RPC 原子回写；避免客户端本地假成功。
- 不把真实 Gmail 账号、密码、OAuth refresh token、真实 PIN 或护照号码写入测试代码、日志、GitHub 或聊天。
