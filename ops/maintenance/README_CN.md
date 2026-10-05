# MDAC 独立维护恢复监督 V1

2026-10-06，Asia/Kuala_Lumpur。安装于本机当前 Windows 用户；不依赖聊天、AI 模型额度或原 PowerShell 会话。仅适用于明确授权的维护操作。

## 当前状态与限制

正式计划任务 `MDAC Maintenance Supervisor` 已安装，每分钟运行一次，无维护 run 时只更新存活记录，不查询数据库或控制 worker。已用真正的 Windows 计划任务恢复一个被暂停的本机合成进程；创建会话退出、恢复后新心跳、重复执行不重复恢复均有证据。13 项合成故障测试通过。没有为了演练暂停生产 worker。

需要这台电脑开机、此 Windows 用户保持登录、Supabase/Vercel CLI 授权仍有效、脚本与本机运行时路径未移动。锁屏通常不终止交互登录任务；注销、关机、断网、CLI 授权失效不在本机制的自动恢复保证范围内。DPAPI 只能在合适的 Windows 用户上下文解密。

提醒只写本机 `*.status.json`、加密阶段日志及错误文件；没有邮件、群消息、外部推送或弹窗，也没有承诺离开电脑能收到通知。维护发起人必须在期限前设置独立的人工作业提醒并安排值守。机器故障不能由同机监督解决。

## 独立入口

从 App 仓库根目录运行：

```powershell
pwsh -NoProfile -File ops/maintenance/Install-MaintenanceSupervisor.ps1 -Action Status
pwsh -NoProfile -File ops/maintenance/Invoke-MaintenanceSupervisor.ps1 -ProbeOnly
pwsh -NoProfile -File ops/maintenance/Invoke-MaintenanceSupervisor.ps1
```

`-ProbeOnly` 为生产只读：取得实际数据库版本／结构／ACL 指纹、正常 Owner 数据库角色读取、实际生产部署 ID、公开登录页及心跳。它不是人工登录验收。当前本机使用便携 psql 17.11、Supabase CLI 2.117.0 与 Vercel CLI 60.1.3，版本化探针通过官方 CLI 在内存取得短期连接；不会将密码写入 Git。

本机路径依赖在 `Connect-ProductionReadonly.ps1` 和 `ProductionProbes.psm1` 中，迁移机器或移动仓库前需要重新配置并重验，不能只复制计划任务。正式状态根目录：`C:/Users/wong7768/Documents/Codex/mdac-private-backups/maintenance`。

## 维护前准备，不能直接调用旧 Pause 脚本

1. 核对备份的数据库与 Storage 恢复点、解密可用性、文件核验结果和版本，不把“目录存在”当作备份通过。旧快照不能自动当成下一次维护的新备份。
2. 明确维护执行人、15 分钟等具体期限、现有数据库／网站版本、拟发布版本和兼容策略。读取探针的数据库 fingerprint 是结构／函数定义／ACL／RLS／约束／migration ledger 的组合，不是客户数量或心跳状态。
3. 在受控影子恢复库验证迁移后目标 fingerprint；不得猜测目标值。目标与现版本相同而阶段为 MIGRATING 时，监督会视为“完成未证明”进入 MANUAL。DML-only 迁移须另行核验并人工解除，不能绕过。
4. 若保留旧网站部署作为兼容恢复版本，应先验证它与目标数据库兼容，再将该部署 ID 加入允许列表。数据库就绪但网站失败／无法确认实际部署时，本 V1 采取 MANUAL，不自动启动。
5. 从实时进程和心跳中核对五组共十个父／子 Python 进程及五个准确 heartbeat ID；PID 不是固定常量。记录原工作目录，核对原命令及本机环境文件，不将密钥搬到前端。
6. 正式监督任务最近 90 秒内有存活记录、上次结果为 0、运行用户一致；然后生成 run。安装动作独立于聊天，下一次暂停前必须重新检查实际存活。

