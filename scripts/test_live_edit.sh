#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
test -d "$task_developer_dir/Platforms/MacOSX.platform"
export DEVELOPER_DIR="$task_developer_dir"
task_test_dir=$(mktemp -d /tmp/fluidvoice-live-edit-tests.XXXXXX)
xcrun swiftc -O -parse-as-library Sources/Fluid/Services/LiveEditMerge.swift Tests/LiveEditMergeTests.swift -o "$task_test_dir/merge-tests"
"$task_test_dir/merge-tests"
xcrun swiftc -O -parse-as-library Sources/Fluid/Services/LiveEditImagePaste.swift Tests/LiveEditImagePasteTests.swift -o "$task_test_dir/paste-tests"
"$task_test_dir/paste-tests"
xcrun swiftc -O -parse-as-library Sources/Fluid/Services/LiveEditMarkup.swift Tests/LiveEditMarkupTests.swift -o "$task_test_dir/markup-tests"
"$task_test_dir/markup-tests"
