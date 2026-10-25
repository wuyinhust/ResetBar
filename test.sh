#!/bin/zsh
set -euo pipefail
task_root="${0:A:h}"
task_build="$task_root/.build"
mkdir -p "$task_build/module-cache"
/usr/bin/xcrun swiftc -swift-version 5 -module-cache-path "$task_build/module-cache" \
  -parse-as-library "$task_root/Sources/Core.swift" "$task_root/Tests/CoreTests.swift" \
  -o "$task_build/core-tests"
"$task_build/core-tests"
