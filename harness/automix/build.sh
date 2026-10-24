#!/bin/sh
# Builds the AutoMix harness for the Mac: SGTimePitch.m as the tweak compiles it, and main.m.
set -e
cd "$(dirname "$0")"
mkdir -p build
xcrun clang -fobjc-arc -O2 -I ../../tweak/Sources -framework Foundation -framework AudioToolbox -framework Accelerate \
    main.m ../../tweak/Sources/Shared/Player/SGTimePitch.m -o build/automix
