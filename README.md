# Passport MDAC Desk

Passport MDAC Desk 是一个面向内部业务流程的 **Flutter Android + Supabase + Python Worker** 自动化工作台，用于集中处理护照资料录入、Azure OCR、客户档案、MDAC 注册、Gmail PIN 获取、Registration 查询、Visit Pass 查询、人工审核与业务凭证归档。

当前仓库主分支版本：**v1.0.43+44**。

> 本 README 以当前 `main` 分支代码为准。`docs/` 中保留了项目早期的设计、dry-run、部署与重构记录，其中部分内容属于历史阶段，不应直接视为当前运行状态。

---

## 当前系统定位与架构

```text
                         ┌─────────────────────────┐
                         │      Flutter Android    │
                         │   Passport MDAC Desk    │
                         └────────────┬────────────┘
                                      │
                                      ▼
                         ┌─────────────────────────┐
                         │        Supabase         │
                         │ Auth / DB / Storage     │
                         │ RPC / Queue / Audit     │
                         └───────┬─────────┬───────┘
                                 │         │
                 ┌───────────────┘         └──────────────────┐
                 ▼                                              ▼
      ┌──────────────────────┐                      ┌──────────────────────┐
      │ Railway / Cloud      │                      │ Local Office Worker  │
      │                      │                      │                      │
      │ Azure OCR Worker     │                      │ MDAC Registration    │
      │ Gmail PIN Worker     │                      │ Registration Check   │
      └──────────────────────┘                      │ Visit Pass Check     │
                                                    │ Azure OCR (可选本地)  │
                                                    │ Gmail PIN (可选本地) │
                                                    └──────────────────────┘
```

### 为什么采用云端 + 本地 Worker 双轨架构

1. **规避官方反爬与 IP 封锁**：马来西亚移民局 MDAC 页面及查询接口具有严格的地域与机房 IP 拦截机制（如 Cloudflare/Akamai 挑战）。在本地办公室使用真实宽带 IP 运行浏览器 Worker，可显著降低验证码拦截率。
2. **长任务与无状态分离**：适合云端长期运行的 API 式任务（如 Azure OCR 与 Gmail PIN IMAP 读取）可交由 Railway 托管；而网页端自动化则全部移交本地 Worker 节点。
3. **Supabase 统一调度**：所有任务由 Supabase 队列进行统一派发与 lease 租约加锁，Worker 自身不留存业务状态，执行证据（截图、PDF、日志）均实时回传云端数据库与私有存储桶。

---

## 最新核心功能演进

### 1. 业务配置记忆与账号快速切换 (v1.0.39-v2 / v1.0.43)
- **MDAC 默认业务配置**：联系邮箱自动记忆曾用过的所有历史 Gmail。提供下拉菜单与快捷芯片（ActionChip），点选即可一键填入，支持在菜单中移除失效邮箱。
- **Gmail PIN 默认邮箱设置**：**双重持久化历史 Gmail 账号与对应的 16 位 Google App Password**。卡片顶部提供历史账号选择器与芯片，切换账号时**同时自动带入邮箱与应用密码**，并支持明暗文切换，彻底消除频繁更换配置时翻找复制密码的痛点。

### 2. 移动端窄屏响应式排版与防溢出治理 (v1.0.39)
- **统计过滤栏**：窄屏 (< 640px) 下搜索框与状态筛选按钮自适应分行与横向滑动，杜绝像素溢出。
- **订单卡片重构**：移动端采用多行分层布局（订单头部、客户姓名与状态徽章、护照与行程日期、稳定 Case ID），消除文字挤压。
- **悬浮操作栏**：第一行紧凑统计，第二行横向平滑滚动展示全部操作按钮，彻底消除底部溢出报错。

### 3. Order / Case 绑定加固与批次工作区 (v1.0.40 ~ v1.0.42)
- Worker 任务严格与 `case_id`、`membership_id` 及 `operational_batch_id` 关联，保障批量处理的审计与数据一致性。
- Check Registration 任务异常时具备自动化 Fallback 加固与安全回写。

---

## 本地化部署 Worker 完整指南

本地化部署支持托管全部 **5 大核心 Worker**：

