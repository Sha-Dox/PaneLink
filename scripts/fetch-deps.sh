#!/bin/sh
# Downloads the FFmpeg (LGPL, shared) Windows build the agent links against into windows/deps/ffmpeg.
set -e
cd "$(dirname "$0")/../windows"
URL=https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-n8.1-latest-win64-lgpl-shared-8.1.zip
mkdir -p deps && rm -rf deps/ffmpeg deps/ffmpeg-tmp
curl -fL --retry 3 -o deps/ff.zip "$URL"
unzip -q deps/ff.zip -d deps/ffmpeg-tmp
mv deps/ffmpeg-tmp/ffmpeg-* deps/ffmpeg
rm -rf deps/ffmpeg-tmp deps/ff.zip
echo "FFmpeg ready in windows/deps/ffmpeg"