```powershell
# 用实时核对值替换变量，不复制旧 PID。此命令仅生成 PREPARING，不暂停。
pwsh -File ops/maintenance/New-MaintenanceRun.ps1 `
  -WorkerProcessIds $confirmedProcessIds -HeartbeatIds $confirmedHeartbeatIds `
  -BackupDirectory $verifiedBackupDirectory -RequiredDbFingerprint $verifiedTargetFingerprint `
  -AllowedDeploymentIds $compatibleDeploymentIds -WorkerWorkingDirectory $originalWorkingDirectory -Minutes 15

# 以下动作只能在新一次维护已经获得适用授权时执行。
pwsh -File ops/maintenance/Control-MaintenanceRun.ps1 -RunPath $runPath -Action Pause
pwsh -File ops/maintenance/Control-MaintenanceRun.ps1 -RunPath $runPath -Action MigrationStarting
```

持久阶段：PREPARING → PAUSED → MIGRATING → DB_VERIFIED → SITE_VERIFIED → RESUMING → RESUMED／MANUAL。阶段、run ID、执行人、期限、原进程身份、原工作目录、版本、备份位置、逐进程 intent 和恢复命令保存在 DPAPI 加密 run 中；公开 status 文件不含命令、主机名、客户数据或凭据。文件锁避免并发恢复，原子替换避免半写状态。

到期检查真实版本与普通读取，再检查所有进程身份；内核句柄再次验证路径和精确创建时间，不能仅凭 PID。逐进程恢复意图先持久化，成功后写 DONE，重复运行不重复恢复。若意图与确认之间中断，进入 MANUAL，不猜测是否已恢复。中途暂停仍处于 PREPARING 时，已有 intent 也会被监督检查。迁移持有相关目录／表 DDL 锁或版本不符不会恢复。

成功需要五个指定 heartbeat ID 在恢复起点之后产生新心跳、状态 ONLINE 或 BUSY、三分钟内有效，并且业务读取成功。旧 ONLINE 不算成功；最多等待四分钟后进入 MANUAL。当前脚本不发起业务任务，不重复真实注册。

## 人工处置

- 查看 `run-<id>.dpapi.status.json` 的原因，并在原 Windows 用户上下文读取加密 run；不要把解密内容发到聊天或提交 Git。
- 数据库未知、部分提交、网站失败：保持 MANUAL，完成前向修复／版本兼容核验；不能通过恢复匿名权限解决。
- 原进程退出或 PID 被复用：不得操作那个 PID。`Restart-MissingWorker.ps1` 使用记录的原父进程命令、可执行路径和工作目录，先检查任何现存同组进程，再按原参数最多启动一组。它不会经过 shell 拼接，不存在原启动路径时拒绝。入口：

```powershell
pwsh -File ops/maintenance/Restart-MissingWorker.ps1 -RunPath $runPath -OriginalParentPid $originalRecordedParentPid
```

- 此启动入口仍保留 MANUAL；由值守人核对新的父／子进程身份、五类新心跳及正常读取后形成恢复结论。不能把旧 roster 自动替换为未经核对的新 PID。本轮测试了缺失／复用时的拒绝与后续入口，没有重启生产 worker，也未将真实缺失 worker 启动列为已实测。
- 普通版本／读取故障经人工修复后，可调用 `Control-MaintenanceRun.ps1 -Action RetryAfterManualReview`，重新运行完整检查。有未确认 resume INTENT 时该入口拒绝，必须人工逐进程核对，不能盲重放。

## 复验与撤销

```powershell
pwsh -File ops/maintenance/Test-MaintenanceRecovery.ps1
# 下列演练只暂停合成进程，但会建立本机演练计划任务；在授权的本机运行。
pwsh -File ops/maintenance/Start-IndependentRehearsal.ps1
pwsh -File ops/maintenance/Finish-IndependentRehearsal.ps1 -Root $printedRehearsalDirectory

# 精确撤销正式监督任务，保留加密 run 历史，不删除业务或备份。
pwsh -File ops/maintenance/Install-MaintenanceSupervisor.ps1 -Action Remove
```

证据：`supabase/tests/evidence/20261006/maintenance-fault-tests.json`（13 项）、`maintenance-independent-task.json`（真实计划任务与合成进程）。本轮两个演练任务和合成进程已精确移除，加密演练记录保留。正式任务在没有 active run 的状态下保留。
