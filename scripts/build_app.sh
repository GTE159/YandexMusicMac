#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

TARGET_ARCH="${1:-universal}"
OUTPUT_DIR="${2:-}"
APP_VERSION="${APP_VERSION:-2.3}"
if [ -n "$OUTPUT_DIR" ]; then
    mkdir -p "$OUTPUT_DIR"
    APP_NAME="${OUTPUT_DIR%/}/flow~.app"
else
    APP_NAME="flow~.app"
fi
CONTENTS="$APP_NAME/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "=== Сборка flow~ v${APP_VERSION} (Архитектура: $TARGET_ARCH) ==="

mkdir -p .build/bin

resolve_bin() {
    local triple="$1"
    local scratch="$2"
    local bin_dir
    bin_dir="$(swift build -c release --triple "$triple" --scratch-path "$scratch" --show-bin-path 2>/dev/null || true)"
    if [ -n "$bin_dir" ] && [ -f "${bin_dir}/YandexMusicMac" ]; then
        echo "${bin_dir}/YandexMusicMac"
        return 0
    fi
    if [ -f "${scratch}/out/Products/Release/YandexMusicMac" ]; then
        echo "${scratch}/out/Products/Release/YandexMusicMac"
        return 0
    fi
    if [ -f "${scratch}/release/YandexMusicMac" ]; then
        echo "${scratch}/release/YandexMusicMac"
        return 0
    fi
    echo "Ошибка: не найден собранный бинарник в ${scratch}" >&2
    exit 1
}

case "$TARGET_ARCH" in
  arm64)
    echo "Компиляция arm64 (Apple Silicon)..."
    swift build -c release --triple arm64-apple-macosx14.0 --scratch-path .build/arm64 --product YandexMusicMac
    ARM_BIN="$(resolve_bin arm64-apple-macosx14.0 .build/arm64)"
    cp "$ARM_BIN" .build/bin/YandexMusicMac
    ;;
  x86_64|intel)
    echo "Компиляция x86_64 (Intel)..."
    swift build -c release --triple x86_64-apple-macosx14.0 --scratch-path .build/x86_64 --product YandexMusicMac
    X86_BIN="$(resolve_bin x86_64-apple-macosx14.0 .build/x86_64)"
    cp "$X86_BIN" .build/bin/YandexMusicMac
    ;;
  universal)
    echo "Компиляция arm64 (Apple Silicon)..."
    swift build -c release --triple arm64-apple-macosx14.0 --scratch-path .build/arm64 --product YandexMusicMac
    ARM_BIN="$(resolve_bin arm64-apple-macosx14.0 .build/arm64)"
    echo "Компиляция x86_64 (Intel)..."
    swift build -c release --triple x86_64-apple-macosx14.0 --scratch-path .build/x86_64 --product YandexMusicMac
    X86_BIN="$(resolve_bin x86_64-apple-macosx14.0 .build/x86_64)"
    echo "Создание Universal Binary (lipo)..."
    lipo -create "$ARM_BIN" "$X86_BIN" -output .build/bin/YandexMusicMac
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

cat << EOF > "$CONTENTS/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>ru</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>ru</string>
    </array>
    <key>CFBundleExecutable</key>
    <string>YandexMusicMac</string>
    <key>CFBundleIdentifier</key>
    <string>com.yandexmusic.mac.client</string>
    <key>CFBundleName</key>
    <string>flow~</string>
    <key>CFBundleDisplayName</key>
    <string>flow~</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${APP_VERSION}</string>
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

if [ -d "Sources/YandexMusicMac/Resources/ru.lproj" ]; then
    cp -R "Sources/YandexMusicMac/Resources/ru.lproj" "$RESOURCES/"
fi

echo "Локальная подпись приложения..."
codesign --force --deep --sign - "$APP_NAME"

echo "Готово! Собрано: $APP_NAME ($TARGET_ARCH)"
