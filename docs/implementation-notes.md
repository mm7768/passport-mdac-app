# Passport MDAC Desk 首版实施说明

## 当前交付边界

本版本严格采用 Flutter Android 作为手机端目标。为了在未提供真实 Supabase 项目、商业 OCR 供应商和 Worker 生产凭证的情况下先验证流程，当前实现使用本地演示数据层。页面和业务对象已经按照规格拆分为客户主档案、OCR 草稿、自动化批次、任务状态和审计事件；真实后端尚未连接。

首版可运行闭环为：登录演示工作区 → 导入单张护照或多护照 PDF 演示文件 → 产生 OCR 草稿 → 人工确认七个 MDAC 必填字段 → 建立 `PENDING` 客户 → 勾选客户并启动任务 → 输入统一入境/出境日期 → 创建任务快照 → dry-run Worker 逐项处理 → 回写演示客户状态与批次进度 → 查看任务详情、失败项和审计记录。

## 已实现模块

| 模块 | 当前状态 | 说明 |
|---|---|---|
| 登录与角色 | 已实现演示流程 | 支持 OWNER 与 OPERATOR 三个白名单演示标识；真实 Auth 未接入 |
| 总览 | 已实现 | 活跃客户、待处理资料、运行中任务、需关注统计和 Worker 状态 |
| OCR 草稿 | 已实现演示流程 | 单图和多护照 PDF 均生成可审核草稿；保留文件名、页面与护照索引 |
| 客户档案 | 已实现 | 搜索、状态筛选、全选、详情查看、软删除、任务入口 |
| MDAC 批量注册 | 已实现 dry-run | 日期只精确到日；校验出境不早于入境；任务创建后模拟逐项处理 |
| Gmail PIN / 两类查询 | 已实现 dry-run 入口 | 模拟护照号优先的任务边界；真实 IMAP 和网页查询未启用 |
| Excel 导出 | 已实现预览与审计 | 仅预览姓名和护照号；真实 `.xlsx` 文件保存/分享面板待存储依赖接入 |
| 账号管理 | 已实现演示记录 | OWNER 可记录创建演示账号；真实服务端创建 Auth 用户未启用 |
| 任务队列 | 已实现 | 批次进度、成功/失败、状态标签、详情弹窗和 Worker 活动 |
| Python Worker | 已实现 dry-run | `worker/dry_run_worker.py` 复刻旧脚本关键字段映射，不访问真实网页或 Gmail |

## 参考旧仓库的迁移结论

现有 `mm7768/mdac-auto-v2` 仓库是 Windows 桌面控制台，核心是 Excel 驱动的 MDAC 网页自动化与 Gmail IMAP PIN 回填。本版本只把其中经过审查的确定性规则抽离到适配层：网页选择器字段、`DD/MM/YYYY` 日期格式、`男 → 1` / `女 → 2`、区域代码 `60` 和护照号优先匹配。旧版混合 `Status` 字段、Excel 回写、Telegram 人工报警和 `MANUAL_CHECK` 行为没有直接搬入新系统。

`#pob` 当前仍按规格暂时映射为国籍值，但新数据模型保留独立 `place_of_birth`，避免后续确认网页含义时迁移客户主档案。真实 Worker 必须把“提交结果未知”与“明确成功”分开，并禁止在响应丢失后立即重复提交。

## 尚未具备生产条件的事项

真实运行前必须完成下表中的确认和接入：

| 项目 | 必须补齐的内容 |
|---|---|
| Supabase | Auth 白名单、profiles、customers、ocr_batches、ocr_results、automation_batches、automation_items、业务结果表、worker_heartbeats、audit_logs、RLS 与私有 Storage |
| OCR | 商业供应商、文件格式/大小限制、原始响应结构、置信度阈值、费用与保存期限 |
| MDAC 自动化 | 官方网页自动化授权、目标字段与 `#pob` 真实语义、办公室浏览器环境、固定业务配置、有限重试次数 |
| Gmail IMAP | 邮箱所有者授权、应用专用密码安全存储、发件人过滤、邮件格式样本、Message-ID 去重与护照号匹配规则 |
| 查询任务 | Check Registration 与 Check Visit Pass 的真实输入字段、原始结果样本和标准化状态清单 |
| 敏感资料 | 护照文件、PIN、截图、日志、导出文件的访问人、保留期限、备份与永久删除策略 |
| Android 发布 | Android SDK、签名密钥、应用包名、真实设备测试、文件保存/分享插件与权限验证 |

