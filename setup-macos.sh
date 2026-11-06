#!/bin/bash
# Compatible with the /bin/bash 3.2 supplied by macOS.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
PACKAGE="$ROOT"
APP=""
KEYS=""
ARCH=""
DESTINATION="$HOME/Library/Application Support/InDe"
CHECK_ONLY=0
BASE_URL=https://github.com/Indigo2233/InDe-Suite/releases/download/v1.0.2-local
fail() { echo "ERROR: $*" >&2; exit 1; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --package-directory) PACKAGE="$2"; shift 2 ;;
    --pixinsight-app) APP="$2"; shift 2 ;;
    --keys-file) KEYS="$2"; shift 2 ;;
    --destination) DESTINATION="$2"; shift 2 ;;
    --arch) ARCH="$2"; shift 2 ;;
    --check-only) CHECK_ONLY=1; shift ;;
    *) fail "Unknown option: $1" ;;
  esac
done
[[ "$(uname -s)" == Darwin ]] || fail '需要 macOS 14 或更高版本。'
[[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ]] || fail '需要 macOS 14 或更高版本。'
if [[ -z "$APP" ]]; then
  for candidate in /Applications/PixInsight/PixInsight.app /Applications/PixInsight.app "$HOME/Applications/PixInsight.app"; do
    if [[ -d "$candidate" ]]; then APP="$candidate"; break; fi
  done
fi
if [[ -z "$APP" && $CHECK_ONLY == 0 ]]; then
  APP="$(osascript -e 'POSIX path of (choose file with prompt "选择 PixInsight.app" of type {"com.apple.application-bundle"})')"
fi
[[ -d "$APP" ]] || fail '找不到 PixInsight.app，请使用 --pixinsight-app 指定位置。'
APP="$(cd "$APP" && pwd -P)"
EXE="$APP/Contents/MacOS/PixInsight"
[[ -x "$EXE" ]] || fail "找不到 PixInsight 可执行文件：$EXE"
PI_ARCHS="$(/usr/bin/lipo -archs "$EXE")"
if [[ -z "$ARCH" ]]; then
  case "$PI_ARCHS" in
    arm64|x86_64) ARCH="$PI_ARCHS" ;;
    *) ARCH="$(uname -m)" ;;
  esac
fi
case "$ARCH" in arm64|x86_64) ;; *) fail "Unsupported architecture: $ARCH" ;; esac
[[ " $PI_ARCHS " == *" $ARCH "* ]] || fail "PixInsight 架构 $PI_ARCHS 与所选 $ARCH 不匹配。"
echo "PixInsight: $APP"
echo "Architecture: $ARCH"
echo '若 PixInsight 使用 Rosetta 运行，请选择 x86_64 安装包并使用 --arch x86_64。'

# The small launcher downloads an archive for the actual PixInsight architecture.
if [[ ! -f "$PACKAGE/InDe-pxm.dylib" ]]; then
  [[ $CHECK_ONLY == 0 ]] || fail '--check-only 需要已解压的完整安装包。'
  CACHE="$HOME/Library/Caches/InDeInstaller"
  mkdir -p "$CACHE"
  NAME="InDe-1.0.2-local-macos-$ARCH"
  SUMS="$CACHE/SHA256SUMS-macos-$ARCH.txt"
  curl --fail --location --retry 3 "$BASE_URL/SHA256SUMS-macos-$ARCH.txt" -o "$SUMS"
  EXPECTED="$(awk -v name="$NAME.tar.gz" '$2 == name {print $1}' "$SUMS")"
  [[ "$EXPECTED" =~ ^[0-9a-f]{64}$ ]] || fail '下载的校验清单无效。'
  ARCHIVE="$CACHE/$NAME.tar.gz"
  if [[ ! -f "$ARCHIVE" || "$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)" != "$EXPECTED" ]]; then
    curl --fail --location --retry 3 "$BASE_URL/$NAME.tar.gz" -o "$ARCHIVE.part"
    [[ "$(shasum -a 256 "$ARCHIVE.part" | cut -d' ' -f1)" == "$EXPECTED" ]] || fail '下载文件 SHA-256 不匹配。'
    mv "$ARCHIVE.part" "$ARCHIVE"
  fi
  EXTRACT="$(mktemp -d "$CACHE/unpack.XXXXXX")"
  tar -xzf "$ARCHIVE" -C "$EXTRACT"
  PACKAGE="$EXTRACT/$NAME"
fi
PACKAGE="$(cd "$PACKAGE" && pwd -P)"
PRIVATE_FILES="$(find "$PACKAGE" \( -iname '*.xssk' -o -iname '*.xsgn' \) -print -quit)"
[[ -z "$PRIVATE_FILES" ]] || fail '请将个人密钥和签名保存在发行包之外，再重新运行。'
[[ "$(cat "$PACKAGE/architecture.txt")" == "$ARCH" ]] || fail '安装包架构与 PixInsight 不匹配，请下载匹配的完整包或小型安装入口。'
echo '正在校验完整安装包…'
[[ -s "$PACKAGE/package-sha256.txt" ]] || fail '缺少校验清单。'
VERIFY_LOG="$(mktemp -t inde-verify)"
if ! (cd "$PACKAGE" && shasum -a 256 -c package-sha256.txt) >"$VERIFY_LOG" 2>&1; then
  tail -n 20 "$VERIFY_LOG"; rm -f "$VERIFY_LOG"; fail '安装包文件损坏，请重新下载。'
