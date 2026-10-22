#!/usr/bin/env bash
# Rebuilds binaries/ from fixture.c. The outputs are committed so the tests
# need no compiler; rerun this only to change a fixture, then update the
# expectations in MachOImageTests (a different toolchain gives different UUIDs).
#
#   ios-arm64.dylib   thin arm64 iOS 16.0 dylib: install name, rpath, a weak
#                     framework, ad-hoc signed by ldid with entitlements
#   macos-fat         arm64 + x86_64 macOS 13.0 executable, ad-hoc signed
#   ios-arm64e-unsigned  thin arm64e iOS 16.0 executable, no signature

set -Eeuo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
out="$here/binaries"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/apelin-macho-fixture.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$out"

ios_sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
mac_sdk="$(xcrun --sdk macosx --show-sdk-path)"
# No build path in a committed binary.
flags=(-Os -g0 -ffile-prefix-map="$here"=. -Wl,-dead_strip)

xcrun clang -target arm64-apple-ios16.0 -isysroot "$ios_sdk" "${flags[@]}" \
    -dynamiclib -install_name @rpath/ApelinFixture.dylib \
    -Wl,-rpath,@loader_path/Frameworks -weak_framework CoreFoundation \
    "$here/fixture.c" -o "$scratch/ios-arm64.dylib"
xcrun strip -x "$scratch/ios-arm64.dylib"
cat >"$scratch/entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>wiki.qaq.apelin.fixture</key>
	<true/>
</dict>
</plist>
PLIST
# ldid, as Scripts/package-deb.sh signs: codesign drops entitlements on a dylib.
ldid -S"$scratch/entitlements.plist" -Cadhoc -Iwiki.qaq.apelin.fixture "$scratch/ios-arm64.dylib"
cp "$scratch/ios-arm64.dylib" "$out/ios-arm64.dylib"

for arch in arm64 x86_64; do
    xcrun clang -target "$arch-apple-macos13.0" -isysroot "$mac_sdk" "${flags[@]}" -DFIXTURE_MAIN \
        -framework CoreFoundation "$here/fixture.c" -o "$scratch/macos-$arch"
done
xcrun lipo -create "$scratch/macos-arm64" "$scratch/macos-x86_64" -output "$scratch/macos-fat"
xcrun strip -x "$scratch/macos-fat"
codesign -f -s - "$scratch/macos-fat"
cp "$scratch/macos-fat" "$out/macos-fat"

xcrun clang -target arm64e-apple-ios16.0 -isysroot "$ios_sdk" "${flags[@]}" -DFIXTURE_MAIN \
    -framework CoreFoundation -Wl,-no_adhoc_codesign "$here/fixture.c" -o "$scratch/ios-arm64e-unsigned"
xcrun strip -x "$scratch/ios-arm64e-unsigned"
cp "$scratch/ios-arm64e-unsigned" "$out/ios-arm64e-unsigned"

ls -l "$out"
