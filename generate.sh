#!/bin/bash
# Regenerates ReceiptDrop.xcodeproj from project.yml. Thin wrapper around
# `xcodegen generate` — the two are interchangeable, and that is deliberate.
#
# This script used to post-patch the generated project: it stamped
# objectVersion 77 back down to 56 and injected compatibilityVersion
# "Xcode 14.0", because XcodeGen 2.45+ emits the Xcode 16 format and the
# Xcode 15.2 project editor crashed on it. That machine is long gone — we
# build on Xcode 26.6 now — so the patch protected nothing and instead made
# the committed project.pbxproj unstable: whoever ran plain `xcodegen
# generate` committed objectVersion 77, whoever ran ./generate.sh committed
# 56, and the file flip-flopped between them with a spurious 2-line diff on
# every regeneration. The patch is gone for good; do not restore it. If some
# future Xcode ever needs a downgraded format again, fix it in project.yml
# so both regeneration paths agree, rather than sed-ing the output of one.
set -euo pipefail
cd "$(dirname "$0")"

xcodegen generate

echo "Done — ReceiptDrop.xcodeproj regenerated from project.yml."
