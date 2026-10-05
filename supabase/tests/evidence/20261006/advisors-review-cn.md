# 本轮 Advisors 逐项说明

生产原始证据：`production-security-advisors.json`，观察时间 2026-10-05T16:43:05Z（2026-10-06 00:43 MYT）。隔离原始证据：`isolated-security-advisors.json`。扫描不是攻击演示，也不替代鉴权断言。

本轮目标：两个匿名 SECURITY DEFINER 告警及 get_workers_health 的 mutable search_path 告警已不存在。两个函数仍为允许 authenticated 读取的 definer，因此仍出现 signed-in definer 提示；SQL 与真实 API 已验证活跃业务 profile／删除／到期检查及最小授权。没有为了得到零告警统一改为 invoker 或 Owner-only。

## 生产六项 RLS Enabled No Policy（INFO）

|private 对象|处理说明|
|---|---|
|app_order_intake_v13_repair_manifest|既有修复 manifest；保持 RLS 默认拒绝的配置，不新增开放策略，本轮未重验其全部调用链。|
|customer_hard_delete_jobs|既有后台删除任务表；保留受控 RPC 访问契约，本轮不扩大直接访问；永久删除沿用历史隔离证据。|
|customer_mdac_profiles|既有私有资料表；不为消除 INFO 添加直读策略，本轮未新增审计该完整调用链。|
|legacy_order_backfill_manifest|既有回填 manifest；没有重跑回填或改政策。|
|order_case_status_sync_v1_manifest|既有状态修复 manifest；没有改状态同步逻辑或策略。|
|phase2a_order_foundation_manifest|既有迁移 manifest；不开放业务用户直读来消除提示。|

隔离多一项 `public.customer_hard_delete_jobs` INFO 属隔离历史结构差异，不据此要求修改生产或重写 migration history。

## 生产 26 个 signed-in definer（WARN）

此提示表示 authenticated 可以调用 definer，不自动等同匿名暴露或已证明越权。以下逐签名记录处理边界；“保留”不表示本轮重新认证为无缺陷。

|函数／签名区分|本轮说明|
|---|---|
|archive_customer(uuid,text)|既有 Owner 归档入口；未改，用历史隔离证据，不冒充生产人工写入验收。|
|archive_order(uuid,text)|同上。|
|bulk_update_customer_created_at(uuid[],timestamptz)|范围外既有业务入口，保留；未做新增全链安全认证。|
|cancel_automation_batch(uuid)|既有旧权限修复保留，未重新开放匿名权限；历史隔离测试不等于此次重跑。|
|close_operational_batch(uuid,text)|范围外业务入口，保留；未做新增全链审计。|
|create_human_query_task(uuid,task_type,jsonb)|同上。|
|create_operational_batch(uuid[],text)|同上。|
|create_order_from_ocr(…)|既有订单创建入口保留；不修改 App 新功能、不在生产创建新订单验收。完整签名见原始 JSON。|
|delete_customer_human_evidence(uuid,text)|既有 Owner 权限修复保留，未扩大授权；本轮没有对真实文件做删除。|
|finish_human_query_task(uuid,text,text)|范围外任务业务入口，保留；未做新增全链审计。|
|get_latest_task_dashboard()|既有业务读取入口保留，本轮只修明确指定的两个读取函数。|
|get_mdac_batch_memberships()|本轮已修：仅 authenticated EXECUTE，实际检查活跃业务 profile，保持共享读取范围。|
|get_workers_health()|本轮已修：同上、固定空 search_path，hostname 只给 FULL Owner；新鲜 ONLINE／BUSY 才算在线。|
|merge_automation_batches(uuid,uuid,text)|范围外既有业务入口保留，未新增全链审计。|
|merge_customers_into_batch(uuid[],uuid,text)|既有修复保留；不重新开放匿名、不扩大角色。|
|merge_customers_into_batch(uuid,uuid[],text)|另一个历史重载，单独列出；同上。|
|requeue_automation_batch(uuid)|范围外业务入口保留，未新增全链审计。|
|restore_customer(uuid,text)|既有 Owner 恢复入口，未改；生产人工恢复尚未补验。|
|restore_order(uuid,text)|同上。|
|rollback_customer_evidence(uuid[],text)|既有 Owner 权限修复保留，历史证据引用不冒充本轮重跑。|
|save_gmail_credentials(text,text)|范围外凭据业务入口保留；没有导出凭据或扩大权限。|
|split_customers_from_batch(uuid,uuid[],text,text)|范围外业务入口保留，未新增全链审计。|
|update_automation_batch_note(uuid,text)|同上。|
|update_gmail_settings(text)|范围外设置入口保留，没有更改 Gmail 配置。|
|update_mdac_settings(…)|范围外设置入口保留，没有更改注册设置；完整签名见原始 JSON。|
|update_operational_batch_item(uuid,uuid,text)|范围外业务入口保留，未新增全链审计。|

## 泄露密码保护 WARN

仍未启用，当前没有调高套餐或修改登录配置。官方方案及账号兼容性评估见 `ops/maintenance/BACKUP_RECOVERY_PLAN_CN.md`；它不是阻塞本轮匿名权限修复的理由。上述其余提示继续保留，未宣称数据库零告警或完成全库安全审计。
