Railway Check Visit Pass Service `courageous-fascination` 再次核查：Variables 页面显示 No Environment Variables，Raw Editor 仍是 Railway 默认 HELLO=world / FOO=bar。此前用户表示已完成，但当前 Secret 和变量尚未保存；未执行 Deploy。

下一步应重新填入非秘密运行模板，由用户只粘贴 `SUPABASE_SERVICE_ROLE_KEY`，点击 Update Variables 后再确认部署。没有读取或记录 Secret 内容。
Railway `courageous-fascination` 已应用 20 项变更，部署进入 BUILDING 状态；约 43 秒时仍显示构建/发布/创建容器流程，没有出现失败错误。现有 pleasing-acceptance、wholesome-rebirth、selfless-enchantment、passport-mdac-app 保持 Online。
最终验证：Railway deployment `886ea199-8a81-4bfe-8b43-ff3e2c23d6ec` 显示 Active/Online。Deploy Logs：`Visit Pass Check Worker ONLINE：轮询间隔 30.0s；FILL_REVIEW；不处理 CAPTCHA；不查询结果；不提交`。