| Worker 名称 | 脚本路径 | 业务职责 | 自动化技术 |
|---|---|---|---|
| **MDAC 自动注册** | `services/mdac-fill-preview/worker.py` | 填报 MDAC 入境卡、人脸防伪校验、生成填报凭证 | Playwright (Chromium) + ddddocr |
| **Check Registration** | `services/registration-check-worker/worker.py` | 核验 MDAC 注册状态并下载官方原版 PDF 凭证 | Playwright (Chromium) + 下载桥接 |
| **Check Visit Pass** | `services/visit-pass-check-worker/worker.py` | 查询入境准证有效记录并截取全景高清表格凭证 | Playwright (Chromium) + 视口自适应 |
| **Azure 护照 OCR** | `worker/azure_ocr_worker.py` | 监听护照图片/PDF 上传并调用 Azure 识别关键字段 | Requests + Azure Document Intelligence |
| **Gmail PIN 抓取** | `services/gmail-pin-worker/worker.py` | 监听官方确认邮件，安全提取 PIN 码写回任务 | IMAP SSL + Supabase Vault 加密流 |

---

### 1. 环境准备

推荐操作系统：**Windows 10/11**、**macOS** 或 **Ubuntu Linux**。

- **Python**：推荐 **Python 3.10 ~ 3.13** 64 位版本。
- **系统包依赖**（Linux 需具备 Chromium 运行依赖库，Windows/macOS 无需额外系统库）。

#### 步骤 1.1：创建并激活 Python 虚拟环境

```bash
# 切换到项目根目录
cd passport-mdac-app

# 创建虚拟环境
python -m venv .venv

# 激活虚拟环境 (Windows PowerShell)
.venv\Scripts\Activate.ps1
# 或 Windows CMD:
.venv\Scripts\activate.bat
# 或 Linux/macOS:
source .venv/bin/activate
```

#### 步骤 1.2：安装 Python 依赖库与 Playwright 浏览器内核

```bash
# 安装基础依赖与网页 Worker 依赖
pip install -r services/mdac-fill-preview/requirements.txt
pip install -r requirements-worker.txt
pip install psutil

# 安装 Playwright 专用 Chromium 内核
playwright install chromium
```

> **提示**：`services/mdac-fill-preview/requirements.txt` 中已包含 `playwright`、`requests`、`ddddocr`、`pillow`，适用于所有浏览器类 Worker。

---

### 2. 环境变量配置

在项目根目录创建 `.env` 文件，或在 `worker/` 下创建 `.env.local`（Worker 启动时会自动按优先级加载）：

```ini
# ==========================================
# 1. Supabase 服务端核心配置 (必填)
# ==========================================
SUPABASE_URL=https://<your-project-id>.supabase.co
# 必须为 service_role key，严禁提交到前端代码仓或公开环境
SUPABASE_SERVICE_ROLE_KEY=eyJh......

# ==========================================
# 2. Azure Document Intelligence 配置 (OCR 必需)
# ==========================================
AZURE_DI_ENDPOINT=https://<your-azure-service>.cognitiveservices.azure.com/
AZURE_DI_KEY=your-azure-document-intelligence-key
OCR_WORKER_ID=local-azure-ocr-worker
OCR_QUEUE_POLL_SECONDS=15
OCR_POLL_SECONDS=2
OCR_REQUEST_TIMEOUT_SECONDS=45

# ==========================================
# 3. 浏览器自动化运行行为控制 (本地推荐配置)
# ==========================================
# 是否直接执行真实提交 (生产环境设为 true；测试设为 false 仅填表预览)
ALLOW_REAL_SUBMIT=true
ALLOW_REAL_REGISTRATION_CHECK=true

# 浏览器是否以无头模式运行 (本地调试排查时可设为 false 观察界面)
HEADLESS=true

# 每次轮询任务间隔 (秒)
POLL_INTERVAL=3
WORKER_LEASE_SECONDS=300
```

> **安全须知**：
> 1. `SUPABASE_SERVICE_ROLE_KEY` 具备数据库高权限，**切勿提交至 Git**；
> 2. Gmail PIN 的邮箱地址和 16 位 App Password 优先从 App 端保存到数据库受保护 Vault，Worker 会通过安全 RPC 自动回读解密，无需在 `.env` 中写死。

