#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
test -d "$task_developer_dir/Platforms/MacOSX.platform"
export DEVELOPER_DIR="$task_developer_dir"
task_test_dir=$(mktemp -d /tmp/fluidvoice-live-edit-tests.XXXXXX)
xcrun swiftc -O -parse-as-library Sources/Fluid/Services/LiveEditMerge.swift Tests/LiveEditMergeTests.swift -o "$task_test_dir/tests"
"$task_test_dir/tests"
