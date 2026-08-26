# Passport MDAC Desk

Passport MDAC Desk 是按 `passport-mdac-app-spec` 实现的 Flutter Android 应用。它将护照资料、OCR 人工确认、客户主档案和 MDAC 自动化任务放在同一个可追踪工作区中；手机端、Supabase 和服务端 Worker 通过明确的任务边界协作。

当前版本已经接入真实 Supabase Auth、客户 CRUD、软删除、私有 Storage、图片/PDF 上传和 OCR 批次记录。Azure 护照 OCR Worker 已完成真实 API 适配和离线解析测试；真实 Azure 识别需要在 Railway Secret Variables 配置 Azure Key 和 Supabase Service Role Key。

## Flutter 运行与验证

需要 Flutter stable、Dart、Android SDK 和 JDK 21。项目根目录可执行：

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

真实 Supabase 模式通过 `dart-define` 注入客户端配置，不把 URL 或 Publishable Key 硬编码进 Dart 源码：

```bash
flutter build apk --debug \\
  --dart-define=SUPABASE_URL=https://xdmcxhvdqsbcqedfprcy.supabase.co \\
  --dart-define=SUPABASE_PUBLISHABLE_KEY=你的_sb_publishable_key
```

未提供 `dart-define` 时会回退到演示模式，方便离线测试。真实模式支持 Email/Password 登录、会话恢复、客户读取/新建/编辑/软删除、OCR 结果恢复和审核确认建档。

## 文件上传与 OCR 流程

```text
Flutter 选择 JPG/PNG/PDF
        ↓
Supabase 私有 passport-documents bucket
        ↓
ocr_batches（包含文件名、MIME、大小、SHA-256）
        ↓
Railway Python Azure OCR Worker
        ↓
Azure Document Intelligence prebuilt-idDocument
        ↓
ocr_results（raw_result、extracted_data、confidence、status）
        ↓
Flutter 人工审核并确认建档
```

手机端文件大小上限为 15 MB。上传内容使用 SHA-256 保护重复提交；OCR 结果缺少关键字段、性别不支持、日期无效或文档类型异常时会进入 `REVIEW_REQUIRED`，不会自动建立客户档案。

## Railway Worker 部署

仓库现在分为两个独立的后台服务：Azure OCR Worker 负责护照 OCR，MDAC fill-preview Worker 负责真实页面填表预览。两个服务不共享提交路径，避免 OCR 服务或旧 dry-run 服务的配置变化影响 MDAC 页面操作。

### MDAC Headless Fill Preview

`services/mdac-fill-preview/` 是当前新增的真实 headless 服务。它从 Supabase 原子领取 `MDAC_REGISTRATION` 批次和任务项，使用 Playwright Chromium 打开官方 MDAC 登记页，填写客户快照和固定资料，回读页面字段并上传私有预览截图。它只写回 `NEEDS_REVIEW`，不会点击 Submit、不会绕过滑块/CAPTCHA，也不会把未确认结果标记为成功。

该服务启动时强制要求 `MDAC_EXECUTION_MODE=FILL_PREVIEW` 与 `ALLOW_REAL_SUBMIT=false`。Railway 根目录应设为 `services/mdac-fill-preview`，使用该目录的 `Dockerfile`。账号登录、密码、MFA、滑块或其他人工挑战不会由服务自动绕过；遇到这些情况必须转人工审核。

MDAC 邮箱、手机、交通方式、出发国家、航班/车辆/船号、住宿类型、地址、州、城市、邮编和 POB 映射现在由 Flutter 设置页编辑，保存到受 RLS 保护的 `mdac_settings` 表。创建任务时，Supabase 会把这份业务配置复制到 `automation_batches.mdac_settings_snapshot`；之后修改默认设置不会影响已经排队的批次。Service Role Key、Worker 安全模式和真实 Submit 禁止开关仍只存在 Railway 受保护变量中。

当前 Supabase 已增加 `claim_mdac_batch`、`claim_mdac_item`、`heartbeat_mdac`、`finish_mdac_fill_preview`、`create_mdac_registration_batch` 和 `update_mdac_settings`，包含原子领取、租约、心跳、尝试次数、设置审计和 `RESULT_UNKNOWN/NEEDS_REVIEW` 边界。Flutter 远程模式创建 MDAC 任务时保存客户/设置快照，并在任务页面提供 Supabase 状态刷新。

### Gmail PIN Worker

`services/gmail-pin-worker/` 是独立的 Gmail PIN 获取服务。它使用只读 IMAP App Password 方案作为第一版，扫描最近邮件中来自 `mdac@imi.gov.my` 的消息，按任务快照中的护照号进行唯一匹配，并将 PIN 结果写入 `email_pin_records`。服务不会删除、移动或标记邮件为已读，不保存邮件正文，也不会把 PIN 写入日志。

