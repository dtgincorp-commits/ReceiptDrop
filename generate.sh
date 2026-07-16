#!/bin/bash
# Regenerates ReceiptDrop.xcodeproj from project.yml.
#
# XcodeGen 2.45+ writes the Xcode 16 project format (objectVersion 77),
# which crashes the Xcode 15.2 project editor. The generated project uses
# no Xcode-16-only constructs, so we stamp it back to the Xcode 15 format.
# If you upgrade to Xcode 16+, delete the patch below.
set -euo pipefail
cd "$(dirname "$0")"

xcodegen generate

PBXPROJ="ReceiptDrop.xcodeproj/project.pbxproj"
/usr/bin/sed -i '' 's/objectVersion = 77;/objectVersion = 56;/' "$PBXPROJ"
# objectVersion 56 projects also carry a compatibilityVersion marker.
if ! grep -q compatibilityVersion "$PBXPROJ"; then
  /usr/bin/sed -i '' 's/^\([[:space:]]*\)buildConfigurationList = \(.*PBXProject.*\);$/&\
\1compatibilityVersion = "Xcode 14.0";/' "$PBXPROJ"
fi

grep -E "objectVersion|compatibilityVersion" "$PBXPROJ" | head -2
echo "Done — project is in Xcode 15-compatible format."