fi
rm -f "$VERIFY_LOG"
while IFS=$'\t' read -r target relative; do
  [[ -n "$relative" ]] || continue
  [[ "$target" != /* ]] || fail "Absolute symlink: $relative"
  [[ -L "$PACKAGE/$relative" && "$(readlink "$PACKAGE/$relative")" == "$target" ]] || fail "Symlink mismatch: $relative"
  target_directory="$(cd "$(dirname "$PACKAGE/$relative")/$(dirname "$target")" && pwd -P)"
  [[ "$target_directory/" == "$PACKAGE/"* ]] || fail "External symlink: $relative"
done < "$PACKAGE/package-links.txt"
[[ "$(lipo -archs "$PACKAGE/InDe-pxm.dylib")" == "$ARCH" ]] || fail '模块架构无效。'
[[ "$(lipo -archs "$PACKAGE/InDeBackend/runtime/bin/python3")" == "$ARCH" ]] || fail 'Python 架构无效。'
codesign --verify --strict "$PACKAGE/InDe-pxm.dylib"
for file in engine/run_models.py engine/models/InDeConv.onnx engine/models/InDeNoise.onnx engine/models/InDeStars.onnx tools/inde_worker.py tools/inde_runtime.py; do
  [[ -f "$PACKAGE/InDeBackend/$file" ]] || fail "Missing: $file"
done
if [[ $CHECK_ONLY == 1 ]]; then echo '校验通过。'; exit 0; fi
pgrep -x PixInsight >/dev/null && fail '请保存图像并完全退出 PixInsight，然后重新运行安装。'
if [[ -z "$KEYS" ]]; then
  osascript <<'APPLESCRIPT'
display dialog "首次安装前，请在 PixInsight 中完成：\n\n1. Script > Development > SigningKeys\n勾选 Generate Signing Keys、Local signing identity，保存 .xssk。\n2. Edit > Local Signing Identity\n选择该文件并勾选 Make the local signing identity persistent。\n3. 保存图像并退出 PixInsight。\n\n下一步选择您自己的 .xssk 文件。密码仅在 PixInsight 窗口输入。" buttons {"取消", "选择已有密钥"} default button "选择已有密钥"
APPLESCRIPT
  KEYS="$(osascript -e 'POSIX path of (choose file with prompt "选择自己的 PixInsight 本地签名密钥 .xssk")')"
fi
[[ -f "$KEYS" && "$KEYS" == *.xssk ]] || fail '请选择现有的 .xssk 文件。'
KEYS="$(cd "$(dirname "$KEYS")" && pwd -P)/$(basename "$KEYS")"
case "$DESTINATION" in /*) ;; *) fail '安装目录必须为绝对路径。' ;; esac
[[ ! -L "$DESTINATION" ]] || fail '安装目录不能是符号链接。'
mkdir -p "$(dirname "$DESTINATION")"
DESTINATION="$(cd "$(dirname "$DESTINATION")" && pwd -P)/$(basename "$DESTINATION")"
case "$DESTINATION" in /|/Applications|"$HOME"|"$HOME/Library"|"$HOME/Library/Application Support"|*/.|*/..) fail '安装目录不安全。' ;; esac
[[ "$DESTINATION/" != "$PACKAGE/"* && "$PACKAGE/" != "$DESTINATION/"* && "$DESTINATION/" != "$APP/"* && "$APP/" != "$DESTINATION/"* ]] || fail '安装目录与源文件或 PixInsight.app 重叠。'
if [[ -e "$DESTINATION" && ! -f "$DESTINATION/.inde-managed" ]]; then
  fail '目标目录已存在且并非由本安装器管理，请使用 --destination 指定一个新的 InDe 目录。'
fi
STAGE="$(mktemp -d "$(dirname "$DESTINATION")/.inde-install.XXXXXX")"
cleanup() {
  if [[ -n "${STAGE:-}" && "$STAGE" == "$(dirname "$DESTINATION")/.inde-install."* ]]; then rm -rf -- "$STAGE"; fi
}
trap cleanup EXIT
ditto "$PACKAGE" "$STAGE"
# Clear quarantine only from this checksum-verified staged package.
xattr -dr com.apple.quarantine "$STAGE" 2>/dev/null || true
echo 'PixInsight 将显示密码窗口，请在该窗口中输入本地签名密码。'
arch "-$ARCH" "$EXE" "--sign-module-file=$STAGE/InDe-pxm.dylib" "--xssk-file=$KEYS"
[[ -s "$STAGE/InDe-pxm.xsgn" ]] || fail 'PixInsight 未生成本地签名。'
[[ "$(shasum -a 256 "$STAGE/InDe-pxm.dylib" | cut -d' ' -f1)" == "$(shasum -a 256 "$PACKAGE/InDe-pxm.dylib" | cut -d' ' -f1)" ]] || fail '签名期间模块文件发生变化。'
pgrep -x PixInsight >/dev/null && fail '替换文件前请完全退出 PixInsight，然后重新运行安装。'
touch "$STAGE/.inde-managed"
BACKUP=""
if [[ -e "$DESTINATION" ]]; then
  BACKUP="$DESTINATION.backup-$(date +%Y%m%d-%H%M%S)"
  [[ ! -e "$BACKUP" ]] || fail "备份目录已存在：$BACKUP"
  mv "$DESTINATION" "$BACKUP"
fi
if ! mv "$STAGE" "$DESTINATION"; then
  if [[ -n "$BACKUP" ]]; then mv "$BACKUP" "$DESTINATION"; fi
  fail '安装失败，已尝试恢复旧版本。'
fi
STAGE=""
echo "安装完成：$DESTINATION"
echo '启动 PixInsight，打开 Process > Modules > Install Modules，选择上方目录并执行 Search / Install，然后重启。'
echo "验证脚本：$DESTINATION/test/native-selftest.js"
[[ -z "$BACKUP" ]] || echo "旧版本备份：$BACKUP"
open "$DESTINATION"
