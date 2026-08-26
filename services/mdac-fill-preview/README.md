# MDAC Headless Fill Preview Worker

这是 Passport MDAC Desk 的独立 Railway 服务。它使用 Python + Playwright Chromium 打开马来西亚移民局 MDAC 登记页，读取 Supabase 中的 `MDAC_REGISTRATION` 队列，按任务快照填写真实表单、回读 DOM 值、保存私有 PNG 预览，并将任务写回 `NEEDS_REVIEW`。

## 当前绝对边界

本服务是 **fill-preview only**。源码不包含真实 Submit 调用；启动时必须同时满足 `MDAC_EXECUTION_MODE=FILL_PREVIEW` 和 `ALLOW_REAL_SUBMIT=false`，否则进程直接拒绝启动。表单 POST 路由还会被 Playwright 防护层拦截，作为第二层保护。服务不会自动点击 Submit，不会把验证码、滑块或 CAPTCHA 当作可自动破解对象，也不会绕过反自动化机制。

如果页面出现账号登录、密码、MFA、验证码、滑块或其他人工挑战，Worker 会把该项保存为 `NEEDS_REVIEW`，并在摘要中标记 `manual_review_required=true`。当前官方登记页是公开表单，首版不预置 MDAC 账号密码；如果将来页面改为登录制，应先设计经授权的人工接管流程，不要把密码写入仓库、聊天或 APK。

## 工作流程

```text
Supabase automation_batches: QUEUED / MDAC_REGISTRATION
        ↓  claim_mdac_batch()：FOR UPDATE SKIP LOCKED + batch lease
Supabase automation_items: QUEUED
        ↓  claim_mdac_item()：单项 lease + attempt limit
Playwright 新 BrowserContext
        ↓
打开官方 MDAC 表单
        ↓
填写固定资料与 customer_snapshot
        ↓
回读 DOM，检查字段值、invalid 控件和页面 URL
        ↓
截图上传到私有 Storage bucket
        ↓
finish_mdac_fill_preview()
        ↓
item=NEEDS_REVIEW、mdac_registrations=NEEDS_REVIEW、submitted=false
```

批次和单项都带租约。Worker 心跳会续期租约；进程崩溃后，下次领取会回收已过期的 `CLAIMED/RUNNING` 项。每项有最大尝试次数，超过上限不能无限循环。预览完成后，数据库原子函数会同时写入 `mdac_registrations` 和 `audit_logs`，并明确保存 `submitted=false`、`result_confirmed=false`、`submitted_at=NULL` 和 `result_confirmed_at=NULL`。

## 旧版规则的迁移

首版沿用旧 `mdac-auto-v2` 的确定性映射：区域代码默认为 `60`；国籍大写；`#pob` 默认跟随国籍；男/女转换为 `1/2`；姓名去首尾空格；护照号去首尾空格并转大写；日期写为 `DD/MM/YYYY`。`MDAC_POB_MODE=CUSTOMER` 可使用任务快照中的 `place_of_birth`，但应在业务确认后再启用。

客户资料不从 Excel 读取，而是使用创建任务时写入的 `automation_items.customer_snapshot`。批次的入境/出境日期作为回退值，并且会再次校验出境日期不能早于入境日期。

## Railway 设置

在 Railway 创建独立 Service，连接 `mm7768/passport-mdac-app` 的 `main` 分支，并设置：

```text
Root Directory: services/mdac-fill-preview
Dockerfile: Dockerfile
Start Command: Dockerfile 内的 CMD
```

必须把下列变量放在 Railway Variables/Secrets 中，不要放进 GitHub 或 APK：`SUPABASE_SERVICE_ROLE_KEY`、`MDAC_EMAIL`、`MDAC_PHONE`、`MDAC_VESSEL`、`MDAC_ADDRESS1`、`MDAC_ADDRESS2`、`MDAC_POSTCODE`。`MDAC_STATE` 与 `MDAC_CITY` 也应根据真实住宿资料在 Railway 中填写，不要假定示例值适用于生产。

最低运行变量如下：

```text
SUPABASE_URL
SUPABASE_SERVICE_ROLE_KEY
MDAC_EXECUTION_MODE=FILL_PREVIEW
ALLOW_REAL_SUBMIT=false
MDAC_WORKER_ID
MDAC_EMAIL
MDAC_PHONE
MDAC_VESSEL
MDAC_ADDRESS1
MDAC_ADDRESS2
MDAC_POSTCODE
```

其他变量可直接参考 `.env.example`。不要配置任何 `MDAC_USERNAME`、`MDAC_PASSWORD` 并期待 Worker 自动登录；当前代码遇到密码输入框会转人工审核。

## 本地测试

纯映射和安全配置测试不访问外部网站。需要真实页面联调时，必须使用脱敏客户快照，并确认你对目标 MDAC 业务拥有正式授权。联调第一阶段只观察截图和 `NEEDS_REVIEW` 记录；任何真实 Submit 都不属于本服务的当前范围。

```bash
python -m unittest discover -s services/mdac-fill-preview -p 'test_*.py'
```

## 已知限制

当前 Railway Worker 尚未连接 Flutter 的真实 automation batch 创建和任务同步界面；这需要客户端后续改动，尤其要移除本地演示 Worker 产生的乐观 `MDAC_REGISTERED` 状态。当前服务也不处理 Gmail PIN、不查询注册结果、不重试结果未知的真实提交。未来若要开启真实提交，应另建明确的 Submit Worker，并要求独立授权、单独凭证/策略、人工确认和 `RESULT_UNKNOWN` 防重复提交设计，不能通过修改本服务的一个环境变量实现。
