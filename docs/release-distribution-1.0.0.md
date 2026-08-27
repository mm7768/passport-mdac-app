# Passport MDAC Desk 1.0.0 内部 Release 分发说明

## 分发包

| 项目 | 信息 |
|---|---|
| 文件 | `app-release.apk` |
| 类型 | Android signed Release APK |
| 版本 | 1.0.0（versionCode 1） |
| 应用名称 | Passport MDAC Desk |
| applicationId | `com.example.passport_mdac_app` |
| 签名方案 | APK Signature Scheme v2，1 个签名者 |
| APK 大小 | 约 58 MB |
| SHA-256 | `cdbbb05601ab9e67a2dfc148deece8de95536fd227fa02aa537665e9cf8773f8` |
| Supabase | 已使用目标项目的公开 publishable key 构建，Service Role Key 未写入 APK |

## 安装方式

将 `app-release.apk` 通过公司内部安全渠道分别传给三位使用者，在 Android 手机上打开 APK 并允许该渠道安装未知来源应用，然后完成安装。安装后打开 Passport MDAC Desk，使用各自的 Supabase Email/Password 账号登录。

如果手机已经安装过同一 applicationId 的 Debug APK，Release APK 可能因为签名不同而不能直接覆盖安装。此时先确认 Supabase 云端数据已同步，再卸载 Debug 包后安装 Release 包。Supabase 中的客户、任务和设置数据不会因为卸载 APK 而删除；未同步的本地演示资料除外。

## 首次验收

安装后先不要使用真实护照。使用完全脱敏的测试账号和虚构资料确认登录、客户新增/编辑、录入日期/国家筛选、多选批量修改 `created_at`、护照低分辨率卡片和窄屏布局。后台 Worker 的测试仍必须遵守 fill-only、人工 CAPTCHA 和不提交限制。

## 更新规则

后续 Release 更新必须继续使用同一 applicationId 和同一签名密钥，并提高 versionCode。否则 Android 会把它视为不同应用或拒绝覆盖安装。当前签名密钥只保存在本地受保护目录 `android/signing/`，该目录已加入 `.gitignore`，没有放入 GitHub、APK 或本说明。不要删除、改名或上传该目录；签名密码也不要发送到聊天中。

当前版本不会自动从服务器更新 APK。后续版本需要重新构建签名 APK，并通过公司内部渠道重新分发；三位使用者在手机上手动安装更新。

## 构建状态

Release 构建曾遇到一次 Gradle daemon 异常退出，随后通过单 worker、无 daemon 和较低 JVM 内存参数重建成功。最终 APK 已通过 `flutter analyze`、全量 Flutter 测试、APK 签名验证、应用名称/包名/版本读取和 SHA-256 校验。

## 安全提醒

不要在测试中上传真实护照、真实 Gmail App Password、Azure Key、Supabase Service Role Key 或 Android 签名私钥。之前意外暴露过的旧 Supabase Service Role Key 如果尚未在 Supabase 端撤销/轮换，必须先完成轮换；本说明不包含任何密钥。
