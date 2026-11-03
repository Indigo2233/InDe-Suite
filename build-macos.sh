#!/bin/bash
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || { echo 'Build on macOS with Xcode installed.' >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")" && pwd)"
ARCH="${INDE_ARCH:-$(uname -m)}"
case "$ARCH" in arm64) MAKE_ARCH=arm64 ;; x86_64) MAKE_ARCH=x64 ;; *) exit 2 ;; esac
PCL_COMMIT=201860a364c05308cde8271f5ca517b69b487fa1
export PCLDIR="${PCLDIR:-$ROOT/build/pcl-macos}"
if [[ ! -d "$PCLDIR/.git" ]]; then
  git init "$PCLDIR"
  git -C "$PCLDIR" remote add origin https://gitlab.com/pixinsight/PCL.git
  git -C "$PCLDIR" fetch --depth 1 origin "$PCL_COMMIT"
  git -C "$PCLDIR" checkout --detach FETCH_HEAD
fi
[[ "$(git -C "$PCLDIR" rev-parse HEAD)" == "$PCL_COMMIT" ]] || {
  echo "PCLDIR must point to SDK commit $PCL_COMMIT" >&2; exit 1;
}
export PCLINCDIR="$PCLDIR/include" PCLSRCDIR="$PCLDIR/src"
export PCLLIBDIR64="$ROOT/build/macos-$ARCH/lib" PCLBINDIR64="$ROOT/build/macos-$ARCH/bin"
mkdir -p "$PCLLIBDIR64" "$PCLBINDIR64"
for lib in lz4 zstd zlib RFC6234 lcms cminpack PCL; do
  [[ -f "$PCLLIBDIR64/lib$lib-pxi.a" ]] && continue
  if [[ "$lib" == PCL ]]; then src="$PCLSRCDIR/pcl"; else src="$PCLSRCDIR/3rdparty/$lib"; fi
  mkdir -p "$src/macosx/g++/$MAKE_ARCH/Release"
  echo "Building $lib ($ARCH)..."
  log="$ROOT/build/macos-$ARCH/$lib.log"
  if ! make -C "$src/macosx/g++" -f "makefile-$MAKE_ARCH" -j "$(sysctl -n hw.logicalcpu)" >"$log" 2>&1; then
    tail -n 100 "$log"; exit 1
  fi
done
cmake -S "$ROOT" -B "$ROOT/build/macos-$ARCH/module" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DPCL_ROOT="$PCLDIR" -DPCL_LIBRARY_DIR="$PCLLIBDIR64"
cmake --build "$ROOT/build/macos-$ARCH/module" --parallel
cp "$ROOT/build/macos-$ARCH/module/InDe-pxm.dylib" "$PCLBINDIR64/"
codesign --force --sign - "$PCLBINDIR64/InDe-pxm.dylib"
codesign --verify --strict "$PCLBINDIR64/InDe-pxm.dylib"
lipo -info "$PCLBINDIR64/InDe-pxm.dylib"
