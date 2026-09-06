# 客户档案复用回退（2026-09-06）

状态：App 回退已实现；用户明确授权后，生产数据库回退已应用并通过事务验证。

## 业务行为

- 一份客户档案对应一次业务流程，移除“再次下单”。
- 新建档案只创建 customers 记录，不新建 Passport / Case。
- 同护照已有未删除档案时继续拦截；完成并删除旧档案后可重新 OCR 建档。
- 新档案不继承旧 PIN、MDAC 状态或查询凭证。
- Check Registration 继续按最近成功 MDAC 的入境、离境日期核对。

## 数据库变更

迁移：supabase/migrations/20260905204913_rollback_customer_reuse.sql
文件名已对齐生产迁移历史的版本 20260905204913；SQL 内容未变。

1. 保留 create_customer_with_case 的签名与 customer 响应，兼容已安装 App；取消内部 Passport / Case 双写，拒绝 A 常客类型。
2. create_case_for_existing_customer 返回中文“复用已停用”错误。
3. 撤销普通客户端向历史 Passport / Case 表 INSERT 的权限。
4. 停用自动更新 Case 状态及长期 PIN 副本的三个触发器。
5. 新任务不再自动关联“最新 Case”；已排队任务的明确 case_id 保留并验证归属。
6. 人工 Registration / Visit Pass 查询使用 customer_id；日期核对及文件证据流程保持。

不删除现存客户、Case、Passport、PIN 或 Storage 文件。历史关联的永久删除清理保留。
生产库检查时：6 个客户、2 条 Case、0 个多 Case 客户、1 条长期 PIN 副本。
历史 Case/长期 PIN 表目前仅保留数据，不继续增长或参与新的业务。

## 验证和发布

- Flutter 静态检查通过，38 项测试全部通过。
- 生产已应用迁移，并通过 supabase/tests/rollback_customer_reuse.sql。
- 验证涵盖建档无 Case、重复护照拦截、旧再次下单接口停用、删除合成记录后重新建档不继承 PIN。
- 删除步骤由事务测试执行器清理合成记录；未冒充手机端完整硬删除流程验证。
- 数据库测试只使用事务中的合成数据，最终 ROLLBACK。
- 迁移后核对仍为 6 个客户、2 条 Case、1 条长期 PIN 副本，与迁移前一致。
- 安全检查未发现新增告警；原有受控 SECURITY DEFINER 接口和密码泄露保护配置提示仍存在。
  参考：[函数权限说明](https://supabase.com/docs/guides/database/database-linter?lint=0029_authenticated_security_definer_function_executable)、[密码保护配置](https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection)。
- 数据库限制对已安装版本立即生效；移除按钮的 UI 需要安装包含回退代码的新 APK，本次尚未制作。
- 不批量执行仓库里所有历史迁移；本次只应用上述新增迁移。
- 本次不改变现存客户的保留期限或启动数据清理。

## 恢复能力

历史数据和字段保留。需要重新开启时，审查此前的 customer_case_write_rpcs、
case_worker_compatibility、registration_target_dates 定义，恢复相关函数、三个
触发器以及历史表 INSERT 权限；不要重复运行含回填的旧迁移。
