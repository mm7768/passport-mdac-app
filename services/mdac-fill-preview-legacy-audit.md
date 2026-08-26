# 旧版 MDAC 自动化静态审查

## 审查范围

仅静态读取 `/home/ubuntu/mdac-auto-v2/main_console.py`，未运行脚本、未启动浏览器、未访问 MDAC 页面、未读取或提交任何真实资料。

## 真实页面入口

`https://imigresen-online.imi.gov.my/mdac/main?registerMain`

## 可迁移的确定性字段动作

- `#region` 选择区域代码，默认 `60`。
- `#nationality` 选择大写国籍。
- `#pob` 旧版跟随国籍选择；这个业务假设保留为待确认项。
- `#email` 与 `#confirmEmail` 填写固定邮箱。
- `#mobile` 填写固定手机号。
- `#trvlMode` 固定选择 `2`。
- `#embark` 固定选择 `CHN`。
- `#vesselNm` 填写固定航班/船名。
- `#accommodationAddress1`、`#accommodationAddress2`、`#accommodationStay`、`#accommodationState`、`#accommodationCity`、`#accommodationPostcode` 填写固定住宿资料。
- `#sex`：男为 `1`，女为 `2`。
- `#name` 填写姓名。
- `#passNo` 填写护照号。
- `#dob`、`#passExpDte`、`#arrDt`、`#depDt` 以 `DD/MM/YYYY` 写入，并触发 `input`、`change` 事件。

## 必须排除的旧版逻辑

- Tkinter 界面、线程日志队列、本地配置 JSON。
- Windows 可见 Chrome 启动：`headless=False, channel="chrome"`。
- 本地 Excel 读取、文件锁、状态写回和 PIN 写回。
- Gmail IMAP/PIN 读取及 Telegram 报警。
- `ddddocr` 滑块图像识别与轨迹模拟。新 Worker 不得绕过 CAPTCHA/滑块或反自动化机制；遇到此类挑战应停止并标记 `NEEDS_REVIEW`，交由人工处理。
- Submit 路径：`get_by_role("button", name="Submit")` 后的 `submit_button.click()`。
- 旧版 Submit 后仅依据 Dialog 文本判断成功，不能直接迁移；新 Worker 必须区分已提交、失败和 `RESULT_UNKNOWN`，并禁止因不确定而重试。

## 旧版安全缺陷/迁移风险

1. `test_mode` 是配置布尔值，错误配置即可进入真实 Submit 分支；新 Worker 不能依赖可变的普通配置作为唯一保护。
2. 领取任务依赖 Excel 状态，缺少云端租约、心跳、超时回收和多 Worker 原子领取。
3. 真实页面和字段选择器没有独立的填写层与提交层；新实现必须让 fill-only 流程的代码路径不包含 Submit 调用。
4. 日期通过 JavaScript 强制写值，需要同时验证页面最终 DOM 值和页面校验状态，不能仅记录“已填入”。
5. 旧版默认 `#pob` 使用国籍是业务假设，必须在预览摘要中标识并保留后续确认入口。

## 新版首阶段安全边界

`MDAC_EXECUTION_MODE=FILL_PREVIEW`，并要求 `ALLOW_REAL_SUBMIT=false`。Worker 只能领取 `MDAC_REGISTRATION` 任务，打开真实页面、登录、填写、校验字段、保存最小必要截图并回写 `NEEDS_REVIEW`；不得调用 Submit，不得标记 `SUCCEEDED`，不得把未确认结果当作成功。

## 2026-08-26 官方页面静态观察

已在官方登记页做被动查看，未填写、未拖动滑块、未点击 Submit。当前页面直接展示登记表单，没有发现账号/密码登录表单；页面通过 `GET /mdac/main?registerMain` 打开，表单 `POST` action 为 `/mdac/register` 加当前会话标识。实际 DOM 仍使用旧版所引用的字段 ID，包括 `name`、`passNo`、`dob`、`nationality`、`pob`、`sex`、`passExpDte`、`email`、`confirmEmail`、`region`、`mobile`、`arrDt`、`depDt`、`vesselNm`、`trvlMode`、`embark`、住宿字段和 `submit`。

页面在加载时异步请求签证国家资料，并初始化 `sliderCaptcha`。滑块使用 `/mdac/captcha` 和前端 canvas；验证成功后才解除 Submit 的 disabled 状态。新 Worker 不会破解、模拟或自动拖动这个验证码；它可以在验证码前完成字段填写和页面校验，然后截图并标记 `NEEDS_REVIEW`，由人工决定是否继续处理。官方页面的 `onsubmit="return validateSubmit();"` 与 `id="submit"` 只作为识别和安全阻断依据，fill-only 路径不会触发提交事件。

## 阶段二会话方案

首版采用每个任务一个全新的 Playwright BrowserContext，默认不保存护照页面 Cookie 到 GitHub 或聊天；如页面后续要求登录，则使用 Railway Secret 提供账号密码，并在首次登录遇到验证码、滑块或 MFA 时转为 `NEEDS_REVIEW`，不尝试绕过。会话状态只允许写入受保护的服务端存储，并按最小权限和可撤销原则处理。由于当前官方登记页是公开表单，首版不预置 MDAC 登录凭证，也不把“登录成功”假设写死在任务状态中。

安全模式由代码常量和启动校验共同保证：必须是 `MDAC_EXECUTION_MODE=FILL_PREVIEW`，`ALLOW_REAL_SUBMIT` 必须严格为 `false`。fill-preview 服务不包含任何 `submit()`、`click()` 或表单提交调用；如果页面在填写过程中自行跳转到确认/提交结果页，则记录为异常并标记 `NEEDS_REVIEW`，不解释为成功。所有完成结果写入 `mdac_registrations.registration_status=NEEDS_REVIEW`、`submitted_at=NULL`、`result_confirmed_at=NULL`，并在摘要中保留 `submitted=false` 与 `result_confirmed=false`。
