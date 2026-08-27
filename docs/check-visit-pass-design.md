# Check Visit Pass 设计依据

来源页面：https://imigresen-online.imi.gov.my/mdac/register?viewVisitPass
抓取时间：2026-08-27（用户时区）

## 官方页面观察

页面标题为 Malaysia Digital Arrival Card (MDAC)，功能标题为 Check Visit Pass。页面提示 movement record only display the latest 3 months。

公开查询表单使用 POST `/mdac/register`，隐藏字段 `hdCurrLang=ms`。查询输入字段如下：

- `passNo`：Passport Number，文本框，maxlength=12，类名 uppercase。
- `nationality`：Nationality / Citizenship，下拉列表，使用三字母 value，例如 `CHN`。
- `email`：Email Address，文本框；页面有邮箱格式校验。
- `regCd`：Country / Region Code，下拉列表；马来西亚 value 为 `60`。
- `mobile`：Mobile Number，文本框，maxlength=12。
- `pinKeyId`：PIN 文本框，maxlength=8。
- `sliderCapture`：验证码隐藏字段，初始为空。

页面包含 `sliderCaptcha`：容器 id 为 `captcha`，由 `/mdac/js/longbow.slidercaptcha.js` 初始化，远程资源为 `/mdac/captcha`，包括主 canvas、拼图 canvas 和 `.sliderContainer`。成功回调才会把 `verifyResult` 设为 true；失败/刷新会清空验证状态。查询按钮为 `#submit`，name=`searchVisitPass`，value=`Submit`，调用 `validateSubmit()`。

`validateSubmit()` 要求护照号、国籍、邮箱、国家/地区代码、手机号、PIN 和验证码均已填写/验证；官方页面会在表单校验通过后进入 POST 查询流程。

## Worker 边界

Check Visit Pass Worker 只允许领取任务、填写普通字段、读取 DOM 进行预检、检测 CAPTCHA、保存必要的私有截图并写回 `NEEDS_REVIEW`/人工介入状态。Worker 不应调用 `#submit`、表单 submit、POST 查询或任何验证码绕过逻辑。若出现滑块，记录 `CAPTCHA_SLIDER` 并暂停；不使用 OCR、轨迹模拟、缺口计算或自动拖动。

PIN 必须由已授权的 Gmail PIN 流程获得并通过服务端受限读取；PIN 不进入 Flutter 客户端可读快照。结果记录需要区分查询成功、明确无记录、页面错误和结果未知，不能因网络中断标记成功。

## 数据最小化

任务快照只需要客户 ID、护照号、国籍、邮箱、国家区号、手机号和 PIN 引用/服务端读取上下文。截图存入 Supabase 私有 Storage，只保存必要的短期预览并通过审计控制访问；日志不得输出 PIN、邮箱密码、Service Role Key 或完整护照资料。
