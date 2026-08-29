# 如何自行重新生成 Passport MDAC Desk 签名 Release APK

## 先理解签名规则

要让新版本直接覆盖旧版本，必须同时保持以下条件不变：

| 项目 | 要求 |
|---|---|
| `applicationId` | 保持 `com.example.passport_mdac_app` |
| 签名 keystore | 必须使用同一份 `passport_mdac_release.jks` |
| key alias | `passport-mdac-release` |
| `versionCode` | 每次更新必须递增 |
| `versionName` | 按版本需要递增，例如 `1.0.1` |

当前 Release 使用的签名私钥没有放在 GitHub、APK 或聊天附件中。要在另一台电脑继续发布同一个应用，必须通过你自己的安全渠道取得并保存这份 keystore；不要把 keystore、密码或私钥发到聊天、GitHub、普通群组或公开网盘。

如果没有原来的 keystore，不要随意生成新 key 后尝试覆盖旧 APK。Android 会因为签名不同而拒绝更新。此时只能卸载旧 APK 后安装新签名包，或者重新规划新的 applicationId 和正式签名方案。

## 环境要求

在自己的电脑安装 Flutter、Android SDK、Android SDK Build Tools 和 Java 17。然后克隆私有仓库：

```bash
git clone https://github.com/mm7768/passport-mdac-app.git
cd passport-mdac-app
git checkout main
```

项目当前使用 Flutter Android，版本号位于 `pubspec.yaml`。Android Release 签名配置位于 `android/app/build.gradle.kts`，而 `android/key.properties` 和 `android/signing/` 被 `.gitignore` 排除，不会从 GitHub 自动取得。

## 放置签名文件

在项目目录创建以下本地文件和目录：

```text
android/key.properties
android/signing/passport_mdac_release.jks
```

`android/key.properties` 的格式如下，但请把密码替换为原 keystore 的真实密码；不要把真实密码写入 GitHub：

```properties
storePassword=你的_keystore_密码
keyPassword=你的_key_密码
keyAlias=passport-mdac-release
storeFile=signing/passport_mdac_release.jks
```

设置权限：

```bash
chmod 600 android/key.properties
chmod 600 android/signing/passport_mdac_release.jks
```

如果这是全新应用而不是更新当前 1.0.0，可以用 `keytool` 生成新的 keystore；但新 key 不能用于覆盖当前已经分发的 APK：

```bash
mkdir -p android/signing
keytool -genkeypair \
  -v \
  -keystore android/signing/passport_mdac_release.jks \
  -storetype PKCS12 \
  -alias passport-mdac-release \
  -keyalg RSA \
  -keysize 4096 \
  -validity 10000 \
  -dname "CN=Passport MDAC Desk, OU=Internal, O=MDAC, C=MY"
```

## 准备 Supabase 构建参数

只使用 Supabase **publishable key**，不要使用 Service Role Key。推荐在终端隐藏输入：

```bash
read -rsp "Supabase publishable key: " SUPABASE_PUBLISHABLE_KEY
echo
export SUPABASE_PUBLISHABLE_KEY
export SUPABASE_URL="https://xdmcxhvdqsbcqedfprcy.supabase.co"
```

如果你使用的是自己电脑的 Flutter 路径，可以设置：

```bash
export FLUTTER_BIN=/你的路径/flutter/bin/flutter
```

## 一键构建

仓库内的构建脚本会检查签名文件，执行依赖同步、静态分析、全量测试、Release 构建、签名验证和 SHA-256 输出：

```bash
chmod +x scripts/build_release.sh
./scripts/build_release.sh
```

成功后文件位于：

```text
build/app/outputs/flutter-apk/app-release.apk
```

构建完成后清除当前终端中的公开 key：

```bash
unset SUPABASE_PUBLISHABLE_KEY
unset SUPABASE_URL
unset FLUTTER_BIN
```

## 手动构建命令

如果不使用脚本，可按以下顺序执行：

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --release \
  --dart-define=SUPABASE_URL=https://xdmcxhvdqsbcqedfprcy.supabase.co \
  --dart-define=SUPABASE_PUBLISHABLE_KEY="$SUPABASE_PUBLISHABLE_KEY"
```

检查 APK：

```bash
apksigner verify --verbose build/app/outputs/flutter-apk/app-release.apk
sha256sum build/app/outputs/flutter-apk/app-release.apk
```

## 修改代码后的版本流程

每次修改功能后，先运行脚本确认测试通过，再修改 `pubspec.yaml` 的版本号。例如：

```yaml
version: 1.0.1+2
```

其中 `1.0.1` 是用户看到的版本，`2` 是 Android 用于判断升级顺序的 versionCode。提交源码时不要提交 `android/key.properties`、`android/signing/`、真实客户资料、真实护照、任何 Service Role Key、Azure Key、Gmail App Password 或签名私钥。

## 三人内部发放

通过公司内部安全渠道发送 `app-release.apk`。如果手机已有同 applicationId 的 Debug APK，因为 Debug key 和 Release key 不同，可能不能覆盖安装；确认云端数据同步后先卸载 Debug 版，再安装 Release 版。后续正式 Release 只要使用同一 keystore 并递增 versionCode，就可以直接覆盖安装。

当前应用不会自动更新 APK。以后每次发布都需要重新构建并通过内部渠道分发。Supabase 云端资料不会因为卸载 APK 而删除，但尚未同步的本地演示数据不在此保证范围内。

## 当前版本参考

当前已构建的 1.0.0 Release APK SHA-256 为：

```text
cdbbb05601ab9e67a2dfc148deece8de95536fd227fa02aa537665e9cf8773f8
```

这只是当前文件的校验值；每次重新构建都应重新计算并记录新的 SHA-256。
