#!/bin/bash
set -eo pipefail

export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="$SCRIPT_DIR/Sources"
OUTPUT_DIR="$SCRIPT_DIR/bin"
LICENSE_DIR="$SCRIPT_DIR/Licenses"
CACHE_DIR="${FFMPEG_CACHE_DIR:-${TMPDIR:-/tmp}/videoeditor-ffmpeg-cache}"
TEMP_BASE="${TMPDIR:-/tmp}"
TEMP_BASE="${TEMP_BASE%/}"

FFMPEG_VERSION="8.1.2"
FFMPEG_ARCHIVE="ffmpeg-${FFMPEG_VERSION}.tar.xz"
FFMPEG_URL="https://ffmpeg.org/releases/${FFMPEG_ARCHIVE}"
FFMPEG_SHA256="464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c"

X264_COMMIT="b35605ace3ddf7c1a5d67a2eb553f034aef41d55"
X264_ARCHIVE="x264-${X264_COMMIT}.tar.bz2"
X264_URL="https://code.videolan.org/videolan/x264/-/archive/${X264_COMMIT}/${X264_ARCHIVE}"
X264_SHA256="6eeb82934e69fd51e043bd8c5b0d152839638d1ce7aa4eea65a3fedcf83ff224"

MIN_MACOS_VERSION="13.0"
ARCHITECTURES=(arm64 x86_64)
BUILD_JOBS="${BUILD_JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)}"

for tool in curl lipo make otool shasum strip tar xcrun; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Required build tool not found: $tool" >&2
        exit 1
    fi
done

mkdir -p "$SOURCE_DIR" "$OUTPUT_DIR" "$LICENSE_DIR" "$CACHE_DIR"

verify_archive() {
    local archive="$1"
    local expected="$2"
    local actual
    actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        echo "Checksum mismatch for $archive" >&2
        echo "expected: $expected" >&2
        echo "actual:   $actual" >&2
        exit 1
    fi
}

resolve_archive() {
    local filename="$1"
    local url="$2"
    local expected="$3"
    local bundled="$SOURCE_DIR/$filename"
    local cached="$CACHE_DIR/$filename"

    if [[ -f "$bundled" ]]; then
        verify_archive "$bundled" "$expected"
        echo "$bundled"
        return
    fi

    if [[ ! -f "$cached" ]]; then
        local partial="$cached.download"
        curl --fail --location --retry 3 --output "$partial" "$url"
        mv "$partial" "$cached"
    fi
    verify_archive "$cached" "$expected"
    echo "$cached"
}

FFMPEG_SOURCE="$(resolve_archive "$FFMPEG_ARCHIVE" "$FFMPEG_URL" "$FFMPEG_SHA256")"
X264_SOURCE="$(resolve_archive "$X264_ARCHIVE" "$X264_URL" "$X264_SHA256")"

BUILD_ROOT="$(mktemp -d "$TEMP_BASE/videoeditor-ffmpeg-build.XXXXXX")"
cleanup() {
    case "$BUILD_ROOT" in
        "$TEMP_BASE"/videoeditor-ffmpeg-build.*)
            rm -rf -- "$BUILD_ROOT"
            ;;
        *)
            echo "Refusing to remove unexpected build directory: $BUILD_ROOT" >&2
            ;;
    esac
}
trap cleanup EXIT

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="$(xcrun --find clang)"
RANLIB="$(xcrun --find ranlib)"

