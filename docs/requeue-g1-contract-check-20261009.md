# G1 客户端/四类 Worker 契约核对

日期：2026-10-09 MYT。App 基线 `062982fbb53f2aa4004f1362995b83d055c76b6d`；Web 基线 `67381d1dfa21dddffe3df8843b4a7122a75691f4`。当前工作树包含本文件及最小 Retry 适配，最终 SHA 由整体验收负责人在提交后绑定。依据 Web `REQUEUE_G1_FROZEN_CONTRACT.md` 与 `supabase/contracts/requeue-g1-v1.json`；**本文件是本地契约核对，不是 G3/G4 或部署通过证明**。

## 结论

四份 Worker helper 的 RPC 名称和实际字面参数符合冻结接口；未修改 Worker 业务解析。两个 App Retry 方法补齐 request UUID 和可验证返回结构。MDAC 人工界面缺独立证据 reason/ref，合法删除存在旧 fallback，均须服务端/对应受控人工流程闭环后验证，不能宣布所有合法客户端路径完成。

|调用域|候选实际行为与冻结结构|状态/待证明|
|---|---|---|
|四种严格 create|已有 App 参数 `p_items` 含 customer/case/operational_batch/membership；MDAC 另传日期，Visit 另传 settings；返回 batch Map|静态一致；缺见证时服务端应拒绝，不据当前新 Batch 推断；真实 token 测试未跑|
|全部 Retry|`requeue_automation_batch_guarded(p_batch_id,p_request_id,p_reason)`；`USER_RETRY`|已最小适配；服务端未安装不能调用成功|
|失败子集 Retry|`requeue_automation_failed_items` 同三参数；无直接 PATCH|已最小适配；FAILED 子集资格/原子性由服务端完成|
|Claim|四种 `claim_<kind>_attempt_batch/item`；参数沿既有 worker/lease/max_attempts；零或一行数组|静态一致；item 必须含原 witness、current_attempt_id/attempt_no、正确 locked_by 和 CLAIMED/RUNNING|
|Heartbeat|四种 `heartbeat_<kind>_attempt`；有 item 时透传 claim nonce，无 item 时 NULL；保持既有 void 返回|静态一致；必须由服务端验证 nonce/lease/worker，不能信客户端声明|
|Finish|7 个既有 finish 名称加 `_attempt` 与 `p_attempt_id`；返回 JSON 含 automation_item_id/attempt_id|参数一致；旧 nonce、旧 worker、lease 与 unknown 单调性尚待真实 G3|
|Runtime|Registration/Visit 加 `_attempt`，参数 item/worker/attempt；保持既有 RETURNS TABLE 数组与原字段|初始机器表笼统 jsonb 有误，负责人已勘误为 TABLE，未改客户端解析|
|Gmail|claim/heartbeat/finish 透传 nonce；finish 是 pin_status，无截图参数|静态/本地 fake 通过；不强造截图，不重做 PIN/IMAP/匹配；`get_gmail_runtime_credentials` 既有服务读取仍需服务端保留最小权限|
|Evidence|prepare: item/attempt/worker/extension/sha256/size；confirm: item/attempt/worker/evidence/sha256；failure: item/attempt/worker/evidence/http_status|准确参数与冻结 JSON 一致；上传禁止 upsert，三个 Worker 使用唯一路径；真实对象字节/权限/cleanup 未验|
|Owner cancel|managed 返回 `deleted=false, storage_paths=[]`|gateway 仅非空 storage_paths 才 remove；main 刷新并记录取消，兼容保留历史；不能误报物理删除|
|三个 MDAC 人工 RPC|签名仍为 item、evidence（success 另含 registration_no）；现 UI evidence 只有 source/官方页面布尔声明|**缺口**：无 reason 和独立受控证据 ref。未改 UI、未用客户端布尔声明冒充授权证据；严格拒绝为安全但不等于合法路径验收完成|
|人工删除/rollback|已有 `delete_customer_human_evidence` RPC 与 check-table/Storage fallback|**缺口**：gateway 旧 fallback 会吞错；服务端必须封堵 managed namespace 普通删除并提供受控清理，验证用户可辨识失败。当前不扩大本工作流修改范围|
|旧 Worker|候选仅隔离 host；managed Task 的经典 claim/finish 必须服务器拒绝|客户端无旧 finish fallback；服务器门控、原租约升级/回滚未实测|

