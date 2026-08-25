# Passport MDAC Desk

Passport MDAC Desk 是按 `passport-mdac-app-spec` 实现的 Flutter Android 首版。它将护照资料、OCR 人工确认、客户主档案和 MDAC 自动化任务放在同一个可追踪工作区中；办公室 Worker 与手机端通过任务边界协作。

当前版本是 **演示数据层 + 可替换 OCR 边界 + dry-run Worker**。它不连接真实 Supabase、不访问真实 Gmail、不打开真实 MDAC 网页，也不会提交真实注册。请不要在此版本上传真实护照或保存真实凭证。

## 运行与验证

需要 Flutter stable、Dart、Android SDK 和 JDK 21。项目根目录可执行：

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

生成的 Debug APK 位于 `build/app/outputs/flutter-apk/app-debug.apk`。手机端默认演示账号为 `owner@mdac.local`，密码为 `demo123`；也可使用 `operator1@mdac.local` 进入操作员视图。

## Supabase 真后端模式

Flutter 不把 URL 或 Publishable Key 硬编码进源码，而是通过 `dart-define` 注入。使用真实项目构建或运行时执行：

```bash
flutter run \
  --dart-define=SUPABASE_URL=https://xdmcxhvdqsbcqedfprcy.supabase.co \
  --dart-define=SUPABASE_PUBLISHABLE_KEY=你的_sb_publishable_key

flutter build apk --debug \
  --dart-define=SUPABASE_URL=https://xdmcxhvdqsbcqedfprcy.supabase.co \
  --dart-define=SUPABASE_PUBLISHABLE_KEY=你的_sb_publishable_key
```

真实模式会使用 Supabase Email/Password 登录，恢复已有会话，读取 `profiles`、`customers` 和 `automation_batches`，并把 OCR 确认建档与手机端任务写入数据库。未提供 `dart-define` 时仍会自动回退到演示模式，方便离线开发和测试。

首次真实登录前，需要在 Supabase Authentication 中创建一个测试用户，并在 `profiles` 中把该用户设置为 `OWNER`；公开注册保持关闭。当前版本不会在手机端持有创建任意用户所需的高权限密钥。

## Worker dry-run

```bash
python3 worker/dry_run_worker.py --output worker/demo_results.json
```

Worker 会验证客户必填字段、日期顺序、性别值和旧版网页选择器映射，并输出脱敏护照号、逐项成功/失败和心跳信息。结果中的 `submitted: false` 与 `result_confirmed: false` 是安全边界，不代表真实 MDAC 注册成功。

## 目录

| 路径 | 用途 |
|---|---|
| `lib/main.dart` | Flutter 首版界面、演示数据层、状态和核心业务交互 |
| `test/` | Repository 与 Widget 测试 |
| `worker/dry_run_worker.py` | 字段映射、队列领取、幂等和失败隔离演示 |
| `worker/README.md` | Worker 生产接入边界 |
| `docs/implementation-notes.md` | 规格映射、当前边界和生产接入清单 |
| `docs/preview-checks.md` | Web 预览检查记录 |

## 后续接入顺序

拿到 Supabase 项目后，先接 Auth、RLS、私有 Storage 和任务表；然后确定商业 OCR 供应商及置信度规则；最后在经过授权的办公室环境中替换 dry-run 网页适配器，并单独接入 Gmail IMAP 的 Message-ID 去重、护照号优先匹配和有限重试。真实执行必须保留“提交结果未知”状态，禁止在结果不明时立即重复提交。
