# Check Registration Worker (核验注册状态与下载原版 PDF)

本服务是 Passport MDAC Desk 的官方登记状态核验与原版 PDF 凭证下载引擎。它基于 Python + Playwright Chromium 打开马来西亚移民局 MDAC 官方状态核验入口（`https://imigresen-online.imi.gov.my/mdac/register?viewRegistration`），使用已确认的 PIN、护照号及国籍完成官方查询，并抓取原版 MDAC Slip PDF 文件归档至 Supabase 私有 Storage。

---

## 核心架构与特性

1. **4 槽位多线程并发执行**：
   - 默认开启 4 个并发工作槽位（`REGISTRATION_CHECK_CONCURRENCY=4`），每个槽位持有独立的浏览器实例。
2. **2×2 四象限桌面大屏布局**：
   - 自动适配 Windows 桌面，窗口铺满屏幕四象限（每窗 `768 × 412`），多窗口并行查询直观可视。
3. **1.5s 阶梯式错峰冷启动**：
   - 槽位间按 1.5 秒递增延迟启动，避免并发冲击导致网络拥塞。
4. **3 级弹性原版 MDAC Slip PDF 抓取引擎 (3-Tier Resilient PDF Pipeline)**：
   - **Tier 1 (页面内存直接 Fetch)**：在已认证页面上下文中执行原生 `fetch('/mdac/register?printSlip')`，将 PDF 二进制数据直接转为 Base64 读取。耗时仅 ~300ms，无弹窗阻断，零磁盘 I/O 开销。
   - **Tier 2 (Playwright Session API 请求)**：使用浏览器上下文的 `context.request.post()` 携带已建立的 Session Cookie 直接拉取 PDF 二进制流。
   - **Tier 3 (DOM 下载事件兜底拦截)**：点击页面打印链接，使用 `page.expect_download(timeout=15000)` 捕获浏览器下载事件。
   - **Tier 4 (存证保障降级截图)**：若官方系统未生成 PDF 文件，自动截取高清全屏凭证，保留提取到的 `trip_id`。
5. **槽位级就地快速重试**：
   - 内置 `REGISTRATION_CHECK_LOCAL_ATTEMPTS=2`，遇到瞬态网络超时或滑块识别异常自动就地重试 1 次。
6. **动态超时自适应机制**：
   - 45 秒基础查询等待 + 15 秒动态加载宽限期，从容应对移民局官网高负载场景。

---

## 环境变量配置 (`.env.local`)

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

---

## 独立运行与测试

```bash
# 激活虚拟环境后运行
python services/registration-check-worker/worker.py --poll

# 运行单元测试
python -m unittest discover -s services/registration-check-worker -p 'test_*.py'
```
