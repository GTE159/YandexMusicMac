#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

TARGET_ARCH="${1:-universal}"
APP_NAME="YandexMusicMac.app"
CONTENTS="$APP_NAME/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "=== Сборка YandexMusicMac (Архитектура: $TARGET_ARCH) ==="

mkdir -p .build/bin

case "$TARGET_ARCH" in
  arm64)
    echo "Компиляция arm64 (Apple Silicon)..."
    swift build -c release --triple arm64-apple-macosx14.0 --scratch-path .build/arm64 --product YandexMusicMac
    cp .build/arm64/out/Products/Release/YandexMusicMac .build/bin/YandexMusicMac
    ;;
  x86_64|intel)
    echo "Компиляция x86_64 (Intel)..."
    swift build -c release --triple x86_64-apple-macosx14.0 --scratch-path .build/x86_64 --product YandexMusicMac
    cp .build/x86_64/out/Products/Release/YandexMusicMac .build/bin/YandexMusicMac
    ;;
  universal)
    echo "Компиляция arm64 (Apple Silicon)..."
    swift build -c release --triple arm64-apple-macosx14.0 --scratch-path .build/arm64 --product YandexMusicMac
    echo "Компиляция x86_64 (Intel)..."
    swift build -c release --triple x86_64-apple-macosx14.0 --scratch-path .build/x86_64 --product YandexMusicMac
    echo "Создание Universal Binary (lipo)..."
    lipo -create \
      .build/arm64/out/Products/Release/YandexMusicMac \
      .build/x86_64/out/Products/Release/YandexMusicMac \
      -output .build/bin/YandexMusicMac
    ;;
  *)
    echo "Неизвестная архитектура: $TARGET_ARCH. Доступны: universal, arm64, x86_64"
    exit 1
    ;;
esac

echo "Архитектура исполняемого файла:"
file .build/bin/YandexMusicMac

echo "Создание структуры бандла $APP_NAME..."
rm -rf "$APP_NAME"
mkdir -p "$MACOS"
mkdir -p "$RESOURCES"

cp .build/bin/YandexMusicMac "$MACOS/YandexMusicMac"

cat << 'EOF' > "$CONTENTS/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>YandexMusicMac</string>
    <key>CFBundleIdentifier</key>
    <string>com.yandexmusic.mac.client</string>
    <key>CFBundleName</key>
    <string>YandexMusicMac</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$RESOURCES/"
fi

echo "Локальная подпись приложения..."
codesign --force --deep --sign - "$APP_NAME"

echo "Готово! Собрано: $APP_NAME ($TARGET_ARCH)"
