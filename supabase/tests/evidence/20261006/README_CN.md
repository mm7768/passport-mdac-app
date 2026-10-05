# 2026-10-06 审核后改进证据

所有时间需区分 UTC 与 Asia/Kuala_Lumpur；不得把快照数量当固定验收值。目录不含 API key、JWT、密码或真实客户明细。

生产 xdmcxhvdqsbcqedfprcy；隔离 rvgslhjmiaunylwhcamz。

## 命令和结果

命令从本机 MDAC 工作区运行（CLI／DPAPI 必须以原 Windows 用户执行），对应调用脚本在 `work/production-release`：

```powershell
& work/production-release/Invoke-ReadRpcGuard.ps1 -Target Isolated
& work/production-release/Invoke-ReadRpcGuard.ps1 -Target Isolated -TestOnly
& work/production-release/Test-ReadRpcApi.ps1 -Target Isolated
# 只可在新部署的适用授权内执行；本轮已经应用，不能再重放。
& work/production-release/Invoke-ReadRpcGuard.ps1 -Target Production
& work/production-release/Test-ReadRpcApi.ps1 -Target Production
& work/production-release/Test-ReadRpcProduction.ps1
& work/production-release/Test-ReadRpcProduction.ps1 -EvidenceName production-heartbeats-followup
& work/production-release/Test-SyntheticPairedRestore.ps1
```

迁移由 App 后端唯一负责；Website 不复制该迁移。runner 在迁移和 ledger 插入的同一个事务里提交，遇版本已存在会拒绝重放。隔离 SQL 测试使用 BEGIN／ROLLBACK 合成夹具。

|证据|含义|
|---|---|
|isolated-before.json／after.json|两个函数的定义、ACL、MD5；只有零参数签名，没有目标重载。|
|isolated-migration-result.json|新增迁移 SHA-256、项目、时间；不暂停 worker。|
|isolated-role-result.json|Owner／Operator／Review、anon／service、缺失／停用／删除／到期 profile、PUBLIC 继承权限、空 search_path、健康结构与旧心跳断言通过。|
|isolated-api-results.json|11 项真实 HTTP：匿名 publishable key 无 access token → 401／42501；三个业务身份读取成功；同一 JWT 遇停用／删除／到期 → 403／42501；本轮账号清理成功。|
|production-before.json／after.json|生产补丁前后定义和 ACL；不含真实业务行。|
|production-migration-result.json|实际生产应用时间、源文件 SHA-256、版本。|
|production-api-results.json|两个生产未登录 HTTP 请求 → 401／42501，无业务数据。|
|production-role-and-heartbeats.json|生产数据库角色而非人工登录：anon 拒绝、Owner 两接口与客户／订单读取、五类心跳第一时点。|
|production-heartbeats-followup.json|第二时点正常读取和持续新心跳；本轮未暂停／重启生产 worker。|
|*-security-advisors.json／advisors-review-cn.md|目标三告警消除，剩余提示逐项说明，不宣称零告警。|
|maintenance-fault-tests.json|13 项合成适配器＋DPAPI 持久状态故障测试；不是生产停机演练。|
|maintenance-independent-task.json|真实 Windows 计划任务独立恢复合成进程，创建会话已退出，新 BUSY 心跳通过，重复任务不重复恢复；演练任务／进程精确清理，正式监督保留。|
|synthetic-paired-restore.json|两个合成文件、非 API schema 与私有 bucket 的配对恢复＋显式增量重放；不是生产全量或异地灾备。|
|isolated-cleanup.json|原三个 inactive 账号、原客户／订单保留；本轮新增账号、bucket、对象、schema 已清理。|

## 调试记录，不隐藏失败

首轮 SQL stdin 非 UTF-8 编码导致事务未提交；修正 UTF-8 后仅隔离迁移成功。测试夹具曾缺少客户必填字段、日期、heartbeat version；角色恢复曾回到短期 CLI role／保留旧 review JWT，均修正测试脚本后通过。首轮 Auth/API 的读取／拒绝通过而清理失败，原因是 profiles 外键限制；精确删除本轮合成 profile 后删除对应 Auth 用户，再全套重跑通过。没有靠删除原隔离夹具、放宽 RLS 或修改生产数据让测试通过。

`isolated-error.log` 仅保留最后一条合成测试调试记录，不是最终失败结论。首轮原生进程演练被句柄创建时间检查拒绝，原因是 CIM 精度截断；改为封存精确内核时间后独立演练重跑成功。首轮失败任务已精确移除。所有测试边界保留在对应 JSON 的 scope 中。

当前浏览器初始化再次失败：`failed to write kernel assets ... path ... (os error 3)`；本轮没有人工生产登录、生产 Operator 页面、正式归档／恢复写入截图。生产 HTTP／数据库角色读取不能替代这些验收。
