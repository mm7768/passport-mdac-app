# Azure Document Intelligence 身份文件模型基线

## 官方模型

使用 Document Intelligence v4.0 GA 的预建身份文件模型 `prebuilt-idDocument`，API 版本为 `2024-11-30`。官方说明该模型支持全球护照的个人资料页，并返回结构化 JSON。

## 关键返回字段

- `DocumentNumber`: 护照号码
- `FirstName`: 名
- `LastName`: 姓
- `DateOfBirth`: YYYY-MM-DD
- `DateOfExpiration`: YYYY-MM-DD
- `Nationality`: ISO 3166 国籍代码
- `Sex`: M/F/X
- `MachineReadableZone`: MRZ
- `DocumentType`: passport

## 文件限制

- 图片：JPEG/JPG、PNG、BMP、TIFF、HEIF
- PDF/TIFF：付费层最多 2,000 页；F0 免费层只处理前 2 页
- 文件大小：付费层 500 MB；F0 4 MB
- 图片尺寸：50x50 至 10,000x10,000 px
- 建议每个文件只放一张清晰的护照个人资料页

## 安全原则

Azure Endpoint 和 Key 只进入办公室 Python Worker 的环境变量或受保护 Secret；不进入 Flutter APK。Worker 从 Supabase 私有 Storage 下载文件，调用 Azure，再把原始 JSON 和标准化字段写回 Supabase。

## 结果处理原则

Azure 返回的日期通常为 ISO `YYYY-MM-DD`，写入 `ocr_results.extracted_data` 时保留 ISO 原值并同时生成应用显示用的 `DD/MM/YYYY`。`Sex` 映射为应用的 `男`/`女`；`X` 或无法映射的值必须进入 `REVIEW_REQUIRED`。MRZ、护照号码、日期缺失或解析冲突也必须进入人工审核，不可自动建档。

来源：
- https://learn.microsoft.com/en-us/azure/ai-services/document-intelligence/prebuilt/id-document?view=doc-intel-4.0.0
- https://learn.microsoft.com/en-us/azure/ai-services/document-intelligence/how-to-guides/use-sdk-rest-api?view=doc-intel-4.0.0

记录日期：2026-08-23

作者：Manus AI

---

本文件只记录实现基线，不包含任何 Azure Key、Supabase Secret 或护照资料。

板块 | 决定
--- | ---
OCR 执行位置 | Azure 云端
调用层 | Python Worker
手机端职责 | 上传、显示进度、人工审核
API Key 位置 | Worker 环境变量或 Secret Manager
默认审核策略 | 低置信度/字段缺失/MRZ冲突进入 REVIEW_REQUIRED

> 重要：F0 的免费页数、文件大小、地区定价和限额以 Azure 当前账号页面为准；正式接入前需在目标 Azure Region 的定价页确认。
