#!/bin/bash
set -e

# ============================================
# FFmpeg 7.1 Universal Build 
# ============================================

# === Output Configuration ===
if [ -n "$GITHUB_WORKSPACE" ]; then
    if command -v cygpath >/dev/null 2>&1; then
        WORKSPACE="$(cygpath -u "$GITHUB_WORKSPACE")"
    else
        WORKSPACE="$GITHUB_WORKSPACE"
    fi
else
    WORKSPACE="$(pwd)"
fi

DIST_DIR="$WORKSPACE/dist"
OUTPUT_DIR="$WORKSPACE/ffmpeg-win-output"
BUILD_DIR="/tmp/ffmpeg-win-build"

mkdir -p "$DIST_DIR" "$OUTPUT_DIR" "$BUILD_DIR"

export INSTALL_DIR="$OUTPUT_DIR"
export BUILD_DIR="$BUILD_DIR"
export TOOLCHAIN="x86_64-w64-mingw32"

export PKG_CONFIG_PATH="$INSTALL_DIR/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$INSTALL_DIR/lib/pkgconfig"

export CC="${TOOLCHAIN}-gcc"
export CXX="${TOOLCHAIN}-g++"
export AR="${TOOLCHAIN}-gcc-ar"
export RANLIB="${TOOLCHAIN}-gcc-ranlib"
export ENABLE_NVENC="${ENABLE_NVENC:-1}"
export ENABLE_AMF="${ENABLE_AMF:-1}"
export SKIP_SYSTEM_DEPS="${SKIP_SYSTEM_DEPS:-0}"
export RUN_HW_RUNTIME_SMOKE="${RUN_HW_RUNTIME_SMOKE:-0}"

echo "================================================"
echo "FFmpeg 7.1 Universal Build"
echo "================================================"
echo "  WORKSPACE:   $WORKSPACE"
echo "  BUILD_DIR:   $BUILD_DIR"
echo "  OUTPUT_DIR:  $OUTPUT_DIR"
echo "  DIST_DIR:    $DIST_DIR"
echo "================================================"

# ----------------------------------------
# 0. Generate Toolchain
# ----------------------------------------
cat > "$BUILD_DIR/toolchain-mingw64.cmake" <<EOF
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CMAKE_C_COMPILER x86_64-w64-mingw32-gcc)
set(CMAKE_CXX_COMPILER x86_64-w64-mingw32-g++)
set(CMAKE_RC_COMPILER x86_64-w64-mingw32-windres)
set(CMAKE_FIND_ROOT_PATH /usr/x86_64-w64-mingw32 "$INSTALL_DIR")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
EOF

# ----------------------------------------
# 1. Install Dependencies
# ----------------------------------------
echo "[1/6] Checking OS dependencies..."
if [ "$SKIP_SYSTEM_DEPS" = "1" ]; then
    echo "   Skipping system dependency installation"
elif command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -qq
    sudo apt-get install -y -qq \
        mingw-w64 pkg-config yasm nasm \
        autoconf automake libtool git wget \
        cmake make patch
elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm --needed \
        base-devel git wget cmake make patch \
        autoconf automake libtool pkgconf yasm nasm zip unzip tar xz \
        mingw-w64-x86_64-toolchain
else
    echo "Unsupported package manager; install dependencies manually." >&2
    exit 1
fi

# ----------------------------------------
# 2. Build OpenH264
# ----------------------------------------
cd "$BUILD_DIR"
if [ ! -f "$INSTALL_DIR/lib/libopenh264.a" ]; then
    echo "[2/6] Building OpenH264..."
    if [ ! -d "openh264" ]; then
        git clone --depth 1 https://github.com/cisco/openh264.git
    fi
    cd openh264
    make clean 2>/dev/null || true
    make -j$(nproc) \
        OS=mingw_nt \
        ARCH=x86_64 \
        CC="$CC" \
        CXX="$CXX" \
        AR="$AR" \
        RANLIB="$RANLIB" \
        PREFIX="$INSTALL_DIR" \
        install-static \
        V=No
    cd ..
