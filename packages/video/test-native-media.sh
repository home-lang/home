#!/bin/sh
# Focused suite for the optional Home AVC/HEVC + MP4 modules. No FFmpeg.
set -eu
cd "$(dirname "$0")"
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/home-native-media.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT HUP INT TERM
cc -std=c11 -Wall -Wextra -Werror $(pkg-config --cflags x264 x265) -c src/codecs/video/native_encoder.c -o "$build_dir/encoder.o"
${ZIG:-zig} fmt --check src/codecs/video/native_encoder.zig src/codecs/video/rgb_i420.zig src/containers/mp4_stream.zig src/native_media_tests.zig tests/color_signal.zig
for mode in Debug ReleaseSafe; do
    ${ZIG:-zig} test src/native_media_tests.zig -O "$mode" -lc "$build_dir/encoder.o" $(pkg-config --libs x264 x265) ${HOME_MEDIA_LDFLAGS:-}
    ${ZIG:-zig} test -O "$mode" -lc "$build_dir/encoder.o" $(pkg-config --libs x264 x265) ${HOME_MEDIA_LDFLAGS:-} --dep encoder --dep mp4 --dep color -Mroot=tests/color_signal.zig -Mencoder=src/codecs/video/native_encoder.zig -Mmp4=src/containers/mp4_stream.zig -Mcolor=src/core/color_description.zig
done
