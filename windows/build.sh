#!/bin/sh
# Cross-compile the Windows agent/viewer from macOS (brew install mingw-w64).
set -e
cd "$(dirname "$0")"
FF=deps/ffmpeg
[ -d "$FF/include" ] || ../scripts/fetch-deps.sh
mkdir -p dist
x86_64-w64-mingw32-windres panelink.rc -O coff -o dist/panelink.res.o
x86_64-w64-mingw32-gcc -O2 -Wall -std=gnu11 -I"$FF/include" panelink.c dist/panelink.res.o -o dist/panelink.exe \
  -L"$FF/lib" -lavcodec -lavutil \
  -ld3d11 -ldxgi -ld3dcompiler_47 -lws2_32 -lwinmm -luuid -lwtsapi32 -lwinhttp -lwindowscodecs -lole32 -lmsimg32 -liphlpapi -mwindows -static-libgcc
cp "$FF"/bin/avcodec-*.dll "$FF"/bin/avutil-*.dll "$FF"/bin/swresample-*.dll dist/
cp install.ps1 uninstall.ps1 Install.cmd dist/
rm -f dist/panelink.res.o
