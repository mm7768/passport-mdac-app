# Passport MDAC Desk

Passport MDAC Desk 是按 `passport-mdac-app-spec` 实现的 Flutter Android 护照与马来西亚数字入境卡（MDAC）自动化工作台。它将护照拍摄/上传、Azure 智能 OCR、客户档案主数据库、MDAC 自动填报提交和 Gmail 官方 PIN 码自动收取整合在同一个工作区中。

当前系统采用 **“Railway 云端 API 服务 + 本地办公室 Worker 执行端”** 的双轨协同架构，彻底解决了云服务器机房 IP 容易被马来西亚政府官网（WAF）拦截的问题，并实现了批量申报 100% 成功闭环。

---

## 架构分工：云端与本地协同模式

```text
[ 手机端 Flutter App ]
  ├── 拍照/上传护照 ────> [ Supabase Storage ] ──> [ Railway 云端: Azure OCR Worker ] ──> 自动识别建档
  │
  ├── 触发 MDAC 注册 ───> [ Supabase 任务队列 ] ──> [ 本地办公室 Worker: MDAC Playwright ] ──> 官方真实申报提交
  │                                                                                  │ (真实宽带 IP / 智能滑块)
  │                                                                                  ↓
  └── 触发 PIN 获取 ────> [ Supabase 任务队列 ] ──> [ Railway 云端: Gmail PIN Worker ] ──> 提取官方邮件 8 位 PIN
```

### 1. Railway 云端服务（极轻量，24小时全天候在线，$5 套餐完全足额覆盖）
* **Azure 护照 OCR Worker (`worker/azure_ocr_worker.py`)**：
  * 手机端拍照或上传 JPG/PNG/PDF 后，云端自动调用微软 Azure AI（Document Intelligence）进行护照解析。
  * 无论本地电脑是否开机，手机端均可随时录入客户并秒级出结果。
* **Gmail PIN 码自动收取 Worker (`services/gmail-pin-worker/`)**：
  * 静默连接 Gmail IMAP 服务器，检索来自 `mdac@imi.gov.my` 的申报确认信。
  * 基于客户护照号精准一对一提取 8 位 PIN 码并写回数据库 `email_pin_records` 表。
  * 支持 HTML 表格跨行排版智能解析与快照凭证自动容错回退。

### 2. 本地办公室 Worker（真实宽带 IP，专职负责对抗官网与滑块验证）
* **MDAC 自动填报提交 Worker (`services/mdac-fill-preview/`)**：
  * 专职负责马来西亚移民局官网（`https://imigresen-online.imi.gov.my`）的申报流程。
  * **防封机制**：使用本地办公室/住宅真实宽带 IP，注入真实 Windows Chrome 指纹（移除了 `navigator.webdriver` 标志），完美避开政府防火墙与 Cloudflare 拦截。
  * **智能过滑块**：内置自动定位与人手拟真速度拖动算法（~1.5 秒），并具备 15 秒人工实时干预兜底。
* **Check Registration / Check Visit Pass Worker (`services/registration-check-worker/` 等)**：
  * 查询申报进度与查验下载通行证。

---

## 本地办公室 Worker 启动指南

在本地 Windows 电脑上运行极为轻量，空闲时不启动浏览器，内存占用仅约 30MB。

### 快速一键启动
双击桌面的 **`启动办公室Worker.bat`**（或项目根目录下的同名文件）即可启动：
* 自动检测 Python 环境与依赖；
* 自动加载 `services/mdac-fill-preview/.env.local` 中的安全凭据；
* 启动监听循环（`MDAC_EXECUTION_MODE=AUTO_SUBMIT`，`ALLOW_REAL_SUBMIT=true`），等待手机 App 下达任务。

---

## 移动端 App 功能与人工介入流程

### 1. Flutter 运行与调试
需要 Flutter stable、Dart、Android SDK 和 JDK 21。
```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --debug \
  --dart-define=SUPABASE_URL=https://xdmcxhvdqsbcqedfprcy.supabase.co \
  --dart-define=SUPABASE_PUBLISHABLE_KEY=你的_sb_publishable_key
```

### 2. 醒目的人工介入与审核入口 (`lib/main.dart` & `lib/mdac_human_review.dart`)
* **移动端整行高亮按钮**：在手机端任务列表中，若批次内存在未成功、滑块需要人工核对或录入错误的客户项，卡片底部会直接展示紫色实体按钮：
  > 🟣 **`[ 👆 人工介入处理 / 查看待审核项 ]`**
* **内置人工审核页面**：可直接在 App 内调起官方页面并加载客户资料，人工完成特殊验证后点击提交。

---

## 业务配置与安全设计

1. **业务默认配置 (`mdac_settings`)**：
   * 申报所需的企业邮箱、境外联系电话、交通方式、入境口岸、住宿类型、在马地址、邮编等，均可在手机 App 设置页中统一编辑与保存。
   * 发起批次时自动拍摄不可变快照，后续配置变动不影响已在队列中的任务。
2. **Gmail 邮箱与应用密码安全 (`private.gmail_credentials` & Supabase Vault)**：
   * Gmail App Password 由 App 客户端通过安全加密 RPC 直接存入 Supabase Vault，不会以明文暴露在前端或日志中。
3. **零明文日志泄露**：
   * 护照号、PIN 码及邮件全文均有严格的脱敏和日志过滤机制，确保符合数据合规要求。

---

## 目录结构

| 路径 | 用途 |
|---|---|
| `lib/main.dart` | Flutter 界面、任务流管理、人工介入按钮与弹窗交互 |
| `lib/supabase_gateway.dart` | Supabase 认证、客户 CRUD、Storage 与 RPC 批次网关 |
| `lib/mdac_human_review.dart` | MDAC 人工介入 WebView 审核与补提页面 |
| `services/mdac-fill-preview/` | 本地办公室 MDAC 真实申报 Worker（Playwright + 智能滑块） |
| `services/gmail-pin-worker/` | 云端 Gmail 官方 PIN 码自动抓取 Worker |
| `services/registration-check-worker/` | Check Registration 填表与结果查验 Worker |
| `services/visit-pass-check-worker/` | Check Visit Pass 通行证查验与下载 Worker |
| `worker/azure_ocr_worker.py` | 微软 Azure Document Intelligence 护照 OCR Worker |
| `启动办公室Worker.bat` | 本地 Worker 一键无痛启动批处理脚本 |
| `railway.toml` | Railway 云端轻量服务部署与健康检查策略 |

---

## 端到端实测验证（2026-09-08）

* **30 人大团 MDAC 申报**：批次 `e9cef4cb-6fd3-4447-aa88-e927e608cf38` 实现 **30/30 完成 · 30 成功 · 0 失败**，全部顺利拿到移民局官方确认。
* **30 人 Gmail PIN 抓取**：批次 `b89882d0-fc7c-4c20-bd01-0333cde763f9` 实现 **30/30 完成 · 30 成功 · 0 失败**，全部官方 8 位 PIN 码精准入库关联。\n