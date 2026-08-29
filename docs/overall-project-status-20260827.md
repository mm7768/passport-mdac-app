# Passport MDAC Desk 总体状态报告

**报告日期：2026-08-27**
**项目：Passport MDAC Desk**
**平台：Flutter Android + Supabase + Railway Worker**

## 一、总体结论

Passport MDAC Desk 的 MVP 主体已经落地，客户管理、护照 OCR 审核、MDAC 受控填写预览、Gmail PIN 获取队列、Check Registration 和 Check Visit Pass 的后台 Worker 代码与部署均已完成。当前最重要的业务功能“客户档案多选后直接修改系统 `customers.created_at`”也已经完成，Supabase 迁移已应用，最新 Debug APK 已构建。

目前不能把项目描述为“全部生产验收完成”，原因是五个后台模块尚未使用完全脱敏资料执行集中端到端验收；MDAC、Check Registration 和 Check Visit Pass 仍严格保持“真实页面填写、DOM 回读、截图预览，不提交/不查询结果”的安全边界。Release 签名 APK 和三人内部正式分发也尚未开始。

## 二、功能完成度

| 模块 | 当前状态 | 说明 |
|---|---|---|
| Flutter Android 应用 | 已完成 MVP 主链路 | 使用真实 Supabase Email/Password 登录，会话可恢复；不是纯演示登录 |
| 客户档案 | 已完成 | 新增、编辑、软删除、业务状态手动调整、搜索、多选和批量操作均已具备 |
| 录入日期分类 | 已完成 | 使用系统 `customers.created_at`，支持全部、今天、最近 7 天、最近 30 天和自定义范围 |
| 国家分类 | 已完成 | 根据客户国籍动态生成，独立于业务状态，可与日期和业务状态组合筛选 |
| 批量修改 `created_at` | 已完成 | OWNER-only；选择多个活跃客户后选择日期和时间，二次确认后直接更新系统字段 |
| 护照资料 | 已完成基础链路 | 私有 Storage 上传，护照号码在档案中可见，不公开原图 |
| 日期与性别输入 | 已完成 | 日期自动补 `/`，严格 DD/MM/YYYY 和真实日期验证；性别使用下拉选项 |
| PIN 管理 | 已完成 | 只清理首尾空白，保留中间空格及连续空格；Gmail App Password 通过 Vault 保存且 App 不回读明文 |
| OCR 审核建档 | 已完成代码链路 | Azure prebuilt-idDocument Worker 已部署；真实脱敏文件端到端验收待执行 |
| MDAC fill-preview | 已完成受控版本 | 真实页面填写、回读和私有截图；验证码/滑块进入人工审核；硬阻断 Submit |
| Check Registration | 已完成受控版本 | 独立 Playwright Worker，填写并回读后进入人工审核；不处理 CAPTCHA，不提交 |
| Check Visit Pass | 已完成受控版本 | 独立 Playwright Worker，填写并回读后进入人工审核；不处理 CAPTCHA，不查询结果 |

## 三、客户档案批量修改 created_at

当前实现的实际流程是：在客户档案中勾选多个活跃客户，底部出现“修改创建时间”，选择日期和时间，系统显示影响人数、目标时间以及会影响录入日期筛选和排序的二次确认提示；确认后调用 Supabase 专用 RPC，成功后重新同步客户列表并清除选择。

数据库侧新增了 `bulk_customer_created_at` 迁移。RPC 只允许 active OWNER 调用，一次最多 200 位客户，拒绝空列表、重复 ID、不存在客户和已软删除客户。每一位客户单独写入 `audit_logs`，包含原始时间、新时间、批次 ID、操作人和批次数量，不记录护照号码或护照文件内容。

普通 authenticated 客户更新路径不能直接改写 `created_at`。新增的数据库触发器会拦截绕过专用 RPC 的直写；合法 RPC 仍可以执行。这样满足“直接修改系统 `created_at`”的业务要求，同时保留操作追踪。

## 四、Supabase 状态

| 项目 | 状态 |
|---|---|
| 目标项目 | `passport-mdac-desk`，ACTIVE_HEALTHY |
| Auth | Email/Password 登录、会话恢复和 active profile 校验已接入 |
| 数据库 | 核心 schema、客户、OCR、自动化队列、审计和 Worker 心跳已应用 |
| RLS | 已启用；内部 helper 已移入 `private` schema |
| Storage | `passport-documents` 为私有 bucket |
| Vault | Gmail App Password 加密保存，Worker 通过 service-role-only RPC 运行时读取 |
| 最新迁移 | `bulk_customer_created_at`，版本 `20260827135448` |
| 新 RPC | SECURITY DEFINER、authenticated 可调用，但函数内部强制 active OWNER |
| created_at 保护 | `customers_prevent_created_at_change` 已启用 |

