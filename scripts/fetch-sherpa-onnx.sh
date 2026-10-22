#!/bin/bash
# Downloads sherpa-onnx's iOS framework (on-device Kokoro voice) into Vendor/.
# It's 81 MB, so it stays out of git. Run once per checkout, then `xcodegen`.
set -euo pipefail
VERSION=1.13.8
cd "$(dirname "$0")/.."
if [ -d Vendor/SherpaOnnxC.xcframework ]; then echo "Vendor/SherpaOnnxC.xcframework is already there."; exit 0; fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# The same build the Flutter sherpa_onnx package ships (pub.dev/packages/sherpa_onnx_ios).
curl -fL "https://pub.dev/api/archives/sherpa_onnx_ios-$VERSION.tar.gz" -o "$tmp/pkg.tar.gz"
tar xzf "$tmp/pkg.tar.gz" -C "$tmp" ios/sherpa_onnx_ios/SherpaOnnxC.xcframework
mkdir -p Vendor
mv "$tmp/ios/sherpa_onnx_ios/SherpaOnnxC.xcframework" Vendor/
echo "Done: Vendor/SherpaOnnxC.xcframework ($VERSION)"
