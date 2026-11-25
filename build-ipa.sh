#!/bin/bash
# 本地打包未签名 IPA（需要 Mac + Xcode）
# 用法：./build-ipa.sh
set -e
cd "$(dirname "$0")"

echo "==> Building ErasePen (Release, unsigned)..."
xcodebuild -project ErasePen/ErasePen.xcodeproj \
  -scheme ErasePen \
  -sdk iphoneos \
  -configuration Release \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

echo "==> Locating ErasePen.app..."
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData -name "ErasePen.app" -type d | head -n 1)
if [ -z "$APP_PATH" ]; then
  echo "错误：未找到 ErasePen.app，请检查上面 xcodebuild 是否成功。"
  exit 1
fi
echo "Found: $APP_PATH"

echo "==> Packaging IPA..."
rm -rf Payload ErasePen-unsigned.ipa
mkdir Payload
cp -r "$APP_PATH" Payload/
zip -r ErasePen-unsigned.ipa Payload
rm -rf Payload

echo "==> Done: $(pwd)/ErasePen-unsigned.ipa"
ls -lh ErasePen-unsigned.ipa
