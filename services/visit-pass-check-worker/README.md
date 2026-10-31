# Check Visit Pass Worker (入境准证核验 Worker)

本服务是 Passport MDAC Desk 的入境准证有效记录核验引擎。它基于 Python + Playwright Chromium 打开马来西亚移民局官方 `Check Visit Pass` 页面（`https://imigresen-online.imi.gov.my/mdac/register?viewVisitPass`），查询旅客的入境许可记录、核验有效逗留天数并截取高清全景凭据归档。

---

## 核心架构与特性

1. **4 槽位多线程并发执行**：
   - 默认开启 4 个并发工作槽位（`VISIT_PASS_CONCURRENCY=4`），多窗口并行处理。
2. **2×2 四象限桌面大屏布局**：
   - 自动检测 Windows 屏幕工作区，均分为四象限监控窗口（每窗 `768 × 412`）。
3. **1.5s 阶梯式错峰启动**：
   - 平滑启动多路连接，防 WAF 限流。
4. **全景自适应高度截屏**：
   - 动态计算页面表格完整滚动高度，消除 Playwright 视口裁剪缺陷，完整记录盖章记录与有效期明细。
5. **Fail-Closed 严谨判别机制**：
   - 严格遵循证据原则，未查到有效准证或页面异常时安全标记为 `NEEDS_REVIEW`，绝不假定成功。
6. **槽位级就地快速重试**：
   - 内置 `VISIT_PASS_LOCAL_ATTEMPTS=2`，网络抖动或超时瞬态异常自动重试 1 次。

---

## 环境变量配置 (`.env.local`)

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

---

## 独立运行与测试

```bash
# 激活虚拟环境后运行
python services/visit-pass-check-worker/worker.py --poll

# 运行单元测试
python -m unittest discover -s services/visit-pass-check-worker -p 'test_*.py'
```
