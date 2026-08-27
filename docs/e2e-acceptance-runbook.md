# Passport MDAC Desk 脱敏端到端验收手册

## 目标

本次验收只验证 App、Supabase、Azure OCR 和五个 Railway Worker 的任务闭环。MDAC fill-preview、Check Registration 和 Check Visit Pass 都只填写/回读/截图并转人工审核，不点击官方 Submit，不自动处理 CAPTCHA/滑块。Gmail PIN Worker 只读邮箱，不删除、移动或标记邮件。

## 前置条件

1. 使用包含最新 Gmail 设置页的 Flutter APK。当前仓库 `main` 已包含 Gmail 地址和 App Password 设置，以及 Check Registration/Visit Pass 任务入口。
2. 测试客户必须完全脱敏：测试姓名、测试护照号、测试日期和不对应真实个人的测试资料。不要上传真实护照文件。
3. MDAC 业务默认值在 App 的设置页保存；不要把邮箱、手机、住宿或 Gmail 业务值再写进 Railway。
4. Supabase Service Role Key 只存在 Railway Secret Variables。Gmail App Password 通过 App 的密码字段写入 Supabase Vault，App 保存后不得回读明文。
5. 任务测试期间记录批次 ID、任务项状态、Worker 日志时间和错误摘要，但不要记录 PIN、邮件正文、护照原图或任何 Secret。

## 测试顺序

### A. App 设置与任务入队

登录 App，保存一套脱敏 MDAC 默认业务配置和 Gmail 地址。确认保存成功后 Gmail App Password 输入框清空，并显示凭证已配置。选择测试客户，依次验证 MDAC、Gmail PIN、Check Registration 和 Check Visit Pass 的远程入队入口；App 不应显示本地 dry-run 成功。

每次只创建一种任务，避免多个 Worker 同时处理同一个客户。创建后刷新任务列表，确认状态从 `QUEUED` 开始，并且同一客户在已有活动任务或 `NEEDS_REVIEW` 时不能重复排队。

### B. Azure OCR

上传完全脱敏的 JPG、PNG 或 PDF，确认文件进入私有 Storage，批次状态经过上传和处理阶段，并在人工审核页显示 OCR 草稿。修改字段后确认建档和审核回写。OCR 端到端的成功条件是结果可读、状态正确、没有把文件设为公开。

### C. MDAC fill-preview

创建一笔脱敏 MDAC 任务。Railway `wholesome-rebirth` 应领取任务并使用批次中的 `mdac_settings_snapshot`。验收：普通字段填写或字段校验失败有明确摘要；遇到 CAPTCHA/滑块时写回 `CAPTCHA_SLIDER`/人工审核状态并保存必要截图；任务不能被标记为真实提交成功；`submitted=false`。

### D. Gmail PIN Get

确认 App 中 Gmail 地址与凭证已保存，再创建一笔脱敏 Gmail PIN 任务。Railway `pleasing-acceptance` 应通过 Vault 运行时 RPC 取得凭证，使用任务的 Gmail 地址快照读取邮件。验收：只读连接成功、按护照号唯一匹配、PIN 写入受保护的 PIN 记录、PIN 不出现在日志；未找到、多个匹配、认证失败或解析失败必须进入失败/人工审核，不得伪造成功。

如果没有经过授权的真实 MDAC PIN 邮件，不要为了测试而向官方系统提交伪造登记。此时使用现有离线解析测试即可，真实邮箱验收延后到有合法测试邮件时进行。

### E. Check Registration

创建一笔脱敏 Check Registration 任务。Railway `selfless-enchantment` 应显示 `Registration Check Worker ONLINE` 并领取队列。验收：只填写官方查询页允许的普通字段；检测到 CAPTCHA 时停止并写人工审核；不点击 Search，不读取结果页，不执行 POST；保存必要截图并回写 `NEEDS_REVIEW`/`RESULT_UNKNOWN`。

### F. Check Visit Pass

创建一笔脱敏 Check Visit Pass 任务。Railway `courageous-fascination` 应显示 `Visit Pass Check Worker ONLINE`，轮询间隔为 30 秒，模式为 `FILL_REVIEW`。验收：使用护照号、国籍、App 配置的邮箱、国家/地区代码和手机号快照；不查询结果、不处理 CAPTCHA、不提交；异常状态必须可审计。

## 预期状态

| 场景 | 允许的结果 |
|---|---|
| Worker 正常领取 | `CLAIMED` 或 `RUNNING` |
| 普通字段填写/回读完成但需人工确认 | `NEEDS_REVIEW` |
| CAPTCHA/滑块出现 | `NEEDS_REVIEW`，摘要包含挑战类型 |
| 网络中断或结果不确定 | `RESULT_UNKNOWN` 或 `NEEDS_REVIEW` |
| PIN 唯一匹配成功 | Gmail 任务项 `SUCCEEDED`，PIN 记录写入；PIN 不写日志 |
| PIN 未找到/多匹配/解析失败 | `FAILED` 或 `NEEDS_REVIEW` |
| 任何 Worker 点击 Submit | **验收失败，立即停止任务并保留日志** |

## 完成后需要提供给开发者的内容

只需提供每个批次的非敏感状态、错误摘要和时间，例如：

```text
OCR：READY_TO_CREATE，结果可见
MDAC：NEEDS_REVIEW，检测到 CAPTCHA_SLIDER
Gmail：FAILED，未找到匹配邮件
Registration：NEEDS_REVIEW，页面出现人工挑战
Visit Pass：NEEDS_REVIEW，页面出现人工挑战
```

不要提供密码、Service Role Key、Gmail App Password、PIN、真实护照号码、护照图像或邮件正文。
