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
| `lib/main.dart` | Flutter 界面、客户维护、上传和 OCR 审核交互 |
| `lib/supabase_gateway.dart` | Supabase Auth、客户 CRUD、Storage、OCR 批次和结果网关 |
| `test/` | Repository 与 Widget 回归测试 |
| `worker/azure_ocr_worker.py` | 真实 Azure 护照 OCR Worker |
| `worker/dry_run_worker.py` | 安全演示 Worker |
| `worker/README.md` | Worker 运行和 Railway 配置边界 |
| `Dockerfile` | Railway Python Worker 镜像入口 |
| `railway.toml` | Railway 构建、启动和重启策略 |
| `supabase/migrations/` | 数据库、RLS、Storage 元数据和去重迁移 |
| `docs/implementation-notes.md` | 规格映射、当前边界和实施记录 |

## 当前未包含

Gmail IMAP PIN、MDAC 真实网页自动化、Check Registration、Visit Pass 查询、数据库租约超时恢复、生产级告警和正式 Android Release 签名仍属于后续阶段。真实运行前应先使用完全脱敏样本完成 Azure OCR 验收，并设置护照资料、OCR 原文和日志的保留期限。