for arch in "${ARCHITECTURES[@]}"; do
    arch_root="$BUILD_ROOT/$arch"
    x264_root="$arch_root/x264"
    x264_prefix="$arch_root/x264-prefix"
    ffmpeg_root="$arch_root/ffmpeg"
    mkdir -p "$x264_root" "$x264_prefix" "$ffmpeg_root"

    tar -xf "$X264_SOURCE" -C "$x264_root" --strip-components=1
    tar -xf "$FFMPEG_SOURCE" -C "$ffmpeg_root" --strip-components=1
    install -m 755 "$SCRIPT_DIR/pkg-config-x264.sh" "$arch_root/pkg-config-x264.sh"

    x264_host="aarch64-apple-darwin"
    x264_asm_flags=()
    ffmpeg_arch_flags=()
    if [[ "$arch" == "x86_64" ]]; then
        x264_host="x86_64-apple-darwin"
        x264_asm_flags=(--disable-asm)
        ffmpeg_arch_flags=(--disable-x86asm --enable-cross-compile)
    fi

    pushd "$x264_root" >/dev/null
    CC="$CLANG" RANLIB="$RANLIB" ./configure \
        --host="$x264_host" \
        --prefix="../x264-prefix" \
        --enable-static \
        --disable-cli \
        --disable-opencl \
        --disable-interlaced \
        --bit-depth=8 \
        --chroma-format=420 \
        --extra-asflags="-arch $arch -mmacosx-version-min=$MIN_MACOS_VERSION -isysroot $SDK_PATH" \
        --extra-cflags="-arch $arch -mmacosx-version-min=$MIN_MACOS_VERSION -isysroot $SDK_PATH" \
        --extra-ldflags="-arch $arch -mmacosx-version-min=$MIN_MACOS_VERSION -isysroot $SDK_PATH" \
        "${x264_asm_flags[@]}"
    make -s -j"$BUILD_JOBS" install
    popd >/dev/null

    pushd "$ffmpeg_root" >/dev/null
    X264_PREFIX="../x264-prefix" ./configure \
        --prefix=/usr/local \
        --extra-version=videoeditor \
        --target-os=darwin \
        --arch="$arch" \
        --cc="$CLANG" \
        --ranlib="$RANLIB" \
        --host-cc="$CLANG" \
        --host-cflags="-isysroot $SDK_PATH" \
        --host-cppflags="-isysroot $SDK_PATH" \
        --host-ldflags="-isysroot $SDK_PATH" \
        --pkg-config=../pkg-config-x264.sh \
        --pkg-config-flags=--static \
        --extra-cflags="-arch $arch -mmacosx-version-min=$MIN_MACOS_VERSION -isysroot $SDK_PATH" \
        --extra-ldflags="-arch $arch -mmacosx-version-min=$MIN_MACOS_VERSION -isysroot $SDK_PATH -L../x264-prefix/lib" \
        --enable-static \
        --disable-shared \
        --enable-small \
        --disable-debug \
        --disable-doc \
        --disable-ffplay \
        --disable-network \
        --disable-autodetect \
        --enable-pthreads \
        --enable-zlib \
        --enable-bzlib \
        --enable-audiotoolbox \
        --enable-videotoolbox \
        --enable-gpl \
        --enable-libx264 \
        "${ffmpeg_arch_flags[@]}"
    make -s -j"$BUILD_JOBS" ffmpeg ffprobe
    popd >/dev/null
done

for executable in ffmpeg ffprobe; do
    slices=()
    for arch in "${ARCHITECTURES[@]}"; do
        slices+=("$BUILD_ROOT/$arch/ffmpeg/$executable")
    done
    lipo -create "${slices[@]}" -output "$OUTPUT_DIR/$executable"
    strip -x "$OUTPUT_DIR/$executable"
    chmod 755 "$OUTPUT_DIR/$executable"

    # otool -L prints one header line per architecture slice; only the
    # tab-indented lines are actual dylib references.
    if otool -L "$OUTPUT_DIR/$executable" | awk '/^\t/ {print $1}' | grep -Ev '^(/usr/lib/|/System/Library/)' >/dev/null; then
        echo "$executable contains a non-system dynamic library reference" >&2
        otool -L "$OUTPUT_DIR/$executable" >&2
        exit 1
    fi
done

install -m 644 "$BUILD_ROOT/arm64/ffmpeg/COPYING.GPLv2" "$LICENSE_DIR/FFmpeg-COPYING.GPLv2"
install -m 644 "$BUILD_ROOT/arm64/ffmpeg/LICENSE.md" "$LICENSE_DIR/FFmpeg-LICENSE.md"
install -m 644 "$BUILD_ROOT/arm64/x264/COPYING" "$LICENSE_DIR/x264-COPYING"

echo "Built Universal 2 tools:"
file "$OUTPUT_DIR/ffmpeg" "$OUTPUT_DIR/ffprobe"
"$OUTPUT_DIR/ffmpeg" -version | sed -n '1,4p'
