#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

VERSION="1.0.0"
DIST_DIR="${PROJECT_ROOT}/dist"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

echo "=== Сборка релизных бандлов YandexMusicMac v${VERSION} ==="

for ARCH in universal arm64 x86_64; do
    echo ""
    echo "--> Сборка для архитектуры: $ARCH"
    ./scripts/build_app.sh "$ARCH"
    ZIP_NAME="YandexMusicMac-v${VERSION}-${ARCH}.zip"
    echo "--> Упаковка в $ZIP_NAME..."
    rm -f "${DIST_DIR}/${ZIP_NAME}"
    ditto -c -k --sequesterRsrc --keepParent YandexMusicMac.app "${DIST_DIR}/${ZIP_NAME}"
done

echo ""
echo "=== Все релизные архивы собраны в ${DIST_DIR}: ==="
ls -lh "${DIST_DIR}"
