#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="WindowStack"
SOURCE_DIR="WindowStack/Sources"
RESOURCE_DIR="WindowStack/Resources"
APP_DIR="dist/$APP_NAME.app"
EXT_DIR="$APP_DIR/Contents/PlugIns/WindowStackFinderSync.appex"
ARCH="$(uname -m)"
CERT_NAME="Local WindowStack Developer"
KEYCHAIN="$PWD/build/keychain/windowstack.keychain"

mkdir -p build/keychain

# 不加 -v：-v 只列受信任的身份，而 add-trusted-cert 需要 GUI 授权，
# 走 SSH 装机时拿不到。签名本身不要求证书受信任，有私钥就够了。
if ! security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$CERT_NAME"; then
  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  security create-keychain -p '' "$KEYCHAIN"
  security unlock-keychain -p '' "$KEYCHAIN"
  security set-keychain-settings -lut 21600 "$KEYCHAIN"

  openssl req \
    -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout build/keychain/windowstack.key.pem \
    -out build/keychain/windowstack.crt.pem \
    -subj "/CN=$CERT_NAME" \
    -addext 'basicConstraints=critical,CA:FALSE' \
    -addext 'keyUsage=digitalSignature' \
    -addext 'extendedKeyUsage=codeSigning' \
    >/dev/null 2>&1

  security import build/keychain/windowstack.crt.pem -k "$KEYCHAIN"
  security import build/keychain/windowstack.key.pem -k "$KEYCHAIN" -T /usr/bin/codesign -T /usr/bin/pluginkit
  security list-keychains -d user -s "$HOME/Library/Keychains/login.keychain-db" "$KEYCHAIN"
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k '' "$KEYCHAIN" >/dev/null 2>&1 || true
  # 需要 GUI 授权，SSH 下必然失败；信任只影响验签展示，不影响签名和运行
  security add-trusted-cert -d -r trustRoot -k "$KEYCHAIN" build/keychain/windowstack.crt.pem \
    || echo "warn: 证书未加入信任（需要图形界面授权），不影响签名与运行"
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$EXT_DIR/Contents/MacOS"

swiftc -O \
  -target "${ARCH}-apple-macos13.0" \
  -framework AppKit \
  -framework CoreVideo \
  -framework ApplicationServices \
  -framework Carbon \
  "$SOURCE_DIR/main.swift" \
  "$SOURCE_DIR/AppDelegate.swift" \
  "$SOURCE_DIR/WindowAnimator.swift" \
  "$SOURCE_DIR/WindowArranger.swift" \
  "$SOURCE_DIR/HotKeyManager.swift" \
  "$SOURCE_DIR/SettingsWindow.swift" \
  -o "$APP_DIR/Contents/MacOS/$APP_NAME"

swiftc -O \
  -target "${ARCH}-apple-macos13.0" \
  -parse-as-library \
  -module-name WindowStackFinderSync \
  -Xlinker -e -Xlinker _NSExtensionMain \
  -framework AppKit \
  -framework FinderSync \
  "$SOURCE_DIR/FinderSync.swift" \
  -o "$EXT_DIR/Contents/MacOS/WindowStackFinderSync"

cp "$RESOURCE_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$RESOURCE_DIR/FinderSync-Info.plist" "$EXT_DIR/Contents/Info.plist"
cp "$RESOURCE_DIR/WindowStack.icns" "$APP_DIR/Contents/Resources/"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

codesign --force --deep --sign "$CERT_NAME" --keychain "$KEYCHAIN" "$APP_DIR"
codesign --force --sign "$CERT_NAME" --keychain "$KEYCHAIN" --entitlements "$RESOURCE_DIR/FinderSync.entitlements" "$EXT_DIR"
xattr -cr "$APP_DIR" 2>/dev/null || true

echo "Built $APP_DIR"
