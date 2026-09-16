# Passport MDAC Desk

Passport MDAC Desk 是一个面向内部业务流程的 **Flutter Android + Supabase + Python Worker** 工作台，用于集中处理护照资料录入、Azure OCR、客户档案、MDAC 注册、Gmail PIN 获取、Registration 查询、Visit Pass 查询、人工审核与业务凭证归档。

当前仓库主分支版本：**v1.0.22+23**。

> 本 README 以当前 `main` 分支代码为准。`docs/` 中保留了项目早期的设计、dry-run、部署与重构记录，其中部分内容属于历史阶段，不应直接视为当前运行状态。

---

## 当前系统定位

这个项目已经从早期的 Flutter 流程原型，演进为一套由多个执行端协同工作的内部业务系统：

- **Flutter App**：业务操作入口、客户资料、OCR 审核、任务发起、状态查看、人工介入、凭证查看与导出。
- **Supabase**：Auth、PostgreSQL、Storage、任务队列、RPC、审计、业务状态与 Worker 协调中心。
- **Azure OCR Worker**：处理护照图片/PDF，调用 Azure Document Intelligence 解析护照字段。
- **Gmail PIN Worker**：读取 MDAC 官方邮件，按客户资料匹配 PIN 并写回数据库。
- **MDAC Worker**：执行 MDAC 页面自动化，并根据运行模式完成填表、人工审核或真实提交。
- **Registration Check Worker**：执行 Registration 查询并保存标准化结果与凭证。
- **Visit Pass Check Worker**：执行 Visit Pass 查询并保存标准化结果与截图凭证。
- **人工审核流程**：自动化结果不明确、页面挑战、资料异常时进入人工介入，而不是把未知结果误判为成功。

---

## 当前架构

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
                                                    └──────────────────────┘
