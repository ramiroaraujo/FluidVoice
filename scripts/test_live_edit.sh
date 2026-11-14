#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
test -d "$task_developer_dir/Platforms/MacOSX.platform"
export DEVELOPER_DIR="$task_developer_dir"
task_test_dir=$(mktemp -d /tmp/fluidvoice-live-edit-tests.XXXXXX)
xcrun swiftc -O -parse-as-library Sources/Fluid/Services/LiveEditMerge.swift Tests/LiveEditMergeTests.swift -o "$task_test_dir/merge-tests"
"$task_test_dir/merge-tests"
xcrun swiftc -O -parse-as-library Sources/Fluid/Services/LiveEditList.swift Tests/LiveEditListTests.swift -o "$task_test_dir/list-tests"
"$task_test_dir/list-tests"
xcrun swiftc -O -parse-as-library Sources/Fluid/Services/LiveEditImagePaste.swift Tests/LiveEditImagePasteTests.swift -o "$task_test_dir/paste-tests"
"$task_test_dir/paste-tests"
xcrun swiftc -O -parse-as-library Sources/Fluid/Services/LiveEditMarkup.swift Tests/LiveEditMarkupTests.swift -o "$task_test_dir/markup-tests"
"$task_test_dir/markup-tests"
xcrun swiftc -O -parse-as-library Sources/Fluid/Services/DictationMuteTimeline.swift Tests/DictationTypingHoldTests.swift -o "$task_test_dir/hold-tests"
"$task_test_dir/hold-tests"
