#!/bin/bash
# Runs the unit tests with only the Command Line Tools installed.
# The CLT ship swift-testing but SwiftPM doesn't add its paths on its own.
set -euo pipefail
cd "$(dirname "$0")/.."

DEV=/Library/Developer/CommandLineTools/Library/Developer
EXTRA=()
if [ -d "$DEV/Frameworks/Testing.framework" ]; then
  EXTRA=(-Xswiftc -F -Xswiftc "$DEV/Frameworks"
         -Xlinker -F -Xlinker "$DEV/Frameworks"
         -Xlinker -rpath -Xlinker "$DEV/Frameworks"
         -Xlinker -rpath -Xlinker "$DEV/usr/lib")
fi

swift test -j 2 ${EXTRA[@]+"${EXTRA[@]}"} "$@"
