# Passport MDAC Desk

Passport MDAC Desk 是一套专为旅行社、签证服务机构及跨境业务团队打造的 **Flutter Android 移动工作台 + Supabase 云端调度 + Python 办公室桌面高并发 Worker** 自动化系统，实现护照资料极速采集、智能识别、MDAC 入境卡全自动批量填报、Gmail 验证码提取、官方注册状态核验、原版 PDF 凭证下载与入境准证（Visit Pass）核验的全流程闭环。

当前系统版本：**v1.0.44**（Worker 核心引擎：`mdac-auto-worker-4`、`registration-check-auto-2`、`visit-pass-check-auto-2`、`azure-ocr-2-concurrent`、`gmail-pin-4`）。

---

## 目录

- [一、 系统整体架构与技术选型](#一-系统整体架构与技术选型)
- [二、 5 大核心 Worker 功能与技术特性](#二-5-大核心-worker-功能与技术特性)
- [三、 办公室桌面 Worker 超详细安装与运行教程](#三-办公室桌面-worker-超详细安装与运行教程)
  - [3.1 环境要求与前置准备](#31-环境要求与前置准备)
  - [3.2 步骤一：拉取/准备代码仓库](#32-步骤一拉取准备代码仓库)
  - [3.3 步骤二：创建并激活 Python 虚拟环境](#33-步骤二创建并激活-python-虚拟环境)
  - [3.4 步骤三：安装项目依赖与 Playwright 浏览器内核](#34-步骤三安装项目依赖与-playwright-浏览器内核)
  - [3.5 步骤四：环境变量配置 (.env.local)](#35-步骤四环境变量配置-envlocal)
  - [3.6 步骤五：启动与管理 Worker（5 种运行模式）](#36-步骤五启动与管理-worker5-种运行模式)
  - [3.7 步骤六：安全退出与停止 Worker](#37-步骤六安全退出与停止-worker)
- [四、 常见故障排查与运维指南 (FAQ)](#四-常见故障排查与运维指南-faq)
- [五、 Flutter Android 移动端构建指南](#五-flutter-android-移动端构建指南)
- [六、 核心安全与设计准则](#六-核心安全与设计准则)

---

## 一、 系统整体架构与技术选型

系统采用 **云端无状态调度 + 本地办公室真实 IP 高并发执行** 的混合双轨架构：

```text
                     ┌────────────────────────────────────────┐
                     │           Flutter Android App          │
                     │  (批次录入 / 智能切片 / 进度看板 / 凭证预览) │
                     └───────────────────┬────────────────────┘
                                         │
                                         ▼ HTTPS / WSS
                     ┌────────────────────────────────────────┐
                     │          Supabase 云端基础设施          │
                     │  Postgres DB / RLS / Auth / Storage    │
                     │  队列原子锁 (FOR UPDATE SKIP LOCKED)   │
                     │  安全密凭托管 (Supabase Vault)         │
                     └───────────────────┬────────────────────┘
                                         │
             ┌───────────────────────────┴───────────────────────────┐
             ▼                                                       ▼
┌───────────────────────────────┐               ┌───────────────────────────────────────┐
│     Railway / 云端可选服务     │               │        办公室桌面 Worker 集群          │
│                               │               │        (真实宽带 IP / 防风控)          │
│ • Azure OCR 备用托管          │               │                                       │
│ • Gmail PIN 抓取备用托管      │               │ 1. MDAC 自动注册 (4 并发四象限监控)    │
└───────────────────────────────┘               │ 2. Check Registration (4 并发 3 级 PDF)│
                                                │ 3. Check Visit Pass (4 并发四象限监控) │
                                                │ 4. Azure OCR 护照识别 (3 线程并发)    │
                                                │ 5. Gmail PIN 自动提取 (IMAP SSL 流)   │
                                                │                                       │
                                                │ • worker_gui.py 极简黑白呼吸灯管理台   │
                                                └───────────────────────────────────────┘
```

### 为什么采用本地办公室 Worker 模式？
1. **规避官方机房 IP 封锁与风控挑战**：马来西亚移民局官网及 MDAC 入口对公有云机房（AWS、GCP、Cloudflare 等）部署了极其严苛的 IP 黑名单和人机挑战机制。在本地办公室使用真实民用宽带 IP 调度浏览器内核，能大幅提升访问顺畅度，将拦截率降至最低。
2. **极速高并发与大屏直观监控**：采用 4 象限网格分屏（`768 × 412`），多窗口并行处理，填表、滑块拖拽、官方出码一览无余，同时享受本地硬件对浏览器渲染的极致加速。
3. **租约防崩溃设计**：每个任务批次及子项均携带租期（Lease）。Worker 维持后台独立心跳，若遇断电或崩溃，超时任务会自动回流队列，绝无死锁或漏项。

---

## 二、 5 大核心 Worker 功能与技术特性

### 1. MDAC 自动填报与注册 Worker (`services/mdac-fill-preview/worker.py`)
- **4 并发多线程执行**：基于 `threading.Thread` + 独立 `asyncio` 事件循环，单批次处理吞吐量提升 3.5~4 倍（30 人团队仅需 3~4 分钟）。
- **2×2 四象限桌面大屏布局**：根据 Windows 桌面实际工作区动态计算，窗口自动铺满四角：
  - 槽位 1（左上）：`0, 0` (`768 × 412`)
  - 槽位 2（右上）：`768, 0` (`768 × 412`)
  - 槽位 3（左下）：`0, 412` (`768 × 412`)
  - 槽位 4（右下）：`768, 412` (`768 × 412`)
- **2.0s 阶梯式错峰冷启动**：槽位 1~4 依次间隔 2 秒启动，平滑流量尖峰，消除并发撞击官方 WAF 导致的 504 Gateway Timeout。
- **DOM 极速批量评估**：将 20+ 个个人与行程字段比对、非法控件扫描及提交按钮状态检查整合为单次 JavaScript evaluate 调用，将校验延迟由秒级降至 10ms。
- **自动滑块验证码求解器**：内置 `slider_solver.py`（基于 Canvas 像素匹配与拟人化加减速轨迹算法），自动完成官方拼图滑块挑战。
- **槽位级就地快速容错重试**：遇到瞬态网络超时或滑块偶发偏位，自动在槽位内重建页面重试 1 次（最多 2 次尝试），减少 80% 无谓的人工介入。
- **防重判智能识别**：除识别 `SUCCESSFULLY REGISTERED` 外，自动识别官方返回的 `ALREADY REGISTERED` / `RECORD ALREADY EXISTS`（已登记），直接提取既有登记号并以成功归档。
- **独立保活心跳线程**：`MDACBatchHB` 每 15 秒同步一次 `BUSY` 租约，多槽位并发期间批次永不过期。

### 2. Registration 核验与 PDF 下载 Worker (`services/registration-check-worker/worker.py`)
- **4 并发多线程执行** + **2×2 四象限桌面大屏布局**（每窗 `768 × 412`）。
- **1.5s 阶梯式错峰冷启动**：平滑建立多路 TCP 连接。
- **3 级弹性原版 MDAC Slip PDF 抓取引擎 (3-Tier Resilient PDF Pipeline)**：
  - **Tier 1 (页面内存直接 Fetch)**：在已认证页面上下文中执行原生 `fetch('/mdac/register?printSlip')`，将 PDF 二进制数据直接转为 Base64 读取。耗时仅 ~300ms，无弹窗阻断，零磁盘 I/O 开销。
  - **Tier 2 (Playwright Session API 请求)**：使用浏览器上下文的 `context.request.post()` 携带已建立的 Session Cookie 直接拉取 PDF 二进制流。
  - **Tier 3 (DOM 下载事件兜底拦截)**：点击页面打印链接，使用 `page.expect_download(timeout=15000)` 捕获浏览器下载事件。
  - **Tier 4 (存证保障降级截图)**：若官方系统未生成 PDF 文件，自动截取高清全屏凭证，保留提取到的 `trip_id`。
- **动态超时自适应**：45 秒基础等待 + 15 秒动态加载宽限期，适应官方高峰期网络延迟。

### 3. Visit Pass 入境准证核验 Worker (`services/visit-pass-check-worker/worker.py`)
- **4 并发多线程执行** + **2×2 四象限桌面大屏布局**（每窗 `768 × 412`）。
- **1.5s 阶梯式错峰启动** + **槽位级就地容错重试**（最多 2 次尝试）。
- **全景自适应截屏**：动态计算页面完整表格高度，规避 Playwright 视口裁剪，完整截取入境盖章记录与有效期凭据。
- **Fail-Closed 严谨判别**：无记录或被阻断时安全标记为 `NEEDS_REVIEW`，绝不假定成功。

### 4. Azure 护照 OCR Worker (`worker/azure_ocr_worker.py`)
- **3 线程并发处理队列**（`ThreadPoolExecutor(3)`），秒级吞吐。
- 调用 Azure Document Intelligence（prebuilt-idDocument 模型），精准识别全球各版本护照机读码（MRZ）、中文拼音姓名、护照号、国籍、出生日期、签发日期与到期日期。
- 自动格式归一化并回写 `customer_profiles`。

### 5. Gmail PIN 自动抓取 Worker (`services/gmail-pin-worker/worker.py`)
- 采用 IMAP SSL 安全长连接，实时监听官方 `noreply@imi.gov.my` 邮件。
- 采用 Supabase Vault 加密流，自动解密使用 App 提交的 16 位 Google App Password。
- 正则提取 6 位数字验证码 PIN 并通过服务级 RPC 安全回写，作为 Check Registration 的必要输入。

---

## 三、 办公室桌面 Worker 超详细安装与运行教程

本教程适用于在本地办公室 Windows 电脑（或云端 Windows 实例）上从零搭建运行环境。

### 3.1 环境要求与前置准备

1. **操作系统**：Windows 10 / Windows 11 (64 位)（推荐），或 Windows Server 2019+。
2. **Python 版本**：**Python 3.10 ~ 3.12 (64-bit)**（建议 3.11/3.12；安装时务必勾选 **"Add python.exe to PATH"**）。
3. **网络环境**：普通的办公室宽带或民用光纤（具备稳定访问马来西亚官网 `https://imigresen-online.imi.gov.my` 的网络连接）。

> [!IMPORTANT]
> 请勿使用机房公开代理或数据中心 IP 运行网页自动化 Worker，否则极易触发官方 Cloudflare 5秒盾或验证码拦截死循环。

---

### 3.2 步骤一：拉取/准备代码仓库

在本地工作目录打开 PowerShell 或 CMD：

```powershell
# 克隆代码仓库 (如已有代码目录可直接 cd 进入)
git clone https://github.com/mm7768/passport-mdac-app.git
cd passport-mdac-app
```

---

### 3.3 步骤二：创建并激活 Python 虚拟环境

使用虚拟环境隔离依赖，避免与其他 Python 项目冲突：

```powershell
# 1. 创建独立的 .venv 虚拟环境
python -m venv .venv

# 2. 激活虚拟环境 (Windows PowerShell)
.\.venv\Scripts\Activate.ps1

# 如果 PowerShell 提示脚本执行受限，可先执行：Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned
# 如果使用 CMD 命令行，请执行：
# .\.venv\Scripts\activate.bat
```

激活成功后，命令行提示符前会显示 `(.venv)` 标识。

---

### 3.4 步骤三：安装项目依赖与 Playwright 浏览器内核

依次安装各 Worker 所需的核心依赖包及 Chromium 浏览器内核：

```powershell
# 1. 升级 pip
python -m pip install --upgrade pip

# 2. 安装全部 Worker 所需依赖
pip install -r services/mdac-fill-preview/requirements.txt
pip install -r requirements-worker.txt
pip install psutil requests ddddocr pillow

# 3. 安装 Playwright 专用 Chromium 浏览器内核 (必须执行)
playwright install chromium
```

> [!TIP]
> `ddddocr` 安装时如遇网络慢，可加国内镜像源，例如：`pip install ddddocr -i https://pypi.tuna.tsinghua.edu.cn/simple`。

---

### 3.5 步骤四：环境变量配置 (.env.local)

系统支持根目录统一配置或各 Worker 独立配置。在运行前，请在项目根目录（或各服务的根目录下）创建 `.env.local` 文件：

#### 核心配置文件：`services/mdac-fill-preview/.env.local`
```ini
# ========================================================
# 1. Supabase 服务端凭据 (必须为具备管理权限的 service_role_key)
# ========================================================
SUPABASE_URL=https://<your-project-id>.supabase.co
SUPABASE_SERVICE_ROLE_KEY=your-supabase-service-role-key-here

# ========================================================
# 2. MDAC 注册 Worker 核心控制
# ========================================================
MDAC_WORKER_ID=office-worker-desktop
MDAC_EXECUTION_MODE=AUTO_SUBMIT
ALLOW_REAL_SUBMIT=true
MDAC_URL=https://imigresen-online.imi.gov.my/mdac/main?registerMain
MDAC_POLL_SECONDS=15
MDAC_LEASE_SECONDS=900
MDAC_MAX_ATTEMPTS=5
SUPABASE_REQUEST_TIMEOUT_SECONDS=30
MDAC_PAGE_TIMEOUT_MS=60000

# 桌面浏览器显示设置 (false 表示前台可见窗口，可直观监控；true 表示后台静默)
MDAC_HEADLESS=false

# 性能与容错参数 (推荐值)
MDAC_CONCURRENCY=4
MDAC_SLOT_STAGGER_SECONDS=2.0
MDAC_LOCAL_ATTEMPTS=2

# 凭据截图私有桶
MDAC_SCREENSHOT_BUCKET=passport-documents
MDAC_SCREENSHOT_PREFIX=mdac-previews
LOG_LEVEL=INFO
```

#### 检查登记配置文件：`services/registration-check-worker/.env.local`
```ini
SUPABASE_URL=https://<your-project-id>.supabase.co
SUPABASE_SERVICE_ROLE_KEY=your-supabase-service-role-key-here
REGISTRATION_CHECK_WORKER_ID=office-reg-check-desktop
REGISTRATION_CHECK_MODE=AUTO_CHECK
ALLOW_REAL_SUBMIT=true
REGISTRATION_CHECK_HEADLESS=false
REGISTRATION_CHECK_CONCURRENCY=4
REGISTRATION_CHECK_SLOT_STAGGER_SECONDS=1.5
REGISTRATION_CHECK_LOCAL_ATTEMPTS=2
REGISTRATION_CHECK_POLL_SECONDS=15
REGISTRATION_CHECK_LEASE_SECONDS=900
REGISTRATION_CHECK_MAX_ATTEMPTS=5
```

#### 检查准证配置文件：`services/visit-pass-check-worker/.env.local`
```ini
SUPABASE_URL=https://<your-project-id>.supabase.co
SUPABASE_SERVICE_ROLE_KEY=your-supabase-service-role-key-here
VISIT_PASS_CHECK_WORKER_ID=office-visit-pass-desktop
VISIT_PASS_CHECK_MODE=AUTO_CHECK
ALLOW_REAL_SUBMIT=true
VISIT_PASS_CHECK_HEADLESS=false
VISIT_PASS_CONCURRENCY=4
VISIT_PASS_SLOT_STAGGER_SECONDS=1.5
VISIT_PASS_LOCAL_ATTEMPTS=2
VISIT_PASS_CHECK_POLL_SECONDS=15
```

#### Azure OCR 配置文件：`worker/.env.local`
```ini
SUPABASE_URL=https://<your-project-id>.supabase.co
SUPABASE_SERVICE_ROLE_KEY=your-supabase-service-role-key-here
AZURE_DI_ENDPOINT=https://<your-azure-resource>.cognitiveservices.azure.com/
AZURE_DI_KEY=your-azure-key
OCR_WORKER_ID=azure-ocr-worker
OCR_CONCURRENCY=3
```

---

### 3.6 步骤五：启动与管理 Worker（5 种运行模式）

项目自带成熟的管理控制台和启动工具，支持按需选用：

#### 模式 1：极简黑白呼吸灯桌面控制面板 (推荐日常使用 ★★★★★)
无需第三方软件，双击运行或在虚拟环境中输入命令：

```powershell
python tools/worker_gui.py
```

* **界面特性**：
  * **沉浸黑深邃美学** + **实时白色呼吸灯脉冲**：反馈系统整体心跳与健康状态。
  * **5 大 Worker 专属状态卡片**：实时显示 MDAC、Registration Check、Visit Pass、OCR、Gmail PIN 的在线状态（ONLINE / BUSY / OFFLINE）、处理量及最新活动时间。
  * **一键控制**：提供「全部启动」、「一键重启」与「安全停止」操作按钮。
  * **实时折叠日志抽屉**：常规下仅显示最新动态，展开可查看完整流水日志。

---

#### 模式 2：Windows Terminal 5 独立多标签页模式 (排查与多日志监控首选)
如果安装了 Windows Terminal，输入：

```powershell
python tools/launch_wt_workers.py --mode tabs
```
系统将自动在一个终端窗口内拉起 5 个独立命名的 Tab 标签页，各自打印对应 Worker 的调试流水。

---

#### 模式 3：Windows Terminal 分屏网格监控模式
```powershell
python tools/launch_wt_workers.py --mode split
```
在单一屏幕内自动切分为多个实时监控小窗，适合多显示器或监控大屏常驻。

---

#### 模式 4：无 GUI 字符控制台托管模式 (适用于 Windows 服务或后台脚本)
```powershell
python tools/run_all_workers.py --cli
```
在原生命令行终端以字符看板的形式实时展示 5 个 Worker 的运行脉冲，无烦人的刷屏日志。

---

#### 模式 5：单 Worker 手动独立启动 (本地开发或单项排查)
若需对某一个 Worker 进行独立断点调试：

```powershell
# 独立调试 MDAC 注册服务
python services/mdac-fill-preview/worker.py --poll

# 独立调试 Check Registration
python services/registration-check-worker/worker.py --poll

# 独立调试 Check Visit Pass
python services/visit-pass-check-worker/worker.py --poll

# 独立调试 Azure OCR
python worker/azure_ocr_worker.py

# 独立调试 Gmail PIN
python services/gmail-pin-worker/worker.py --poll
```

---

### 3.7 步骤六：安全退出与停止 Worker

任何时候需要完全停止所有正在运行的后台 Worker 时，请运行统一清理脚本：

```powershell
python tools/stop_workers.py
```
该脚本会安全通知各 Worker 进程注销心跳，关闭打开的浏览器进程，释放数据库租约，避免任务死锁。

---

## 四、 常见故障排查与运维指南 (FAQ)

### Q1: 运行提示 `缺少环境变量：SUPABASE_SERVICE_ROLE_KEY`
* **原因**：找不到 `.env.local` 文件或该文件放置路径不正确。
* **解决办法**：确认在各 Worker 所在目录（如 `services/mdac-fill-preview/`）或项目根目录下创建了 `.env.local`，并且其中包含了 `SUPABASE_SERVICE_ROLE_KEY` 与 `SUPABASE_URL`。

### Q2: 浏览器打开后提示 `Playwright executable doesn't exist`
* **原因**：未安装 Playwright 对应的 Chromium 驱动内核。
* **解决办法**：在虚拟环境中执行 `playwright install chromium`。

### Q3: 官方提交后提示 `RESULT_UNKNOWN` 怎么办？
* **原因**：马来西亚官方系统在深夜或早高峰维护，提交后未能在 20 秒内渲染出结果页。
* **处理机制**：系统已内置防重与局部就地重试；若重试 2 次后仍无响应，会自动标记为 `NEEDS_REVIEW`（人工复核）。此时可在 App 端点击“人工核对”，系统会自动比对登记号，严禁盲目短时间多次重复提交。

### Q4: 4 个浏览器窗口排列重叠，如何调整？
* **解决办法**：系统默认会根据显示器真实工作区计算四象限坐标。如果使用了缩放（如 125% 或 150%），可以在 `.env.local` 中直接指定槽位绝对坐标与尺寸：
  ```ini
  MDAC_SLOT_1_POSITION=0,0
  MDAC_SLOT_1_SIZE=768,412
  MDAC_SLOT_2_POSITION=768,0
  MDAC_SLOT_2_SIZE=768,412
  ```

---

## 五、 Flutter Android 移动端构建指南

移动端基于 Flutter 3.24+ 构建，为操作员提供集中作业、批次导入、客户档案管理及进度展示。

### 依赖与构建
```bash
# 获取依赖
flutter pub get

# 静态语法与代码规范分析
flutter analyze --no-fatal-infos --no-fatal-warnings

# 执行测试用例
flutter test

# 编译 Debug APK
flutter build apk --debug \
  --dart-define=SUPABASE_URL=https://<your-supabase-url> \
  --dart-define=SUPABASE_PUBLISHABLE_KEY=<your-anon-publishable-key>
```

> [!CAUTION]
> 移动端 APK 仅允许注入公开的 `anon/publishable key`，严禁在前端打包代码中编译写入 `service_role key`。

---

## 六、 核心安全与设计准则

1. **状态唯一真理源 (Single Source of Truth)**：所有业务状态（`QUEUED`、`CLAIMED`、`RUNNING`、`SUCCEEDED`、`NEEDS_REVIEW`、`FAILED`）均以 Supabase 数据库为主，Worker 仅为无状态执行器。
2. **严防误判准则 (Fail-Closed Policy)**：遇到不可判定的页面白屏、跳转未知 URL、滑块阻断时，严格写回 `NEEDS_REVIEW`，杜绝一切未经验证伪造成功的行为。
3. **安全凭据三级隔离**：
   - 客户端仅使用受限 RLS `anon` Key。
   - 服务端仅在本地 Worker 读取 `service_role` 访问队列。
   - 敏感 Gmail 授权密码统一托管在 Supabase Vault，前后端均无明文存储。
4. **证据归档闭环**：官方回执原版 PDF、全景截图等原始凭证统一上载至私有隔离存储桶，并在主档案中建立唯一证据链，确保可审计、可追溯。

---

## 仓库信息

- **GitHub 代码仓**：[https://github.com/mm7768/passport-mdac-app](https://github.com/mm7768/passport-mdac-app)
- **主开发分支**：`main`
- **维护机构**：Passport MDAC Desk Team