## 验收建议

建议先使用本地演示数据完成 AC-006、AC-007、AC-008、AC-009、AC-010、AC-013、AC-014、AC-022、AC-023、AC-024、AC-025 和 AC-029 的流程验收。AC-001 至 AC-005、AC-011、AC-012、AC-015 至 AC-021、AC-026 至 AC-028 中涉及真实账号、私有文件、真实邮件、真实网页、XLSX 文件生成或权限后端的部分，应在 Supabase、OCR 和 Worker 接入后重新验收。

本版本不应被描述为生产可用，也不应直接上传真实护照、PIN 或 Gmail 凭证。它的目标是先把业务流程、页面交互、状态拆分和 Worker 边界变成可运行的 Flutter 验证基线。

## 客户维护与手机布局补丁

本补丁新增手动录入护照入口，并允许从客户详情打开编辑表单修改已建档客户的姓名、护照号码、出生日期、出生地点、国籍、性别、护照有效期和 Gmail PIN。护照号码继续执行首尾空白清除、大写标准化和重复拦截；编辑自己的原护照号码不会被误判为重复。编辑动作会写入演示审计记录。

PIN 规则已统一为：保存前只去除首尾空白，PIN 中间的空格和连续空格原样保留；空白 PIN 保存为 null。当前 dry-run Worker 写入的是固定演示值 `DRY-PIN`，真实 Gmail IMAP 解析仍需在 Worker 接入时调用同一保存规则。

总览统计卡片在手机端改为占满内容区宽度；总览双栏、处理原则、客户表格行、任务行和登录页也增加窄屏布局分支。360dp Widget 回归测试已覆盖总览、客户、任务和设置页面。

## 本轮客户表单规则更新

手动录入与客户编辑现在使用日期输入器自动插入 `/`，只接受真实的 `DD/MM/YYYY` 日期；性别改为“男/女”选择控件；业务状态改为可选择并同步 Supabase 的下拉控件。业务状态变更继续写入审计日志。另修复 Android 工程在沙箱重置后缺失标准 Flutter v2 embedding 文件的问题，并将 Gradle 内存配置调整为适配低内存构建环境的 2G。

验证：Flutter 静态分析通过，14 项单元与 Widget 测试通过。

## Azure OCR 两天 MVP

本轮新增 `worker/azure_ocr_worker.py`，使用 Azure Document Intelligence v4.0 GA 的预建身份文件模型 `prebuilt-idDocument`（API 版本 `2024-11-30`）。Worker 从 Supabase 私有 `passport-documents` Storage 下载图片/PDF，调用 Azure 异步分析接口并轮询结果，解析护照号码、姓名、出生日期、有效期、国籍、性别和 MRZ，把原始 JSON 与标准化字段写入 `ocr_results`。

手机端登录或会话恢复后会读取 `ocr_results`，显示 `REVIEW_REQUIRED` 或 `READY_TO_CREATE` 的 OCR 草稿。审核人可以补充出生地点、修改字段，确认后创建客户；真实 OCR 结果会同步更新为 `CREATED`，写入审核人、审核时间和创建的客户 ID。

Azure Endpoint 和 Key 只允许放在 Worker 环境变量 `AZURE_DI_ENDPOINT` 与 `AZURE_DI_KEY`。Supabase Service Role Key 同样只允许放在 Worker 环境变量，绝不进入 Flutter APK。`worker/.env.example` 仅包含占位符和当前 Endpoint，不包含真实密钥。

离线测试覆盖 Azure 字段解析、日期规范化、性别映射、缺失关键字段降级为 `REVIEW_REQUIRED`、不支持性别值降级和文件 MIME 识别。真实 Azure 识别验证需要在 Azure 资源已创建后配置 Worker 环境变量并使用脱敏样本执行。

当前两天 MVP 尚未包含 Gmail IMAP PIN、MDAC 网页自动化、Registration/Visit Pass 查询和办公室 Worker 常驻部署；这些保持在后续阶段。
