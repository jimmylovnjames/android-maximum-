#!/usr/bin/env bash
# Installs everything Godot needs to turn REDLINE into an APK, then builds one.
#
#   tools/setup_android_export.sh [godot-binary]
#
# Nothing here is bundled with the repo because both pieces are large
# third-party downloads:
#
#   1. Godot's Android export templates   (~1 GB)  -> android_debug.apk template
#   2. Android SDK platform-tools + build-tools (~200 MB) -> apksigner, zipalign
#
# The default export preset uses Godot's prebuilt template, so the full Android
# Studio install and the Gradle path are NOT needed -- only the SDK command line
# tools, for signing and aligning the package.
#
# Requires: curl, unzip, a JDK (for keytool/apksigner). JDK 17 or newer.
set -euo pipefail

GODOT="${1:-${GODOT:-godot}}"
PRESET="Android arm64 (OnePlus 12 / Snapdragon 8 Gen 3)"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

command -v "$GODOT" >/dev/null || { echo "Godot not found: $GODOT"; exit 127; }
command -v curl >/dev/null    || { echo "curl is required"; exit 127; }
command -v unzip >/dev/null   || { echo "unzip is required"; exit 127; }
command -v keytool >/dev/null || { echo "a JDK is required (keytool not found)"; exit 127; }

VERSION="$("$GODOT" --headless --version | tail -1)"   # 4.5.stable.official.<hash>
SHORT="$(cut -d. -f1,2 <<<"$VERSION")"                 # 4.5
CHANNEL="$(cut -d. -f3 <<<"$VERSION")"                 # stable
TAG="${SHORT}-${CHANNEL}"
TPL_DIR="${HOME}/.local/share/godot/export_templates/${SHORT}.${CHANNEL}"
SDK_DIR="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/android-sdk}}"
CMDLINE_ZIP="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
BUILD_TOOLS_VERSION="34.0.0"
PLATFORM_VERSION="34"

echo "Godot            : $VERSION"
echo "Export templates : $TPL_DIR"
echo "Android SDK      : $SDK_DIR"
echo

# --------------------------------------------------------------------------
# 1. Export templates
# --------------------------------------------------------------------------
if [ -f "${TPL_DIR}/android_debug.apk" ]; then
  echo "[1/4] export templates already installed"
else
  echo "[1/4] downloading export templates for ${TAG} (~1 GB) ..."
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  curl -fL --retry 3 --retry-delay 4 -o "${TMP}/templates.tpz" \
    "https://github.com/godotengine/godot/releases/download/${TAG}/Godot_v${TAG}_export_templates.tpz"
  unzip -q -o "${TMP}/templates.tpz" -d "$TMP"
  mkdir -p "$TPL_DIR"
  cp -f "${TMP}/templates/"* "$TPL_DIR/"
  echo "      installed $(ls "$TPL_DIR" | wc -l) template files"
fi

# --------------------------------------------------------------------------
# 2. Android SDK command line tools (for apksigner + zipalign + adb)
# --------------------------------------------------------------------------
if [ -d "${SDK_DIR}/build-tools" ] && [ -d "${SDK_DIR}/platform-tools" ]; then
  echo "[2/4] Android SDK build-tools and platform-tools already present"
else
  echo "[2/4] installing Android SDK command line tools into ${SDK_DIR} ..."
  mkdir -p "${SDK_DIR}/cmdline-tools"
  TMP2="$(mktemp -d)"
  curl -fL --retry 3 -o "${TMP2}/cmdline.zip" "$CMDLINE_ZIP"
  unzip -q -o "${TMP2}/cmdline.zip" -d "$TMP2"
  rm -rf "${SDK_DIR}/cmdline-tools/latest"
  mv "${TMP2}/cmdline-tools" "${SDK_DIR}/cmdline-tools/latest"
  rm -rf "$TMP2"
  yes | "${SDK_DIR}/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$SDK_DIR" --licenses >/dev/null
  "${SDK_DIR}/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$SDK_DIR" \
    "platform-tools" "build-tools;${BUILD_TOOLS_VERSION}" "platforms;android-${PLATFORM_VERSION}"
fi

# --------------------------------------------------------------------------
# 3. Debug keystore + editor settings
# --------------------------------------------------------------------------
if [ ! -f tools/debug.keystore ]; then
  echo "[3/4] creating debug keystore ..."
  keytool -keyalg RSA -genkeypair -alias androiddebugkey -keypass android \
    -keystore tools/debug.keystore -storepass android \
    -dname "CN=REDLINE Debug,O=REDLINE,C=NZ" -validity 10000 -deststoretype pkcs12
else
  echo "[3/4] debug keystore present"
fi

# Godot reads the SDK location from editor settings, not from the project.
SETTINGS_DIR="${HOME}/.config/godot"
SETTINGS="${SETTINGS_DIR}/editor_settings-${SHORT}.tres"
mkdir -p "$SETTINGS_DIR"
if [ ! -f "$SETTINGS" ]; then
  "$GODOT" --headless --editor --quit --path "$ROOT" >/dev/null 2>&1 || true
fi
python3 - "$SETTINGS" "$SDK_DIR" "$ROOT/tools/debug.keystore" <<'PYEOF'
import sys, pathlib, re
path, sdk, keystore = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
wanted = {
    "export/android/android_sdk_path": sdk,
    "export/android/debug_keystore": keystore,
    "export/android/debug_keystore_user": "androiddebugkey",
    "export/android/debug_keystore_pass": "android",
}
if not path.exists():
    body = "\n".join('%s = "%s"' % (k, v) for k, v in wanted.items())
    path.write_text('[gd_resource type="EditorSettings" format=3]\n\n[resource]\n' + body + "\n")
else:
    text = path.read_text()
    for k, v in wanted.items():
        line = '%s = "%s"' % (k, v)
        if re.search(r'(?m)^%s\s*=' % re.escape(k), text):
            text = re.sub(r'(?m)^%s\s*=.*$' % re.escape(k), line, text)
        else:
            text = text.rstrip("\n") + "\n" + line + "\n"
    path.write_text(text)
print("      editor settings updated:", path)
PYEOF

# --------------------------------------------------------------------------
# 4. Build
# --------------------------------------------------------------------------
echo "[4/4] exporting APK ..."
mkdir -p export
"$GODOT" --headless --path "$ROOT" --export-debug "$PRESET" "export/redline-arm64.apk"
ls -la export/
echo
echo "Install on a connected device with:"
echo "  ${SDK_DIR}/platform-tools/adb install -r export/redline-arm64.apk"