---

### 3. 一键启动与运行方式

项目提供了多套成熟的本地运行工具，覆盖不同的办公环境与调试需求：

#### 方式 A：极简黑白呼吸灯管理面板（推荐日常生产使用，极致宁静）

运行统一托管脚本，默认将自动唤起**极简黑白呼吸灯管理窗口**（零外部依赖，基于原生 Python 引擎）：

`ash
python tools/run_all_workers.py
`

- **视觉风格**：沉浸式深邃纯黑背景（#000000）+ 优雅正弦波**白色呼吸灯**（实时反馈系统心跳），彻底告别传统命令行黑框的杂乱刷屏与视觉疲劳；
- **5 大 Worker 状态卡片**：直观展示 MDAC、Registration、Visit Pass、OCR、Gmail PIN 的运行状态与实时心跳；
- **极简日志抽屉**：常规状态下仅展示最新一条动态，点击「展开详细日志」即可无缝查看实时完整流水；
- **心跳自愈与安全控制**：内置 3 秒崩溃自动重连，界面提供「一键重启所有 Worker」及安全退出。

> **提示**：若在纯终端/服务器无桌面环境下运行，只需添加 --cli 参数：python tools/run_all_workers.py --cli，即可进入极简黑底字符看板（同款白色脉冲指示器，无滚动刷屏）。

#### 方式 B：Windows Terminal 独立多标签页模式（推荐排查与观测使用）

若已安装 Windows Terminal，可一键调出 5 个独立命名的标签页，各自独立打印详细日志：

```bash
python tools/launch_wt_workers.py --mode tabs
```

- **5 个专属标签页**：
  - `[Tab 1]` MDAC 自动注册
  - `[Tab 2]` 查 Registration
  - `[Tab 3]` 查 Visit Pass
  - `[Tab 4]` Azure 护照 OCR
  - `[Tab 5]` Gmail PIN 抓取

#### 方式 C：Windows Terminal 分屏网格模式（大屏监控首选）

在单个窗口内将屏幕切分为多个网格面板并实时刷新：

```bash
python tools/launch_wt_workers.py --mode split
```

#### 方式 D：Windows 桌面一键重启批处理

双击运行根目录或 tools 下的脚本：

```cmd
tools\restart_workers.bat
```

- 脚本会自动杀除旧的残留 Python 进程，避免重复抢占数据库 Lease，随后拉起最新环境。

#### 停止所有本地 Worker：

```bash
python tools/stop_workers.py
```

---

## Flutter 开发与构建

### 环境建议
- Flutter 3.24+ (Channel stable)
- Dart 3.5+
- Android SDK (API 34+)
- JDK 21

### 安装依赖
```bash
flutter pub get
```

### 静态分析与测试
```bash
flutter analyze --no-fatal-infos --no-fatal-warnings
flutter test
```

### 编译 Debug APK
```bash
flutter build apk --debug \
  --dart-define=SUPABASE_URL=https://<your-supabase-url> \
  --dart-define=SUPABASE_PUBLISHABLE_KEY=<your-anon-publishable-key>
```

> **注意**：前端 APK **只允许注入** `anon` / `publishable key`，严禁将 `service_role key` 编译入客户端。

---

## 核心开发与设计原则

1. **状态一致性**：Supabase 是唯一的业务状态源；Worker 仅作为无状态执行器；
2. **严防误判**：网络超时、页面变动或验证码阻断时，严格判定为 `NEEDS_REVIEW`（人工复核）或 `FAILED`，严禁未经验证标记为 `SUCCEEDED`；
3. **安全凭据隔离**：加密凭证由 Supabase Vault 保存，App 不回读明文密码，Worker 按需解密调用；
4. **证据归档闭环**：官方查询凭证统一写入私有 Storage 并在客户主档案中保留唯一有效证据，避免历史脏记录混淆。

---

## 仓库信息

- **GitHub 仓库**：`https://github.com/mm7768/passport-mdac-app`
- **默认分支**：`main`
- **维护人员**：`mm7768`
