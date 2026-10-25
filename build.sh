#!/bin/zsh
set -euo pipefail
task_root="${0:A:h}"
task_output="$task_root/dist/ResetBar.app"
task_arch="$(/usr/bin/uname -m)"
mkdir -p "$task_root/.build/module-cache" "$task_output/Contents/MacOS" "$task_output/Contents/Resources"
/usr/bin/xcrun swiftc -swift-version 5 -O -target "${task_arch}-apple-macos13.0" -module-cache-path "$task_root/.build/module-cache" \
  "$task_root/Sources/Core.swift" "$task_root/Sources/Services.swift" "$task_root/Sources/App.swift" \
  -framework AppKit -framework ServiceManagement -framework UserNotifications \
  -o "$task_output/Contents/MacOS/ResetBar"
/usr/bin/python3 - "$task_output/Contents/Info.plist" <<'PY'
import plistlib,sys
info={
 'CFBundleName':'ResetBar','CFBundleDisplayName':'ResetBar',
 'CFBundleIdentifier':'work.kuohu.ResetBar','CFBundleExecutable':'ResetBar',
 'CFBundleVersion':'2','CFBundleShortVersionString':'1.0.1',
 'CFBundlePackageType':'APPL','LSUIElement':True,'LSMinimumSystemVersion':'13.0',
 'NSHighResolutionCapable':True,'NSPrincipalClass':'NSApplication'
}
with open(sys.argv[1],'wb') as f: plistlib.dump(info,f)
PY
/usr/bin/codesign --force --sign - --identifier work.kuohu.ResetBar "$task_output"
print -r -- "$task_output"