## Retry 最小适配与限制

- 无新依赖。使用 `Random.secure()` 生成规范 UUIDv4；两个 gateway 方法保留原调用方式，新增可选 `requestId` 以便明确复用。
- 默认 key 按当前 actor、RPC 操作、Batch 缓存在内存。同一未确认请求、重复点击和网络未知后人工再次调用使用同 key；不自动发第二次请求。明确 SQL 拒绝也保留 key，服务端可重新校验，绝不隐藏错误。成功确认后移除，退出登录清空。
- 成功须 id/request_id 精确匹配、replayed 为 bool、非空且等长的 item/attempt UUID 列表，且各自无重复。缺字段、错误 key、无效明细都不算成功。
- **内存缓存不跨 App 重启，不代表持久网络幂等 UI 已通过。** 冻结服务端必须以 actor/key/fingerprint 保存结果，旧签名仅安全拒绝重复；重启后应先刷新核对，不以新 key 强行重试未知任务。G4 必须实际验按钮/提示及重启后核对行为。
- actor 来自实时 Auth；request ID 不携带/决定授权。服务器仍独立检查 FULL、原创建者范围、Task 资格/原 witness/租约及事务锁。

## 本地证据与下一 Gate

新增 `services/tests/test_g1_frozen_protocol.py`：6 项通过，覆盖四份复制一致、全部 ROUTES 名称、Worker 字面 RPC 参数、prepare/confirm 准确参数、Gmail nonce 无图片、claim 数组/runtime TABLE/heartbeat void，以及真实 MDAC post-claim 心跳调用必须带 item_id。仅解析实际 source 或执行实际 client AST + fake Session；未请求数据库、真实 Storage、邮箱或政府网站。

B2 定向核对发现 MDAC `worker.py` 领取 Item 后漏传 item_id，已仅在该心跳调用补上传参，由已有 helper 注入 nonce。其余三 Worker 已有相同 Item 关联，不改页面自动化、PIN、IMAP、解析或生产进程。完成后的 ONLINE 无 batch/item 与新协议兼容。后续 finish 必测最后一次 `finish → claim_item 空结果 → ONLINE`：服务端不能提前清父批 lease 导致正常空轮询抛错；现阶段不称 finish 合约已通过。

更新 `test/requeue_rpc_contract_test.dart`：原 7 项保留，新增明确 key/网络未知保留/异操作隔离/错误返回/重复点击/明确拒绝等合成测试，另补迟到旧响应不能移除较新请求 key 的交错测试，共 **15 项通过**（exit 0）。不得合并为服务端真实 Auth/API 通过。`flutter analyze --no-pub` 为 **0 error / 0 warning / 6 既有 deprecated info**，exit 1；不是全绿，未修改不相关 UI。`git diff --check` exit 0。

命令：

```text
python services/tests/test_g1_frozen_protocol.py
flutter test test/requeue_rpc_contract_test.dart --no-pub
flutter analyze --no-pub
```

本客户端核对工作没有应用迁移、真实 token、真实 REST/Storage、独立数据库多会话、Retention/回滚或真实 App/Preview 点击。G3/G4 为 NOT RUN。生产库、生产 Worker、真实任务及 main 未操作。代码已提交并推送指定开发分支，客户端被测代码 SHA 为 `e22fbbba2022c325b305aa04b85d24612c889aa0`；整体 Web 阶段报告另记录隔离 SQL 回滚测试（不是真实 Auth/API），Web 被测代码 SHA 为 `28e6fc766be5de19db36e2ea52046361939e2817`。本次仅追加文档状态，不改变被测代码。使用 Supabase 技能将 API 名称/参数核对与 ACL/RLS/实际行状态证据分开，官方 [Flutter RPC 文档](https://supabase.com/docs/reference/dart/rpc)确认命名参数方式，未据 SDK 调用成功推导业务安全。