```

### 为什么采用云端 + 本地 Worker 双轨架构

适合云端长期运行的工作，例如 OCR 与 Gmail PIN，可以由 Railway 等云端环境持续处理。

与官方网页交互的浏览器 Worker 则可以部署在办公室/本地真实网络环境中，由 Supabase 队列统一调度。这样 App 不需要直接执行浏览器自动化，Worker 也不会保存完整业务状态，所有任务结果最终回写 Supabase。

---

## 已实现功能

### 1. 护照导入与 Azure OCR

支持上传护照图片或 PDF，并由 `worker/azure_ocr_worker.py` 调用 Azure Document Intelligence 进行解析。

当前标准化字段包括：

- 姓名
- 护照号码
- 出生日期
- 性别
- 国籍
- 护照有效期
- MRZ
- 其他需要人工补充或确认的字段

OCR 结果不会直接无条件写入正式客户资料，而是进入审核流程；字段缺失或识别结果异常时可人工修改后再建档。

### 2. 客户档案

Flutter App 已具备客户资料管理能力，包括：

- 客户搜索与筛选
- 客户资料编辑
- 业务状态维护
- 护照资料与业务凭证查看
- 客户删除与关联资料清理
- 最新 Registration / Visit Pass 凭证展示
- 护照图片、Registration PDF、Visit Pass 图片等资料归档

当前数据模型已从早期“客户即一次业务”的思路逐步拆分为客户、业务任务、自动化批次、执行项、业务结果与证据记录。

### 3. MDAC 自动化

`services/mdac-fill-preview/` 是当前 MDAC 浏览器 Worker。

它通过 Supabase 队列领取任务，读取客户资料以及任务创建时保存的业务配置快照，再执行官方页面流程。

系统已经具备：

- 批量任务
- Worker lease / 锁
- 重试控制
- 自动完成 RPC
- 成功 / 失败 / 待人工状态区分
- 截图凭证
- 人工审核入口
- 任务取消与状态回退
- 自动提交结果写回

数据库中已经存在专门的 Worker 完成 RPC，用于区分：

- `SUCCEEDED`
- `NEEDS_REVIEW`
- `FAILED`

系统设计原则是：**只有结果被明确确认时才写成功；结果未知时不得伪造成功。**

### 4. Gmail PIN 自动获取

`services/gmail-pin-worker/` 负责读取 MDAC 官方确认邮件并匹配客户 PIN。

当前实现包含：

- Gmail IMAP
- 官方发件人过滤
- 护照号匹配
- PIN 标准化入库
- 任务队列与 lease
- 重试机制
- Supabase Vault / 受保护凭证读取
- 不把 PIN 和密码写入普通日志

Gmail 地址与 App Password 不应硬编码在代码或 Railway 配置文件中；运行时凭证由受保护的数据流程提供。

### 5. Check Registration

`services/registration-check-worker/` 用于查询 MDAC Registration 状态。

当前系统可以将查询结果标准化写入数据库，并保存相关证据文件；查询结果与客户业务状态可以联动。

### 6. Check Visit Pass

`services/visit-pass-check-worker/` 用于查询 Visit Pass。

v1.0.22 已进一步处理：

- 严格按结果表格 Date 列匹配
- 动态扩展页面视口
- 保存完整结果表格截图
- 清理旧 Visit Pass 凭证
- 每个客户档案只展示最新有效 Visit Pass 凭证
- 删除重复或历史脏数据记录

### 7. 任务队列

App 已具有统一任务视图，支持查看：

- 批次
- 客户执行项
- 任务类型
- 执行进度
- 成功 / 失败 / 待人工数量
- Worker 状态
- 错误摘要
- 人工审核入口

v1.0.21 起，任务界面支持自动轮询后台状态，减少手动刷新。

### 8. 批次管理

当前数据库已经支持：

- 自动化批次创建
- 客户批次卡片
- 批次合并
- 将指定客户移动/合并到目标批次
- 重复客户去重
- 批次计数重新计算
- 空批次清理

相关 RPC 位于：

```text
supabase/migrations/20260911020000_merge_automation_batches.sql
```

### 9. 业务凭证与导出

`lib/customer_bundle_exporter.dart` 已支持客户资料包导出，当前系统可以组合客户业务资料并生成统一 PDF / ZIP 输出。

业务证据主要包括：

- 护照图片
- Registration PDF / 查询凭证
- Visit Pass 截图
- 其他任务结果文件

### 10. 人工介入

自动化不是唯一出口。

以下情况应优先进入人工审核：

- 页面结构发生变化
- CAPTCHA / 滑块无法可靠处理
- 官方结果无法唯一判断
- 网络中断导致提交结果未知
- OCR 关键字段低置信度或缺失
- 多封邮件 / 多个 PIN 候选无法唯一匹配

相关 Flutter 代码：

```text
lib/mdac_human_review.dart
lib/human_query_review.dart
```

---

## 当前主要目录

| 路径 | 当前职责 |
|---|---|
| `lib/main.dart` | Flutter 主界面与主要业务流程 |
| `lib/supabase_gateway.dart` | Supabase Auth、CRUD、Storage、RPC、任务网关 |
| `lib/mdac_human_review.dart` | MDAC 人工审核 / 人工介入 |
| `lib/human_query_review.dart` | Registration / Visit Pass 等人工查询审核 |
| `lib/customer_bundle_exporter.dart` | 客户资料 PDF / ZIP 导出 |
| `lib/features/tasks/` | 任务模型与任务展示逻辑 |
| `worker/azure_ocr_worker.py` | Azure 护照 OCR Worker |
| `services/gmail-pin-worker/` | Gmail PIN Worker |
| `services/mdac-fill-preview/` | MDAC 浏览器自动化 Worker |
| `services/registration-check-worker/` | Registration 查询 Worker |
| `services/visit-pass-check-worker/` | Visit Pass 查询 Worker |
| `tools/run_all_workers.py` | 本地 3 合 1网页 Worker supervisor |
| `tools/restart_workers.bat` | Windows Worker 重启工具 |
| `supabase/migrations/` | 数据库结构、RPC、队列、权限、业务演进 |
| `supabase/tests/` | 数据库行为测试 |
| `test/` | Flutter 单元 / Widget 测试 |
| `docs/` | 历史设计、部署记录、研究与阶段性文档 |

---

## 本地办公室 Worker

当前 `tools/run_all_workers.py` 会统一托管 3 个本地网页 Worker：

```text
MDAC Registration
Check Registration
Check Visit Pass
```

启动：

```bash
python tools/run_all_workers.py
```

Supervisor 会：

- 同时启动 3 个 Worker
- 将日志统一输出到同一个控制台
- Worker 异常退出后自动重启
- `Ctrl + C` 时统一停止子进程

Gmail PIN Worker 当前不属于这个本地 3 合 1 supervisor；它可以独立部署为云端常驻 Worker。

---

## Flutter 开发与构建

环境建议：

- Flutter stable
- Dart 3.13+
- Android SDK
- JDK 21

安装依赖：

```bash
flutter pub get
```

静态检查：

```bash
flutter analyze
```

测试：

```bash
flutter test
```

Debug APK：

```bash
flutter build apk --debug \
  --dart-define=SUPABASE_URL=<your-supabase-url> \
  --dart-define=SUPABASE_PUBLISHABLE_KEY=<your-publishable-key>
```

当前 `pubspec.yaml` 版本：

```text
1.0.22+23
```

主要 Flutter 依赖：

```text
supabase_flutter
file_picker
crypto
webview_flutter
flutter_inappwebview
syncfusion_flutter_pdf
archive
```

---

## Supabase

Supabase 是当前系统的核心状态源，而不是单纯的数据存储。

主要职责包括：

- 用户认证
- 客户主数据
- OCR 批次与结果
- 自动化任务批次
- 自动化任务执行项
- Worker lease
- Gmail PIN 记录
- MDAC Registration 记录
- Registration Check
- Visit Pass Check
- Settings Snapshot
- Audit Logs
- 私有 Storage
- Vault / 受保护凭证
- Worker 专用 RPC

数据库变更全部通过：

```text
supabase/migrations/
```

进行版本化管理。

不要直接依赖某一张表当前字段作为长期 API；Worker 与 App 应优先通过现有 RPC / Gateway 边界交互。

---

## 配置快照

MDAC 联系方式、交通方式、入境地点、住宿资料、地址等业务默认值由 App 管理。

创建任务时会生成配置快照，因此：

```text
之后修改全局设置
        ≠