Supabase 安全顾问目前会对允许 authenticated 调用的 SECURITY DEFINER RPC 产生提示，包括新增的批量 created_at RPC，以及之前已有的 MDAC/Gmail 设置 RPC。这是因为这些客户端业务操作本来就必须通过受控 RPC 暴露；新增 RPC 内部包含 active user、OWNER、数量、客户状态和时间范围校验。另有一项与本次功能无关的 Auth 提示：泄露密码保护尚未开启，后续可以单独处理。

## 五、Railway Worker 状态

目前应有五个在线 Worker，旧的 dry-run 服务 `glorious-wonder` 已按确认删除；GitHub 源码仍保留用于历史参考和维护。

| Worker | Railway 状态 | 当前行为 | 端到端状态 |
|---|---|---|---|
| Azure OCR | Online | 私有文件下载、Azure 异步 OCR、字段解析、回写和人工审核 | 待用完全脱敏文件验收 |
| MDAC fill-preview | Online | 真实填写、DOM 回读、截图、CAPTCHA 检测 | 待创建脱敏任务验收 |
| Gmail PIN | Active/Online | 只读 IMAP，过滤 `mdac@imi.gov.my`，不删除/移动/标记邮件 | 待用测试邮箱验收 |
| Check Registration | Active/Online | Playwright fill-and-review，不提交 | 待脱敏任务验收 |
| Check Visit Pass | Active/Online | Playwright fill-and-review，不查询结果、不提交 | 待脱敏任务验收 |

三个网页检查类 Worker 都明确设置为填写/回读/审核阶段，不自动处理 CAPTCHA 或滑块，不实现轨迹模拟、识别或绕过。任何验证码或滑块挑战都会暂停并进入人工审核。

## 六、测试与构建

当前本地 Flutter 验证结果如下：

| 检查项 | 结果 |
|---|---|
| Dart 格式化 | 通过 |
| `flutter analyze` | 通过，无问题 |
| 全量 Flutter 测试 | 23 项通过 |
| 客户页面 Widget 测试 | 已覆盖客户页面、窄屏布局和多选后批量入口 |
| Supabase 迁移应用 | 成功 |
| Supabase RPC 生产核对 | 已确认 SECURITY DEFINER 和 authenticated 执行权限 |
| created_at 保护触发器生产核对 | 已确认启用 |
| 最新 APK | Debug APK，约 174 MB |
| APK SHA-256 | `09001804948158984dcebf556f1980bc493b3202b5001a08c41a3cd506e7283f` |

最新 APK 已包含独立录入日期/国家分类和批量直接修改系统 `created_at` 功能，但仍是 Debug 测试包，不是签名 Release APK。

## 七、代码仓库状态

项目使用 GitHub 私有仓库 `mm7768/passport-mdac-app` 的 `main` 分支。最新已明确推送的基线提交为 `adbfcfa`；之后的独立录入日期/国家分类和批量直接修改 `created_at` 改动目前仍在本地工作区，尚未推送。当前本地改动包括 Flutter 主页面、SupabaseGateway、Widget/业务测试和新的 Supabase migration；构建产物未作为源码提交。

推送前仍需执行 `git diff --check`、完整测试、暂存内容扫描，并确认没有 `.env`、`android/local.properties`、build 产物、真实护照资料、Azure/Supabase/Gmail/MDAC 凭证或 Android 签名私钥。

## 八、尚未完成事项

第一，五个 Worker 的完全脱敏端到端验收尚未执行。这是目前从“代码和部署完成”走向“业务闭环确认”的主要缺口，需要使用完全脱敏客户资料，不使用真实护照。

第二，Release APK 和三人内部签名分发尚未制作。用户此前选择暂缓，当前不应把 Debug APK 当成正式分发包。

第三，GitHub 尚未接收最近本地改动。需要用户明确同意后才能执行 commit/push。

第四，之前聊天中曾意外出现过 Supabase Service Role Key。后续仍必须确认旧 key 已在 Supabase 端撤销/轮换，并确保 Railway 只保存新的掩码 Secret；本报告不重复任何密钥内容。

## 九、推荐下一步顺序

建议先由用户安装最新 Debug APK，使用脱敏账号和脱敏客户资料验收客户档案、多选、批量修改创建时间、日期/国家筛选及排序变化。确认 UI 和业务口径无误后，再明确授权推送当前本地改动到私有 GitHub。

随后集中执行五模块脱敏端到端验收：先保存 App 内 MDAC 默认配置和 Gmail 配置，再建立 OCR、MDAC、Gmail PIN、Check Registration 和 Check Visit Pass 任务，检查 Supabase 状态、私有截图和 Railway 日志；MDAC/两个检查 Worker 仍只填写不提交，验证码由人工处理。

最后才制作签名 Release APK 和三人内部分发流程，并单独记录版本号、签名私钥保管方式、安装步骤、回滚方式和后续更新策略。
