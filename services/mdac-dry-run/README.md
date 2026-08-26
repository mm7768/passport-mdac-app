# MDAC Dry-run Worker

这是从 `mdac-auto-v2` 字段映射提取出的云端安全预览 Worker。它可以读取 Supabase 中的 `MDAC_REGISTRATION` 队列，校验日期、性别、护照号和字段映射，然后把每个任务标记为 `FAILED / DRY_RUN_ONLY` 并写入审计日志。

它**不会**启动浏览器、登录 MDAC、读取 Excel、读取 Gmail、处理验证码或提交真实注册。这样可以先验证手机端任务、Supabase 队列、字段快照、租约边界和失败回写，不会误把模拟结果当成真实注册成功。

## Railway 服务设置

为 Railway 新建一个独立 Service，连接同一个 Private GitHub 仓库，并设置：

```text
Root Directory: /services/mdac-dry-run
Dockerfile: Dockerfile
Start Command: python worker.py
```

Variables：

```text
SUPABASE_URL=https://xdmcxhvdqsbcqedfprcy.supabase.co
SUPABASE_SERVICE_ROLE_KEY=Railway Secret Variable 中的 Worker 专用密钥
MDAC_DRY_RUN_WORKER_ID=railway-mdac-dry-run
MDAC_DRY_RUN_POLL_SECONDS=30
LOG_LEVEL=INFO
```

真实密钥只放 Railway Secret Variables，不要放进 GitHub、Flutter APK 或聊天消息。

## 状态边界

Worker 只领取 `automation_batches.task_type = MDAC_REGISTRATION` 且 `status = QUEUED` 的批次。领取后会读取 `automation_items.customer_snapshot`，按照旧版 `mdac-auto-v2` 的规则生成 `DD/MM/YYYY` 日期、`男 → 1` / `女 → 2`、区域代码 `60` 和字段映射预览。每个项目随后标记为 `FAILED`，错误码为 `DRY_RUN_ONLY`，避免任何人误以为已经提交真实 MDAC。

待确认真实授权、网页登录方案、验证码处理和结果未知状态后，再另行开发真实 headless Worker；不会通过修改这个服务的一个环境变量就开启真实提交。
