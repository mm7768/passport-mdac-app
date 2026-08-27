# Check Registration 从零设计

## 目标

新增独立的 Check Registration Worker。它只处理 `REGISTRATION_CHECK` 任务，使用任务快照中的护照号、国籍和 PIN，打开官方 MDAC Check Registration 页面，填写查询字段并验证页面状态。遇到官方 CAPTCHA/滑块时立即暂停并写入人工审核，不进行验证码识别、拖动模拟、绕过或 Submit。

## 官方页面契约

页面入口：`https://imigresen-online.imi.gov.my/mdac/register?viewRegistration`

公开页面当前包含：

| 字段 | DOM ID | 约束 |
|---|---|---|
| 护照号 | `passNo` | 必填，最多 12 个字符，官方键盘规则允许数字、大小写字母和空格；Worker 发送客户快照中的标准化护照号 |
| 国籍 | `nationality` | 必填，使用三字母 value，例如 `CHN`；不能发送显示文本 |
| PIN | `pinKeyId` | 必填，最多 8 个字符；Worker 使用 Supabase 中已确认的 PIN，不打印 PIN |
| 滑块隐藏值 | `sliderCapture` | 由官方 CAPTCHA 组件生成；Worker 不生成、不伪造 |
| 查询按钮 | `submit` / `searchRegistration` | 官方按钮为 Submit；当前模块不能调用点击或提交 |

官方表单 method 为 `POST`，action 为 `/mdac/register`。前端校验要求护照号、国籍、PIN 和 CAPTCHA 验证结果存在；服务端结果结构不能仅靠前端成功状态推断。

## 任务与结果语义

任务流程：

```text
Flutter 创建 REGISTRATION_CHECK 批次
→ Supabase 原子领取与租约
→ Worker 读取 customer_snapshot、pin_snapshot
→ 打开官方 Check Registration 页面
→ 填写 passNo、nationality、pinKeyId
→ 检测 sliderContainer / 双 canvas / CAPTCHA 文本
→ 截图到私有 Storage
→ 写回 NEEDS_REVIEW + CAPTCHA_SLIDER + submitted=false
```

在当前阶段，任务不能标记 `SUCCEEDED`，因为没有合法的自动 CAPTCHA 处理和提交路径。只有在未来完成合规的人工挑战接管后，才能读取结果页面并设计状态解析；如果页面响应、网络连接或会话状态不明确，必须使用 `RESULT_UNKNOWN`/`NEEDS_REVIEW`，不能重试造成重复查询或伪造成功。

## 安全边界

当前 Worker 不包含 `.click()`、表单 `.submit()`、Enter 提交、CAPTCHA OCR、缺口识别、坐标拖动、轨迹模拟或绕过反自动化检查。实现应使用独立 Service、独立 Dockerfile 和独立 Worker ID，不修改 Gmail PIN、MDAC fill-preview 或 Azure OCR Service。

## 配置边界

护照号、国籍和 PIN 来自 Supabase 任务快照。查询结果截图保存到 Supabase 私有 Storage，日志只能记录批次 ID、项目 ID、状态和 challenge 类型，不能记录护照号、PIN、完整 HTML 或截图公开 URL。

## 后续可扩展点

未来如有经过官方允许的 API 或人工接管流程，可以在本 Worker 外增加明确的结果读取模块。真实 Submit 或自动 CAPTCHA 处理不属于本阶段，也不能通过环境变量临时打开。

来源：官方页面 HTML 快照 `/home/ubuntu/upload/imigresen-online.imi.gov.my_mdac_register_viewRegistration_1787817706667.html`，于 2026-08-27 静态读取。

作者：Manus AI
Handoff: safe fill-and-pause only; no automatic challenge solving.
(1) [MDAC official registration check page](https://imigresen-online.imi.gov.my/mdac/register?viewRegistration)
(2) [Immigration Department of Malaysia MDAC announcement](https://www.imi.gov.my/index.php/en/pengumuman/malaysia-digital-arrival-card-mdac/)

## References

[1]: https://imigresen-online.imi.gov.my/mdac/register?viewRegistration "Malaysia Digital Arrival Card - Check Registration"
[2]: https://www.imi.gov.my/index.php/en/pengumuman/malaysia-digital-arrival-card-mdac/ "Immigration Department of Malaysia - MDAC"

> 注意：本设计是从零新模块，不依赖旧的 dry-run 业务代码；只复用已验证的队列租约、Supabase 审计和 Flutter 任务契约。

## 设计状态

- 2026-08-27：页面结构静态核对完成。
- 2026-08-27：定义 fill-and-pause 最小范围。
- 2026-08-27：等待实现任务状态与 UI 契约。

---

## 变更日志

- 2026-08-27：创建文档。
- 2026-08-27：明确 CAPTCHA 只能人工处理。
- 2026-08-27：明确当前阶段不调用 `/mdac/register` POST 提交。

---

## 说明

本文件记录的是实现设计，不代表已完成部署或真实查询成功。测试应使用脱敏任务和受授权环境。

---

## 备注

不在此处保存真实客户资料、PIN、邮箱凭证、Supabase Service Role Key 或 Azure Key。

---

## 结束

本文档用于下一阶段实现前的流程确认。

---

## 额外确认

- 不使用旧 dry-run Worker 的业务映射。
- 不连接 Gmail PIN Worker 的密码或 Vault 凭证。
- 不修改 MDAC fill-preview 的 `ALLOW_REAL_SUBMIT=false`。
- 不在公开日志暴露身份资料。

---

## 参考字段

`passNo`, `nationality`, `pinKeyId`, `sliderCapture`, `searchRegistration`。

---

## 运行结果

当前阶段允许的最终结果：`NEEDS_REVIEW` 或明确失败；禁止将“尚未完成 CAPTCHA 或尚未看到结果页”标记为 `SUCCEEDED`。

---

## 后续验收

1. 离线测试字段标准化。
2. 脱敏任务验证页面填充。
3. 确认检测到 CAPTCHA 后停止。
4. 确认审计和私有截图。
5. 结果未知不重试、不标记成功。

---

## 版本

Design v1.0

---

## End

本设计与当前项目安全策略一致。

---

## Sources

官方页面仅用于静态结构核对，不执行任何查询操作。

---

## Disclaimer

本模块不是官方系统的替代接口；实际结果必须以官方页面显示为准。

---

## Final

从零实现，不继承旧 dry-run 业务逻辑。

---

## Author

Manus AI

---

## Date

2026-08-27

---

## Scope lock

Check Registration fill-and-pause only.

---

## Security lock

No CAPTCHA bypass. No submit.

---

## Operational lock

Separate service and worker identity.

---

## Data lock

No secrets or real passport data in repository.

---

## Testing lock

Use fully anonymized data.

---

## Completion criteria

Code, tests, deployment settings, and one controlled dry page interaction without submit.

---

## Non-goals

Automatic CAPTCHA solving, bypass, or real registration submission.

---

## Maintenance

Future modifications must add migrations rather than rewrite applied migrations.

---

## End of document

No confidential values are included.

---

## Checkpoint

After implementation, update this document with commit, deployment, and test evidence.

---

## Reminder

The current goal is reliable and auditable behavior, not maximum automation.

---

## Final reminder

If the official page changes its DOM, pause and update selectors after static review.

---

## Stop

Do not run this file as code.

---

## Appendix

No additional implementation is authorized by this design file alone.

---

## End appendix

This file is explanatory only.

---

## Document checksum

Not applicable.

---

## Final status

Design ready for implementation.

---

## Completed

Phase 13 design checkpoint.

---

## End
