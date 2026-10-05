# 备份／灾备补充方案与测试边界

2026-10-06，Asia/Kuala_Lumpur。方案不等于异地灾备已上线。

## 已验证与未验证

本轮在隔离项目 rvgslhjmiaunylwhcamz 使用独立非 API schema、私有 bucket、两个合成文本文件验证了 DPAPI 加密快照、数据库文件元数据与 Storage 内容 SHA-256 的同恢复点还原、显式保留并重放恢复点后增量。精确清理本轮 schema、bucket、对象，没有全量重传生产护照。证据 `supabase/tests/evidence/20261006/synthetic-paired-restore.json`。

这不是生产数据库的全量独立重验，不证明当前 290 MB 等旧备份数字仍对应最新恢复点，不证明跨机器解密或备份副本已经异地保存；业务约束、Auth/Vault/平台配置和大量生产对象仍须按正式恢复演练验证。历史本机恢复报告作为旧证据保留，不能改成此次已重跑。

## 现有同机加密限制

CurrentUser DPAPI 一般绑定同一 Windows 登录凭据与机器，依赖用户配置中的主密钥；简单把 `.dpapi` 文件复制到另一台电脑不能保证解密。管理员重设 Windows 密码可能导致旧材料不可恢复，正常用户改密与管理员重设不能混为一谈。不要通过 Machine 范围加密放宽为本机所有用户可解密。依据：[Microsoft DPAPI](https://learn.microsoft.com/en-us/windows/win32/api/dpapi/nf-dpapi-cryptprotectdata)、[DPAPI 示例及限制](https://learn.microsoft.com/en-us/windows/win32/seccrypto/example-c-program-using-cryptprotectdata)。

EFS 还需要对应证书私钥，证书公钥本身不够。可以由备份责任人在安全交互环境使用 `cipher /x` 导出受密码保护的证书／私钥备份，另存于受控介质；本轮未导出私钥，也未在另一台机器导入或验证。依据：[Microsoft cipher](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/cipher)。

## 待批准的无新增付费默认方案

1. 主责任人为现有业务 Owner，备份恢复交接人由 Owner 指定；不擅自给同事发文件、邮件或密钥。
2. 选择用户已有的加密离线移动盘或已经批准的企业存储作为独立副本目的地；本轮尚未得到具体目的地，未上传生产资料。最终目的地须明确访问人员、所在位置和取回路径。
3. 在原 Windows 用户可解密时，把数据库 dump、Storage 清单、对象、schema／migration／网站版本／Auth 配置说明和恢复点打成可跨机器解密的加密归档。采用经过评审的标准工具或信封加密，独立随机恢复密钥，不自创算法。只在内存或受控 EFS 临时目录解密。
4. 将恢复密钥／证书私钥与唯一备份副本分开保管；密钥可置于用户已授权的密码管理器和密封离线恢复材料。归档与唯一解密材料都只放同一电脑不能算灾备。
5. 建议待批准的保留周期：最近 7 个每日配对快照、4 个每周快照、3 个月度快照，以及变更前快照直至新版本验收通过。它是待批准建议，不是本轮已建立的自动任务或已执行清理规则；未删除旧备份。
6. 首次正式采用前由责任人在独立机器验证：密钥可取回、归档可解密、数据库与 Storage 配对一致、权限／RLS与迁移完整、App／Website 能读取；分别记录耗时和失败处理。目标 RPO/RTO 应按实际测试再确认，当前不能宣称已具备灾备。

## 恢复点与恢复后新增写入

维护前短暂冻结写入，获取同一恢复点的数据库与 Storage 清单及对象哈希；无法冻结时须设计增量／一致性协议，不能将任意时间的 dump 和对象目录拼为快照。

恢复前先封存故障时点的数据库、对象和审计／任务状态，保留快照之后的业务增量；恢复到原快照后按编号、任务幂等键、对象关联和版本冲突规则人工核对并有序重放，不自动重复 MDAC 注册。未保存的增量不能凭旧快照凭空恢复。合成测试验证了此区别，但尚未实现生产全量增量恢复工具或业务冲突自动合并。

## 后续永久删除扩展测试

隔离库补三个独立场景：执行中 profile 变为停用／删除／到期，多个 bucket 同一客户文件，批量对象部分删除失败。逐阶段重新鉴权；错误不得标记 STORAGE_CLEANED／COMPLETED；重试只能处理原授权范围和未完成对象，不能因更换 token 越权；保留失败原因和 object 清单。现有永久删除套件沿用旧证据，本轮没有把这三个新增场景写成已通过，也不使用真实客户测试。

## 泄露密码保护

生产 Advisors 仍提示未启用。官方说明该功能需要 Pro 或以上套餐；当前未更改套餐、未启用、未批量重设账号密码。若日后启用，先核对已有套餐和配置、在隔离验证旧账号登录及 App／Website 对 WeakPasswordError 的处理，再安排用户改密流程。强度要求变化不等同于立即让全部旧密码失效；当前登录兼容性仍需实测。此项不阻塞已完成的两个匿名读取权限修复。依据：[Supabase Password security](https://supabase.com/docs/guides/auth/password-security)。
