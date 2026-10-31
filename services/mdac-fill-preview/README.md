# MDAC Registration Worker (MDAC 自动注册服务)

本服务是 Passport MDAC Desk 的核心自动化模块之一。它基于 Python + Playwright Chromium 打开马来西亚移民局 MDAC 官方在线登记系统（`https://imigresen-online.imi.gov.my/mdac/main?registerMain`），自动领取任务、高速填写旅客身份与行程数据、解决官方拼图滑块验证码、完成官方提交并提取注册凭据。

---

## 核心架构与特性

1. **4 并发多线程槽位（4 Concurrency Slots）**：
   - 默认开启 4 个并发工作槽位（`MDAC_CONCURRENCY=4`），每个槽位持有独立的 Chromium 浏览器进程与独立 `asyncio` 事件循环。
   - 吞吐量比单线程模式提升约 3.5~4 倍，30 人团队仅需 3~4 分钟。

2. **2×2 四象限桌面大屏布局**：
   - 运行时自动检测 Windows 桌面工作区（排除任务栏），将屏幕均分为四个象限窗口（每窗 `768 × 412`）：
     - **Slot 1**（左上角）：`0, 0`
     - **Slot 2**（右上角）：`768, 0`
     - **Slot 3**（左下角）：`0, 412`
     - **Slot 4**（右下角）：`768, 412`
   - 各槽位窗口独立打开，填表、滑块拖拽与官方出码一览无余。

3. **2.0s 阶梯式错峰冷启动（Staggered Start）**：
   - 槽位间按 2.0 秒递增启动（`MDAC_SLOT_STAGGER_SECONDS=2.0`），平滑建立连接，彻底避免并发撞击官方 WAF 导致的 504 Gateway Timeout 或 TCP 丢包。

4. **DOM 极速单次评估（Fast DOM Batch Eval）**：
   - 20+ 个个人与行程字段的回读比对、非法控件扫描及提交按钮状态检查整合为单次 JavaScript evaluate 调用，将校验延迟由秒级降至 10ms。

5. **槽位级就地快速重试（In-Worker Local Retry）**：
   - 内置 `MDAC_LOCAL_ATTEMPTS=2`。遇到滑块自动识别瞬态偏位（`SLIDER_SOLVER_FAILED`）、页面操作超时（`PAGE_TIMEOUT`）或官方网关响应异常，槽位在内部自动重建独立 Page 并快速重试 1 次，成功后直接提交。

6. **防重判智能识别**：
   - 除精准匹配 `SUCCESSFULLY REGISTERED.` 提取 Registration No. 外，还能自动捕获官方提示的 `ALREADY REGISTERED` / `RECORD ALREADY EXISTS`（已登记），直接提取既有登记号以成功状态归档。

7. **独立保活心跳线程（MDACBatchHB）**：
   - 批次执行期间由独立后台守护线程每 15 秒同步一次 `BUSY` 租约，多槽位并发期间批次永不过期。

---

## 环境变量配置 (`.env.local`)

```ini
SUPABASE_URL=https://<your-project-id>.supabase.co
SUPABASE_SERVICE_ROLE_KEY=your-supabase-service-role-key-here
MDAC_WORKER_ID=office-worker-desktop
MDAC_EXECUTION_MODE=AUTO_SUBMIT
ALLOW_REAL_SUBMIT=true
MDAC_URL=https://imigresen-online.imi.gov.my/mdac/main?registerMain
MDAC_POLL_SECONDS=15
MDAC_LEASE_SECONDS=900
MDAC_MAX_ATTEMPTS=5
SUPABASE_REQUEST_TIMEOUT_SECONDS=30
MDAC_PAGE_TIMEOUT_MS=60000
MDAC_HEADLESS=false

# 并发与容错参数
MDAC_CONCURRENCY=4
MDAC_SLOT_STAGGER_SECONDS=2.0
MDAC_LOCAL_ATTEMPTS=2

MDAC_SCREENSHOT_BUCKET=passport-documents
MDAC_SCREENSHOT_PREFIX=mdac-previews
LOG_LEVEL=INFO
```

---

## 独立运行与测试

```bash
# 激活虚拟环境后运行
python services/mdac-fill-preview/worker.py --poll

# 运行单元测试
python -m unittest discover -s services/mdac-fill-preview -p 'test_*.py'
```
