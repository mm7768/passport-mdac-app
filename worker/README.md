# Passport MDAC OCR Worker

本目录提供 Azure 护照 OCR Worker。Worker 只运行在服务端（例如 Railway），不会放进 Flutter APK，也不会把 Azure Key 或 Supabase Service Role Key 写入 GitHub。

## 当前能力

- 从 Supabase 私有 `passport-documents` Storage 读取上传的图片/PDF。
- 调用 Azure Document Intelligence `prebuilt-idDocument` 模型。
- 轮询异步识别结果，解析护照号码、姓名、出生日期、有效期、国籍、性别和 MRZ。
- 把原始 JSON、标准化字段、置信度和审核状态写入 `ocr_results`。
- `REVIEW_REQUIRED`、`READY_TO_CREATE` 和 `FAILED` 状态由手机端审核流程继续处理。
- 支持单批次命令，也支持 Railway 持续轮询 `UPLOADED` 批次。

## Railway 部署

仓库根目录的 `Dockerfile` 和 `railway.toml` 已配置为直接启动：

```bash
python worker/azure_ocr_worker.py --poll
```

Railway 服务需要配置以下 Variables。真实值只在 Railway Secret Variables 中设置，不要提交 `.env`：

```text
AZURE_DI_ENDPOINT=https://passport-mdac-ocr.cognitiveservices.azure.com/
AZURE_DI_KEY=your-azure-key
SUPABASE_URL=https://xdmcxhvdqsbcqedfprcy.supabase.co
SUPABASE_SERVICE_ROLE_KEY=your-supabase-service-role-key
OCR_WORKER_ID=railway-azure-ocr-worker
OCR_QUEUE_POLL_SECONDS=15
OCR_POLL_SECONDS=2
OCR_REQUEST_TIMEOUT_SECONDS=45
```

Worker 会定期查找最早的 `UPLOADED` OCR 批次，使用 `status=eq.UPLOADED` 条件尝试领取为 `PROCESSING`，然后读取私有文件并调用 Azure。若识别成功，批次状态会变为 `READY_TO_CREATE` 或 `REVIEW_REQUIRED`；若异常，批次状态会变为 `FAILED` 并记录脱敏后的错误信息。

## 本地运行单个批次

在项目根目录设置环境变量后执行：

```bash
python worker/azure_ocr_worker.py --batch-id <OCR批次UUID>
```

## 本地轮询一次

```bash
python worker/azure_ocr_worker.py --once
```

## 持续运行

```bash
python worker/azure_ocr_worker.py --poll
```

`--poll` 适用于 Railway Background Worker。若使用 Railway Cron，服务必须在完成工作后退出；当前轮询模式是长期运行模式，不应配置为 Cron。Railway 的 Cron 适合短任务，不能替代持续 Worker。

## 测试

离线解析测试不会调用 Azure，也不会上传任何文件：

```bash
PYTHONPATH=worker python -m unittest discover -s worker -p 'test_*.py'
```

## 当前未包含

Gmail IMAP PIN、MDAC 真实网页自动化、Check Registration、Visit Pass 查询、数据库租约超时恢复和生产级告警仍属于后续阶段。dry-run Worker 仍保留在 `dry_run_worker.py`，用于不接触真实服务的流程测试。
