#!/bin/sh
# Build the AirPlay bridge (libairplaybridge.dylib).
# Prerequisites: brew install cmake pkg-config gstreamer gst-plugins-base \
#   gst-plugins-good gst-plugins-bad gst-libav libplist openssl@3
set -e
cd "$(dirname "$0")"
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
echo "built: $(pwd)/build/libairplaybridge.dylib"
