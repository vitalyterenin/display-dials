#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
developer_dir="$(xcode-select -p)"
testing_plugin="$developer_dir/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ "$developer_dir" == */CommandLineTools && -f "$testing_plugin" ]]; then
    # CLT 27.2's swiftbuild discovers Testing.framework but misses its macro plugin.
    swift test -Xswiftc -load-plugin-library -Xswiftc "$testing_plugin"
else
    swift test
fi
