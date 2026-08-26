# Railway 控制台加载诊断

记录时间：2026-08-26（用户时区）

访问 `https://railway.com` 时营销首页可以加载；访问项目和 Service 深链接时，页面先出现空白，随后 Dashboard 路由显示深色骨架屏但没有可交互元素。用户侧也报告同样空白。Railway 官方状态页当前显示 Dashboard、API、Authentication、Builds、Deployments 和 EU West 均为 Fully Operational；因此目前更像是控制台前端/会话/缓存加载问题，而不是已确认的全平台事故。

在控制台恢复前，代码已经推送到私有仓库 `main`，commit `fc44594`；Supabase 两个 MDAC 迁移已成功应用；本地 Flutter analyze/test 和 Python fill-preview 离线测试均通过。Railway 尚未创建新的 `mdac-fill-preview` Service，也没有配置任何新的 Secret。

当前安全结论：不反复刷新、不在网页白屏时填写 Secret；先保留代码和迁移，待 Dashboard 恢复后创建独立服务。


补充：稍后访问 `https://railway.com/dashboard` 后骨架屏成功加载，显示账号 `wongaddmath@gmail.com` 与现有项目 `wholesome-respect`；点击项目后进入 Azure OCR Service 路由，但画布又暂时显示空白，说明控制台不是永久不可用，更可能是前端数据加载延迟或项目画布组件异常。


再次观察：Dashboard 路由可以在等待后加载，但项目卡片一度显示“无服务”，点击后项目路由又回到空白，随后项目页才显示 `Add` 入口和两个现有 Service。控制台数据加载明显不稳定；当前不应在未确认页面状态时执行 Deploy/Apply，避免误改服务。


补充：直接进入项目架构页会多次回到 `about:blank`；返回 `/dashboard` 后先显示骨架屏。当前控制台加载不稳定，尚未执行新 Service 创建或 Apply/Deploy 操作。


补充：项目画布最终稳定显示 `Add` 菜单，包含 GitHub Repository、Database、Template、Docker Image 等选项。通过可见坐标点击 GitHub Repository 后菜单关闭但未进入下一步；元素索引点击未持久化，select 工具不适用于该 ARIA 菜单。尚未创建新服务，也未执行部署或 Secret 配置。


外部核查来源：Railway 官方状态页 https://status.railway.com/。读取时间：2026-08-26。页面显示 Fully Operational；Dashboard — railway.com、API — backboard.railway.com、Authentication、Builds、Deployments，以及 EU West (Amsterdam, Netherlands) 的 Builds/Deployments/Compute 均报告 100.00% uptime/Operational。该状态页同时说明小范围或孤立问题可能不会显示，因此不能排除当前账户/前端会话问题。