Gmail 地址和 App Password 只能由用户在 Railway Secret Variables 中填写；不要把它们放入 Flutter、GitHub、聊天或测试代码。当前 Supabase 已增加 `create_gmail_pin_batch`、`claim_gmail_pin_batch`、`claim_gmail_pin_item`、`heartbeat_gmail_pin` 和 `finish_gmail_pin_item`。唯一匹配并成功解析 PIN 时，任务项才标为 `SUCCEEDED`、客户状态改为 `PIN_RECEIVED`；未找到、解析失败、匹配不唯一或认证异常不会伪装成成功。

该服务的 Railway Root Directory 应设为 `services/gmail-pin-worker`，使用目录内的 Dockerfile 和 `railway.toml`。首轮部署前必须在受保护变量中配置 Gmail 地址、App Password、Supabase Service Role Key 和 Worker 参数，并使用一封脱敏测试邮件完成端到端验收。

仓库根目录的 `Dockerfile` 和 `railway.toml` 已配置为 Python Worker 服务，默认启动：

```bash
python worker/azure_ocr_worker.py --poll
```

Railway Variables 需要配置以下服务端变量：

```text
AZURE_DI_ENDPOINT=https://passport-mdac-ocr.cognitiveservices.azure.com/
AZURE_DI_KEY=你的 Azure Key
SUPABASE_URL=https://xdmcxhvdqsbcqedfprcy.supabase.co
SUPABASE_SERVICE_ROLE_KEY=Worker 专用密钥
OCR_WORKER_ID=railway-azure-ocr-worker
OCR_QUEUE_POLL_SECONDS=15
OCR_POLL_SECONDS=2
OCR_REQUEST_TIMEOUT_SECONDS=45
```

Azure Key 和 Supabase Service Role Key 只能放在 Railway Secret Variables 中，不能放进 Flutter、GitHub 或聊天消息。Worker 会自动查找并领取最早的 `UPLOADED` OCR 批次，更新为 `PROCESSING`，读取私有文件，调用 Azure，并将结果回写为 `READY_TO_CREATE`、`REVIEW_REQUIRED` 或 `FAILED`。

## 本地 Worker 测试

离线测试不会调用 Azure，也不会上传文件：

```bash
PYTHONPATH=worker python -m unittest discover -s worker -p 'test_*.py'
```

手动处理单个真实批次：

```bash
python worker/azure_ocr_worker.py --batch-id <OCR批次UUID>
```

持续轮询待处理批次：

```bash
python worker/azure_ocr_worker.py --poll
```

`dry_run_worker.py` 只用于演示旧版字段映射、任务状态和失败隔离，不调用 Azure、Gmail 或 MDAC 网页。

## 目录

| 路径 | 用途 |
|---|---|
| `lib/main.dart` | Flutter 界面、客户维护、MDAC 设置、上传和 OCR 审核交互 |
| `lib/supabase_gateway.dart` | Supabase Auth、客户 CRUD、Storage、OCR 和 MDAC 任务网关 |
| `test/` | Repository 与 Widget 回归测试 |
| `worker/azure_ocr_worker.py` | 真实 Azure 护照 OCR Worker |
| `services/mdac-fill-preview/` | 真实 MDAC headless 填表预览 Worker，零 Submit |
| `services/gmail-pin-worker/` | Gmail PIN 只读获取 Worker，不发送/删除邮件 |
| `services/gmail-pin-worker/README.md` | Gmail PIN 认证、部署、状态和验收说明 |
| `services/mdac-fill-preview-legacy-audit.md` | 旧 MDAC 选择器与安全边界审查记录 |
| `supabase/migrations/20260826_mdac_worker_leases.sql` | MDAC Worker 租约、原子领取和预览回写函数 |
| `supabase/migrations/20260826_mdac_batch_enqueue.sql` | Flutter MDAC 批次原子入队和客户快照函数 |
| `supabase/migrations/20260826_mdac_settings.sql` | App 可编辑 MDAC 默认配置、RLS 与审计 RPC |
| `supabase/migrations/20260826_mdac_settings_snapshot.sql` | 入队时复制 MDAC 业务配置快照 |
| `supabase/migrations/20260826_gmail_pin_worker.sql` | Gmail PIN 队列、租约和原子结果回写 |
| `docs/gmail-pin-auth-notes.md` | Gmail 官方认证资料与安全设计依据 |
| `worker/dry_run_worker.py` | 安全演示 Worker |
| `worker/README.md` | Worker 运行和 Railway 配置边界 |
| `Dockerfile` | Railway Python Worker 镜像入口 |
| `railway.toml` | Railway 构建、启动和重启策略 |
| `supabase/migrations/` | 数据库、RLS、Storage 元数据和去重迁移 |
| `docs/implementation-notes.md` | 规格映射、当前边界和实施记录 |

## 当前未包含

真实 MDAC Submit、Check Registration、Visit Pass 查询、生产级告警和正式 Android Release 签名仍属于后续阶段。当前 MDAC 网页自动化只完成真实填表预览；首次真实提交必须另行明确授权，并由独立的提交流程处理。Gmail PIN Worker 已完成代码和数据库契约，但仍需 Railway 独立服务部署以及一次受控端到端测试。
真实运行前应先使用完全脱敏样本完成 Azure OCR 验收，并设置护照资料、OCR 原文和日志的保留期限。