修改已经进入队列的旧任务
```

这是为了保证任务可审计和可重复判断。

---

## 环境变量与安全默认值

仓库中的 `.env.example` **只用于说明变量，不代表生产环境实际值**。

特别注意：

- `SUPABASE_SERVICE_ROLE_KEY` 只能存在 Worker / Secret 环境。
- Azure Key 只能存在 OCR Worker 环境。
- Gmail App Password 不进入 Flutter APK，也不应提交 Git。
- `.env.example` 中的 `ALLOW_REAL_SUBMIT=false`、`FILL_PREVIEW`、`FILL_REVIEW` 属于安全默认值。
- 如果部署环境需要启用真实自动执行，必须由部署者明确配置运行模式和权限开关。
- 不要把真实护照号、PIN、邮箱密码、Service Role Key 或 Azure Key 写入日志。

---

## Worker 状态原则

任务系统必须明确区分：

```text
QUEUED
CLAIMED
RUNNING
SUCCEEDED
FAILED
NEEDS_REVIEW
```

任何情况下都不要因为：

```text
浏览器超时
网络断开
页面关闭
响应丢失
```

就直接推断任务失败或再次重复提交。

**“结果未知”与“明确失败”不是同一个状态。**

这条原则对 MDAC 注册尤其重要。

---

## 当前发布状态

### v1.0.22

主要更新：

- Visit Pass 全景紧凑高清截图
- Visit Pass 结果表格完整保留
- 客户档案旧凭证物理清理
- Registration / Visit Pass 凭证展示去重
- 历史脏数据清洗
- Worker 重启工具完善

### v1.0.21

主要更新：

- 任务列表自动轮询
- 护照上传后自动等待 OCR
- OCR 完成后即时弹出人工审核
- Visit Pass 日期匹配与截图修复

### v1.0.20

主要更新：

- 客户按批次折叠展示
- 自动化批次合并
- 客户跨批次移动 / 合并
- 状态回退时同步清理旧查询证据

---

## 已有实际验证记录

仓库历史记录中包含一次 2026-09-08 的 30 人批次端到端运行记录：

```text
MDAC：30 / 30 完成
Gmail PIN：30 / 30 完成
```

这只能作为当时版本、当时页面结构和当时网络环境下的验证记录，**不代表未来任何时间都保证相同成功率**。官方页面、网络、防护机制或邮件格式变化都可能影响 Worker。

---

## 当前已知技术债

### Flutter 主文件过大

目前 `lib/main.dart` 已承担大量页面和业务逻辑。后续继续扩展前，建议逐步拆分：

```text
features/
repositories/
services/
models/
widgets/
```

避免后续 App、网站或 Agent 接入时继续扩大单文件耦合。

### Worker 存在重复逻辑

MDAC、Registration Check、Visit Pass Worker 当前仍包含部分相似的：

- Playwright 初始化
- 浏览器指纹配置
- Supabase REST 调用
- lease / retry
- screenshot
- error handling

后续可抽成共享 Worker SDK，但在生产流程稳定前，不建议为了“代码漂亮”而一次性重构所有 Worker。

### 历史文档与当前实现存在阶段差异

`docs/` 中有不少文件记录了项目从：

```text
Demo
→ Dry Run
→ Railway Worker
→ 本地 Worker
→ 自动提交 / 自动查询
```

的不同阶段。

因此进行交接或 AI 辅助开发时：

1. 先看本 README。
2. 再看最新 migration。
3. 再看对应 Worker 当前代码。
4. 最后才把 `docs/` 当作设计背景参考。

---

## 后续建议方向

当前系统已经具备继续扩展成完整内部业务平台的基础。

比较自然的下一阶段包括：

- Web Agent / Admin Portal
- Agent / Owner 权限体系
- Order 生命周期
- Customer 与 Order 正式分离
- Master List / Temporary Batch
- 财务字段：售价、成本、利润、收款状态
- 客户资料复用规则
- 护照过期与最新护照替换机制
- 自动归档与数据保留策略
- Worker Dashboard
- 统一告警
- 更完整的 E2E 测试
- App 模块化重构

这些属于下一阶段架构，不应直接混入当前 v1.0.22 已交付功能描述。

---

## 开发原则

后续修改建议继续保持以下边界：

1. **Supabase 是唯一业务状态源。**
2. **App 不保存 Service Role Secret。**
3. **Worker 不自行维护第二套客户数据库。**
4. **自动化结果必须可审计。**
5. **任务创建后使用配置快照。**
6. **结果未知时进入人工审核，不伪造成功。**
7. **历史凭证与最新有效凭证必须区分。**
8. **生产 Secret 永远不提交 Git。**
9. **新业务优先增加明确的数据模型与 RPC，而不是继续把逻辑塞进 UI。**
10. **重大重构前先保证当前 Worker 闭环可回归。**

---

## Repository

```text
https://github.com/mm7768/passport-mdac-app
```

当前 README 对应：

```text
main
v1.0.22+23
```