else
    echo "[2/6] OpenH264 already built, skipping..."
fi


# ----------------------------------------
# 3. Install AMF Headers
# ----------------------------------------
cd "$BUILD_DIR"
if [ "$ENABLE_AMF" = "1" ]; then
    if [ ! -d "$INSTALL_DIR/include/AMF" ]; then
        echo "[3/6] Installing AMF..."
        [ ! -d "AMF" ] && git clone --depth 1 https://github.com/GPUOpen-LibrariesAndSDKs/AMF.git
        mkdir -p "$INSTALL_DIR/include/AMF"
        cp -r AMF/amf/public/include/* "$INSTALL_DIR/include/AMF/"
    else
        echo "[3/6] AMF already installed, skipping..."
    fi
else
    echo "[3/6] AMF disabled via ENABLE_AMF=0"
fi

# ----------------------------------------
# 5. NVIDIA Headers
# ----------------------------------------
cd "$BUILD_DIR"
if [ "$ENABLE_NVENC" = "1" ]; then
    if [ ! -f "$INSTALL_DIR/include/ffnvcodec/nvEncodeAPI.h" ]; then
        echo "[4/6] Installing NVIDIA headers..."
        rm -rf nv-codec-headers
        git clone --depth 1 https://github.com/FFmpeg/nv-codec-headers.git
        cd nv-codec-headers
        make PREFIX="$INSTALL_DIR" install
        cd ..
    else
        echo "[4/6] NVIDIA headers already installed, skipping..."
    fi
else
    echo "[4/6] NVENC disabled via ENABLE_NVENC=0"
fi

if [ -f "$INSTALL_DIR/lib/pkgconfig/ffnvcodec.pc" ]; then
    sed -i 's|includedir=\${prefix}/include|includedir=${prefix}/include/ffnvcodec|' "$INSTALL_DIR/lib/pkgconfig/ffnvcodec.pc"
fi

# ----------------------------------------
# 6. Configure FFmpeg (PROPER NVENC METHOD)
# ----------------------------------------
cd "$BUILD_DIR"

if [ -d "ffmpeg-7.1" ]; then
    echo "⚠️  Cleaning previous FFmpeg build..."
    rm -rf ffmpeg-7.1
fi

if [ ! -d "ffmpeg-7.1" ]; then
    echo "Downloading FFmpeg 7.1..."
    wget -q --show-progress https://ffmpeg.org/releases/ffmpeg-7.1.tar.xz
    tar xf ffmpeg-7.1.tar.xz
fi
cd ffmpeg-7.1

# ----------------------------------------
# 6. Configure FFmpeg (HARD FIX)
# ----------------------------------------
cd "$BUILD_DIR/ffmpeg-7.1"

echo "[6/7] Configuring FFmpeg..."

export CFLAGS="-I$INSTALL_DIR/include -I$INSTALL_DIR/include/ffnvcodec"
export LDFLAGS="-L$INSTALL_DIR/lib"
export PKG_CONFIG_PATH="$INSTALL_DIR/lib/pkgconfig"

CONFIGURE_HW_ARGS=("--enable-d3d11va")

if [ "$ENABLE_NVENC" = "1" ]; then
    pkg-config --exists ffnvcodec
    CONFIGURE_HW_ARGS+=("--enable-nvenc" "--enable-ffnvcodec" "--enable-encoder=h264_nvenc")
fi

if [ "$ENABLE_AMF" = "1" ]; then
    CONFIGURE_HW_ARGS+=("--enable-amf" "--enable-encoder=h264_amf")
fi

./configure \
    --prefix="$INSTALL_DIR" \
    --target-os=mingw32 \
    --arch=x86_64 \
    --cc="$CC" \
    --cxx="$CXX" \
    --ar="$AR" \
    --ranlib="$RANLIB" \
    --cross-prefix=${TOOLCHAIN}- \
    --ld="$CXX" \
    --enable-cross-compile \
    --pkg-config="pkg-config" \
    --pkg-config-flags="--static" \
    --extra-cflags="-I$INSTALL_DIR/include -I$INSTALL_DIR/include/ffnvcodec" \
    --extra-ldflags="-L$INSTALL_DIR/lib -static" \
    --enable-static \
    --disable-shared \
    --disable-everything \
    --enable-small \
    --disable-autodetect \
    --disable-debug \
    --disable-doc \
    --enable-ffmpeg \
    --enable-avcodec --enable-avformat --enable-avutil \
    --enable-swscale --enable-swresample --enable-avfilter \
    --enable-libopenh264 \
    --enable-decoder=hevc,av1,h264,aac,ac3,eac3,flac,opus,ass,ssa,subrip,webvtt,mov_text \
    --enable-hwaccel=h264_d3d11va,hevc_d3d11va,av1_d3d11va \
    --enable-encoder=libopenh264,aac,webvtt \
    --enable-parser=hevc,av1,h264,aac,ac3,eac3,flac,opus \
    --enable-demuxer=matroska,hls \
    --enable-muxer=hls,mpegts,webvtt \
    --enable-protocol=file,pipe,http,https,tcp,tls \
    --enable-filter=scale,format,aresample \
    --enable-bsf=h264_mp4toannexb,aac_adtstoasc \
    "${CONFIGURE_HW_ARGS[@]}"

# ----------------------------------------
# 7. Build
# ----------------------------------------
echo ""
echo "[7/7] Building FFmpeg..."
make -j$(nproc)
make install

# Strip debug symbols from binary for smaller size
if [ -f "$INSTALL_DIR/bin/ffmpeg.exe" ]; then
    ${TOOLCHAIN}-strip "$INSTALL_DIR/bin/ffmpeg.exe"
    echo "   Stripped binary for smaller size"
fi

run_hw_smoke_test() {
    local label="$1"
    shift
    echo "   Running $label smoke test..."
    "$INSTALL_DIR/bin/ffmpeg.exe" -hide_banner -loglevel error \
        -f lavfi -i testsrc2=size=128x72:rate=24 \
        -frames:v 1 -an -c:v "$@" \
        -pix_fmt yuv420p -profile:v high \
        -f null - >/dev/null
}

if [ "$RUN_HW_RUNTIME_SMOKE" = "1" ]; then
    echo ""
    echo "[7.5/8] Verifying hardware paths..."

    if [ "$ENABLE_NVENC" = "1" ]; then
        run_hw_smoke_test "NVENC" h264_nvenc -preset p4 -tune hq -rc vbr -cq 24 -b:v 0 -maxrate 12M -bufsize 24M
    fi

    if [ "$ENABLE_AMF" = "1" ]; then
        run_hw_smoke_test "AMF" h264_amf -usage transcoding -quality speed -rc cqp -qp_i 24 -qp_p 26
    fi
else
    echo ""
    echo "[7.5/8] Skipping runtime hardware smoke tests (RUN_HW_RUNTIME_SMOKE=0)"
fi

# ----------------------------------------
# 8. Create ZIP Package
# ----------------------------------------
echo ""
echo "[8/8] Creating distribution package..."

cd "$OUTPUT_DIR"
zip -r "$DIST_DIR/ffmpeg-win-static.zip" bin/ lib/ include/ 2>/dev/null || \
zip -r "$DIST_DIR/ffmpeg-win-static.zip" .

if [ -f "$DIST_DIR/ffmpeg-win-static.zip" ]; then
    echo "✅ Package created: $DIST_DIR/ffmpeg-win-static.zip"
    ls -lh "$DIST_DIR/ffmpeg-win-static.zip"
else
    echo "❌ Failed to create package!"
    exit 1
fi
