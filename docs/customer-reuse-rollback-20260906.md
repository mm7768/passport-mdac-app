# 客户档案复用回退（2026-09-06）

状态：App 回退已实现；生产数据库迁移等待用户明确授权，尚未执行。

## 业务行为

- 一份客户档案对应一次业务流程，移除“再次下单”。
- 新建档案只创建 customers 记录，不新建 Passport / Case。
- 同护照已有未删除档案时继续拦截；完成并删除旧档案后可重新 OCR 建档。
- 新档案不继承旧 PIN、MDAC 状态或查询凭证。
- Check Registration 继续按最近成功 MDAC 的入境、离境日期核对。

## 数据库变更

迁移：supabase/migrations/20260905203954_rollback_customer_reuse.sql

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

- Flutter 静态检查通过；完整测试包含删除、OCR、查询日期与档案界面。
- 数据库批准后执行迁移，再执行 supabase/tests/rollback_customer_reuse.sql。
- 数据库测试只使用事务中的合成数据，最终 ROLLBACK。
- 迁移完成前，不应将移除按钮等同于数据库回退已完成。
- 不批量执行仓库里所有历史迁移；本次只应用上述新增迁移。
- 本次不改变现存客户的保留期限或启动数据清理。

## 恢复能力

历史数据和字段保留。需要重新开启时，审查此前的 customer_case_write_rpcs、
case_worker_compatibility、registration_target_dates 定义，恢复相关函数、三个
触发器以及历史表 INSERT 权限；不要重复运行含回填的旧迁移。
