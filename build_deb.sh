#!/bin/bash
set -e

echo "========================================================"
echo "   BUILDING iOS .deb PACKAGE FOR ACBFACE"
echo "========================================================"

# 1. Kiem tra SDK
SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path)
echo "Using iOS SDK: $SDK_PATH"

# 2. Bien dich Mach-O ARM64 bang Clang chinh thuc cua Apple
echo "Compiling ARM64 binary..."
xcrun -sdk iphoneos clang -arch arm64 \
    -miphoneos-version-min=14.0 \
    -fobjc-arc \
    -isysroot "$SDK_PATH" \
    -framework UIKit \
    -framework AVFoundation \
    -framework CoreGraphics \
    -framework CoreImage \
    -framework QuartzCore \
    -lz \
    src/main.m \
    src/AppDelegate.m \
    src/ViewController.m \
    src/CameraManager.m \
    src/ZipManager.m \
    src/ACBUploader.m \
    -o ACBFace

echo "Code signing with entitlements..."
codesign -s - --entitlements entitlements.plist -f ACBFace

# 3. Tao Bundle /Applications/ACBFace.app
echo "Creating ACBFace.app bundle..."
rm -rf deb_root packages
mkdir -p deb_root/Applications/ACBFace.app
mkdir -p deb_root/DEBIAN
mkdir -p packages

mv ACBFace deb_root/Applications/ACBFace.app/
cp Info.plist deb_root/Applications/ACBFace.app/
cp control deb_root/DEBIAN/control
if [ -f layout/DEBIAN/postinst ]; then
    cp layout/DEBIAN/postinst deb_root/DEBIAN/postinst
    chmod 755 deb_root/DEBIAN/postinst
fi

# 4. Dong goi .deb
echo "Packaging .deb..."
dpkg-deb -Zgzip --root-owner-group -b deb_root packages/ACBFace_1.0.0_iphoneos-arm64.deb

echo "========================================================"
echo "BUILD SUCCESS!"
ls -lh packages/*.deb
echo "========================================================"
