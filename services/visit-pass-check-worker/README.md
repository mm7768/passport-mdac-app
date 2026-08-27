# Check Visit Pass Worker

这是从官方公开 MDAC `Check Visit Pass` 页面重新设计的独立 Railway Worker。当前版本只做 **FILL_REVIEW**：领取任务、填写普通查询字段、回读验证、检测官方 CAPTCHA/滑块、保存私有截图并写回人工审核状态。它不查询结果页、不点击 Search/Submit、不执行表单 POST，也不解决或绕过 CAPTCHA。

## Official page contract

页面：`https://imigresen-online.imi.gov.my/mdac/register?viewVisitPass`

查询字段：`passNo`、`nationality`、`email`、`regCd`、`mobile`、`pinKeyId`。页面的国家/地区代码 `regCd` 使用数值字符串，例如马来西亚为 `60`；国籍使用三字母代码，例如 `CHN`。

官方页面包含 `sliderCaptcha`，其结构包括 `#captcha`、两个 canvas 和 `.sliderContainer`，并通过 `#sliderCapture` 隐藏字段记录挑战状态。Worker 发现完整挑战结构后写入 `CAPTCHA_SLIDER` 与人工审核状态，不会自动拖动。

官方页面说明 movement record 只显示最近三个月。当前 Worker 不读取 movement record，因为读取需要通过官方查询提交，而本阶段禁止提交；因此完成任务时 `result_unknown=true`、`submitted=false`、`result_confirmed=false`。

## Railway deployment

在 Railway 从同一个私有 GitHub 仓库创建独立 Service：

```text
Root Directory = services/visit-pass-check-worker
Custom Start Command = python worker.py --poll
```

只在 Railway Secret Variables 中设置 `SUPABASE_URL` 和 `SUPABASE_SERVICE_ROLE_KEY`。不要把 Gmail 密码、PIN、客户资料或真实护照资料放进环境变量、镜像或日志。Gmail App Password 由 App 提交到 Supabase Vault，Worker 通过既有服务端受限 RPC 间接使用。

## Runtime flow

```text
claim_visit_pass_check_batch
  -> claim_visit_pass_check_item
  -> get_visit_pass_check_runtime_input
  -> Playwright 打开官方页面
  -> 填写 passNo / nationality / email / regCd / mobile / PIN
  -> 回读 DOM
  -> 检测 CAPTCHA/滑块
  -> 上传最小私有截图
  -> finish_visit_pass_check_item
  -> NEEDS_REVIEW / RESULT_UNKNOWN
```

PIN 只通过服务端受限 RPC 返回给持有租约的 Worker；PIN 不进入 `automation_items.customer_snapshot`，也不写入日志摘要。任务快照只保存查询所需的邮箱、地区区号和手机号，且由 App 入队时锁定。

## Safety gates

运行时必须保持：

```text
VISIT_PASS_CHECK_MODE=FILL_REVIEW
ALLOW_REAL_SUBMIT=false
VISIT_PASS_CHECK_HEADLESS=true
```

不要把当前 Worker 改成提交 Worker。遇到 CAPTCHA、页面结构变化、网络中断、PIN 不匹配或结果不确定时，写入人工审核/失败状态，不能伪造成功，也不能自动重试可能已提交的请求。

## Local validation

```bash
python3 -m py_compile worker.py
python3 -m unittest discover -s . -p 'test_*.py'
```

测试必须使用脱敏或合成数据；不会连接真实 MDAC、真实 Gmail 或真实客户资料。
