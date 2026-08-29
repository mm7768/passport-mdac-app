#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

FLUTTER_BIN="${FLUTTER_BIN:-flutter}"
SUPABASE_URL="${SUPABASE_URL:-https://xdmcxhvdqsbcqedfprcy.supabase.co}"

if [[ -z "${SUPABASE_PUBLISHABLE_KEY:-}" ]]; then
  echo "缺少 SUPABASE_PUBLISHABLE_KEY。请提供 publishable key，不要使用 Service Role Key。" >&2
  exit 1
fi

if [[ ! -f android/key.properties ]]; then
  echo "缺少 android/key.properties；请先按 docs/how-to-rebuild-release.md 配置签名。" >&2
  exit 1
fi

if [[ ! -f android/signing/passport_mdac_release.jks ]]; then
  echo "缺少 android/signing/passport_mdac_release.jks；必须使用原签名 keystore 才能覆盖更新。" >&2
  exit 1
fi

"$FLUTTER_BIN" pub get
"$FLUTTER_BIN" analyze
"$FLUTTER_BIN" test
"$FLUTTER_BIN" build apk --release \
  --dart-define=SUPABASE_URL="$SUPABASE_URL" \
  --dart-define=SUPABASE_PUBLISHABLE_KEY="$SUPABASE_PUBLISHABLE_KEY"

APK_PATH="build/app/outputs/flutter-apk/app-release.apk"
if [[ ! -s "$APK_PATH" ]]; then
  echo "Release APK 未生成：$APK_PATH" >&2
  exit 1
fi

ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [[ -n "$ANDROID_HOME" ]]; then
  APKSIGNER="$(find "$ANDROID_HOME/build-tools" -type f -name apksigner 2>/dev/null | sort -V | tail -1 || true)"
  if [[ -n "$APKSIGNER" ]]; then
    "$APKSIGNER" verify --verbose "$APK_PATH" | grep -E 'Verified using|Number of signers|Signer #1 certificate SHA-256 digest' || true
  fi
fi

sha256sum "$APK_PATH"
printf 'Release APK: %s\n' "$ROOT_DIR/$APK_PATH"
