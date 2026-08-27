# Check Registration Worker

这是从零实现的 MDAC Check Registration Worker，当前只执行 **fill-and-review**：打开官方 Check Registration 页面，填写护照号、国籍和已确认 PIN，回读字段，检测官方 CAPTCHA/滑块，保存私有截图并写回 `NEEDS_REVIEW` 或 `RESULT_UNKNOWN`。

本 Worker 不依赖旧 `mdac-dry-run` 业务逻辑。它只复用已验证的 Supabase 队列租约、审计、Flutter 任务契约和私有 Storage 基础设施。

## 当前安全范围

- `REGISTRATION_CHECK_MODE` 必须是 `FILL_REVIEW`。
- `ALLOW_REAL_SUBMIT` 必须严格是 `false`。
- `REGISTRATION_CHECK_HEADLESS` 必须严格是 `true`。
- 不调用官方 `/mdac/register` POST。
- 不点击 Submit，不使用 Enter 提交，不读取提交结果作为成功依据。
- 不识别、模拟或绕过 CAPTCHA/滑块；检测到官方挑战后转人工审核。
- 不在日志写护照号、PIN、完整邮件或截图公开 URL。
- PIN 只通过 service-role-only RPC 在 Worker 运行时取用，不复制进客户端可读的任务快照。

## 官方页面契约

当前公开入口：

```text
https://imigresen-online.imi.gov.my/mdac/register?viewRegistration
```

已核对字段：

| 业务含义 | DOM ID | Worker 行为 |
|---|---|---|
| Passport No. | `passNo` | 从客户任务快照读取并填写 |
| Nationality | `nationality` | 从客户任务快照读取，使用三字母 value |
| PIN | `pinKeyId` | 从服务端 RPC 读取并填写，不写入日志 |
| Challenge hidden value | `sliderCapture` | 只检测，不生成或伪造 |
| 官方查询按钮 | `submit` / `searchRegistration` | 不调用 |

## 队列流程

```text
Flutter 创建 REGISTRATION_CHECK 批次
→ create_registration_check_batch
→ claim_registration_check_batch
→ claim_registration_check_item
→ get_registration_check_runtime_input
→ Playwright 填写并回读
→ 检测 CAPTCHA/滑块
→ 上传私有截图
→ finish_registration_check_item
→ NEEDS_REVIEW / RESULT_UNKNOWN
```

入队 RPC 要求客户存在一个 `RECEIVED` PIN 记录；PIN 不会放进 `automation_items.customer_snapshot`。任务快照只含 `full_name`、`passport_number` 和 `nationality`。

## Railway 部署

Root Directory：

```text
services/registration-check-worker
```

独立启动配置：

```text
python worker.py --poll
```

需要设置的变量：

```text
SUPABASE_URL
SUPABASE_SERVICE_ROLE_KEY
REGISTRATION_CHECK_WORKER_ID=railway-registration-check
REGISTRATION_CHECK_MODE=FILL_REVIEW
ALLOW_REAL_SUBMIT=false
REGISTRATION_CHECK_HEADLESS=true
REGISTRATION_CHECK_URL=https://imigresen-online.imi.gov.my/mdac/register?viewRegistration
REGISTRATION_CHECK_POLL_SECONDS=30
REGISTRATION_CHECK_LEASE_SECONDS=900
REGISTRATION_CHECK_MAX_ATTEMPTS=5
SUPABASE_REQUEST_TIMEOUT_SECONDS=30
REGISTRATION_CHECK_PAGE_TIMEOUT_MS=60000
REGISTRATION_CHECK_SCREENSHOT_BUCKET=passport-documents
REGISTRATION_CHECK_SCREENSHOT_PREFIX=registration-check-previews
LOG_LEVEL=INFO
```

`SUPABASE_SERVICE_ROLE_KEY` 只能由用户在 Railway Secret Variables 中保存。不要把它放进 App、GitHub、`.env`、APK 或聊天。

## 测试

```bash
python3 -m unittest services/registration-check-worker/test_worker.py -v
python3 -m py_compile services/registration-check-worker/worker.py
```

测试不访问官方页面、不访问 Supabase、不读取 Gmail，也不需要真实护照资料。

## 当前未实现

真实的结果确认、Check Registration 的 Submit、自动 CAPTCHA/滑块处理和任何结果自动确认都不属于当前版本。页面只填写并保存预览，最终状态必须人工确认。

> 本服务不是官方 API；页面结构变化时必须先做静态核对，再更新选择器和测试。
