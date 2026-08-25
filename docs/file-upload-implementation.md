# 手机端文件上传实现说明

## 当前闭环

已实现 Flutter Android 端选择单个 JPG、JPEG、PNG 或 PDF 文件，限制单个文件不超过 15 MB。真实 Supabase 模式下，文件上传到私有 `passport-documents` bucket 的用户隔离路径：`{user_id}/ocr/{timestamp}_{safe_file_name}`。

文件上传成功后，会在 `public.ocr_batches` 建立 `UPLOADED` 批次记录，并将原始文件名、MIME 类型、文件大小和 SHA-256 内容指纹写入 `metadata`。文件内容本身仍保存在私有 Storage，不公开生成永久 URL。

## 状态与失败处理

手机端显示上传中、已上传和上传失败状态。失败记录保留当前会话内的字节数据，可以点击“重试”；应用重启后，云端已上传批次会恢复显示，但失败记录若没有已保存文件内容则需要重新选择。

内容指纹在客户端阻止同一会话重复提交，并在 Supabase 上通过 `ocr_batches_uploaded_content_hash_uq` 唯一索引保护跨设备重复提交。失败批次不占用唯一索引，因此允许重新提交。

## OCR 边界

本阶段只完成文件上传和 OCR 批次记录，尚未调用 Azure、Mindee、腾讯云或其他 OCR 供应商。下一阶段在受保护的 Worker/服务端中读取私有 Storage 文件，再调用选定的 OCR API，写入 `ocr_results.raw_result` 与 `ocr_results.extracted_data`，最后将批次状态推进到 `REVIEW_REQUIRED`。

## 后端迁移

已应用：

- `20260823_ocr_batch_metadata.sql`：增加 `ocr_batches.metadata` JSONB 字段。
- `20260823_ocr_batch_content_hash_unique.sql`：增加内容指纹唯一索引。

## 安全边界

OCR API Key 不进入 APK。客户端只使用 Supabase Publishable Key 和认证会话；真实 OCR 调用、原始护照文件读取和供应商 API Key 应放在办公室 Worker 或受保护服务端。生产环境还应配置 Storage 生命周期、访问审计、错误日志脱敏和 OCR 供应商数据保留策略。
