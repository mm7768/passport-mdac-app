# Automation Requeue：隔离候选客户端（禁止部署）

2026-10-09。分支 feat/automation-requeue-security-20261009，来源 390e242ae9a6d7ca718b827977bd2cfeca1dcf6a。Web 是唯一产品 migration 责任方；本仓库不添加/复制 migration。

## 已写的候选代码

- SupabaseGateway 全部重试改 requeue_automation_batch_guarded(uuid)，仅失败项改单个 requeue_automation_failed_items(uuid)；无裸两表 PATCH、无旧 RPC fallback、无静默假成功。
- 两种重试仅准隔离URL。旧同签名 requeue_automation_batch(uuid) 的受控兼容包装仍必须由 Web 数据库迁移实现，不能把新App路由当成全局权限修复。
- MDAC、Registration、Visit Pass 仅修改存证/必要attempt协议与失败处理，不改官方页面、验证码、代理或结果解析。新claim命名 claim_<kind>_attempt_batch/item；heartbeat/finish/runtime名见每服务attempt_evidence.py的ROUTES。
- 新 claim 必须返回 canonical UUID：id、case_id、customer_id、original_operational_batch_id、original_membership_id、current_attempt_id，整数attempt_no、对应locked_by及CLAIMED/RUNNING。
- prepare_automation_evidence 服务端授予 bucket=passport-documents、evidence_id、attempt_id、path、sha256。只接受 automation-attempt-evidence/<attempt>/<evidence>.png或pdf，Storage POST x-upsert=false。
- confirm_automation_evidence 必须返回 state=STORED及相符evidence/attempt/hash。manifest先PREPARED、失败对象仍可追溯。网络未知不DELETE、不覆盖；后端补偿未实现。
- finish/lease/runtime传p_attempt_id；成功finish响应检查 automation_item_id、attempt_id。不默默替换inflight nonce。已知结果须已确认证据；finish网络失败不改结果再写第二次。
- Visit FOUND不调用即时旧证据清理；旧Case/Customer删除helper改no-op。合法到期/Owner硬删除要由受控保留流程处理，尚未联调；不能据此宣布已建立永久保存或合规删除。

四服务的attempt_evidence.py为相同代码的本地副本，使既有每服务Dockercontext能正常导入；services/tests/test_attempt_protocol.py检查副本一致。无需新依赖，不启动这些候选Worker。

## 安全边界

数据库新端点尚未存在；代码缺协议会失败。RPC前硬性只接受 rvgslhjmiaunylwhcamz.supabase.co，生产URL会在请求前拒绝。没有启动、暂停、替换、部署任何生产Worker，没有修改OCR源码，没有合并main。

GMAIL_PIN是第四种业务任务。用户追加授权最小nonce透传后，开发分支已适配claim/heartbeat/finish及Docker本地模块。Gmail不上传截图，不更改邮件匹配/过期判定/IMAP流程，不访问真实邮箱。新协议缺失或nonce错误安全拒绝，没有旧finish回退。完整受控服务端/旧Worker门控尚未实现，不能称为可上线。

随后获用户追加授权，最小修复两个原基线PIN提取缺陷：保留同一行内部空格，空PIN不误取下一行；全值校验保持3–24字符与字母数字首尾，允许原有连字符/下划线及内部水平空白，拒绝无效值的截断前缀。未扩展跨行PIN格式。两个测试替身补heartbeat_tick，30项合成样本任务时间改为邮件到达之前，不改变生产邮件时间筛选。

## 本地测试（不等于G3/G4）

- 18:42 MYT重跑Python协议测试19项，含4个Gmailnonce/旧轮次/生产host拒绝测试，使用真实客户端/processor类AST与fake HTTP，未调用Supabase/官方页面。
- 三个旧Worker合成单元套件11+11+20=42项。旧Visit断言改为无绑定拒绝、FOUND不删历史；默认30s与基线一致；MDAC已有随机track的旧30..40断言改为实际28/36边界确定性测试，未改solver。
- Gmail基线390e242的20项原测试独立复现2 FAIL、3 ERROR；获授权后24项全通过（原20+新增4），含30项准确映射、陈旧邮件拒绝、姓名冲突复核与日志脱敏。matching/IMAP尾段与基线逐字相同（从def decide_for_item开始、规范化LF，SHA256 b5a40275437105f412a9e4386385bbd508b5f71b8d1bed43b99a824c96dbf3a9）。本轮85项Python本地测试全通过，不是G3。
- App requeue_rpc_contract_test.dart：7项，只用测试回调，非真实Auth/API/按钮验收。
- Flutter analyze --no-pub：0 errors/0 warnings、6条既有deprecated info，默认exit1；不能报严格全绿。
- 必须由Web完成隔离migration、真实token ACL/REST、原业务witness/锁、旧Worker门控、真实Storage、保留/删除补偿与G4，再申请G5。

运行说明仅限本地测试：

```text
python services/tests/test_attempt_protocol.py
python -m unittest discover -s services/mdac-fill-preview -p test_worker.py -v
python -m unittest discover -s services/registration-check-worker -p test_worker.py -v
python -m unittest discover -s services/visit-pass-check-worker -p test_worker.py -v
python -m unittest discover -s services/gmail-pin-worker -p "test_worker*.py" -v
flutter test test/requeue_rpc_contract_test.dart --no-pub
flutter analyze --no-pub
```

不能执行worker.py --poll/--once来替代这些测试；没有提供生产启动命令。回滚候选客户端不应恢复数据库宽权限或旧对象覆盖；已经生成的attempt/event不得删除。当前尚无可执行产品migration/安全rollback。
