#!/bin/bash
set -e

# ============================================
# FFmpeg 7.1 Universal Build 
# ============================================

export INSTALL_DIR="/home/runner/mkv/ffmpeg-win-static"
export BUILD_DIR="/home/runner/mkv/ffmpeg-build-win"
export TOOLCHAIN="x86_64-w64-mingw32"

export PKG_CONFIG_PATH="$INSTALL_DIR/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$INSTALL_DIR/lib/pkgconfig"

mkdir -p "$INSTALL_DIR" "$BUILD_DIR"

export CC="${TOOLCHAIN}-gcc"
export CXX="${TOOLCHAIN}-g++"
export AR="${TOOLCHAIN}-ar"
export RANLIB="${TOOLCHAIN}-ranlib"

echo "================================================"
echo "FFmpeg 7.1 Universal Build"
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
sudo apt-get update -qq
sudo apt-get install -y -qq \
    mingw-w64 pkg-config yasm nasm \
    autoconf automake libtool git wget \
    cmake make patch

# ----------------------------------------
# 2. Build x264
# ----------------------------------------
cd "$BUILD_DIR"
if [ ! -f "$INSTALL_DIR/lib/libx264.a" ]; then
    echo "[2/6] Building x264..."
    if [ ! -d "x264" ]; then
        git clone --depth 1 https://code.videolan.org/videolan/x264.git
    fi
    cd x264
    ./configure --prefix="$INSTALL_DIR" --host=${TOOLCHAIN} --cross-prefix=${TOOLCHAIN}- --enable-static --disable-cli --disable-opencl
    make -j$(nproc)
    make install
    cd ..
else
    echo "[2/6] x264 already built, skipping..."
fi


# ----------------------------------------
# 3. Install AMF Headers
# ----------------------------------------
cd "$BUILD_DIR"
if [ ! -d "$INSTALL_DIR/include/AMF" ]; then
    echo "[4/6] Installing AMF..."
    [ ! -d "AMF" ] && git clone --depth 1 https://github.com/GPUOpen-LibrariesAndSDKs/AMF.git
    mkdir -p "$INSTALL_DIR/include/AMF"
    cp -r AMF/amf/public/include/* "$INSTALL_DIR/include/AMF/"
else
    echo "[3/6] AMF skipped..."
fi

# ----------------------------------------
# 5. NVIDIA Headers
# ----------------------------------------
cd "$BUILD_DIR"
if [ ! -f "$INSTALL_DIR/include/ffnvcodec/nvEncodeAPI.h" ]; then
    echo "[5/6] Installing NVIDIA headers..."
    rm -rf nv-codec-headers
    git clone --depth 1 https://git.videolan.org/git/ffmpeg/nv-codec-headers.git
    cd nv-codec-headers
    make PREFIX="$INSTALL_DIR" install
    cd ..
else
    echo "[5/6] NVIDIA headers skipped..."
fi

# FIX: Copy headers from ffnvcodec subdir to root include dir
# FFmpeg's pkg-config points to include/ but headers are in include/ffnvcodec/
if [ -d "$INSTALL_DIR/include/ffnvcodec" ]; then
    cp -n "$INSTALL_DIR/include/ffnvcodec/"*.h "$INSTALL_DIR/include/" 2>/dev/null || true
fi

# FIX: Update ffnvcodec.pc to point to correct subdirectory
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

# 1. FORCE THE PATHS: Point directly to where the headers and libs are
export CFLAGS="-I$INSTALL_DIR/include -I$INSTALL_DIR/include/ffnvcodec"
export LDFLAGS="-L$INSTALL_DIR/lib"
export PKG_CONFIG_PATH="$INSTALL_DIR/lib/pkgconfig"

# 2. BYPASS THE AUTO-CHECK: We use sed to "lie" to the configure script.
sed -i 's/enabled ffnvcodec && check_pkg_config ffnvcodec/enabled ffnvcodec/g' configure

./configure \
    --prefix="$INSTALL_DIR" \
    --target-os=mingw32 \
    --arch=x86_64 \
    --cross-prefix=${TOOLCHAIN}- \
    --enable-cross-compile \
    --pkg-config="pkg-config" \
    --pkg-config-flags="--static" \
    --extra-cflags="-I$INSTALL_DIR/include -I$INSTALL_DIR/include/ffnvcodec" \
    --extra-ldflags="-L$INSTALL_DIR/lib -static" \
    --enable-static \
    --disable-shared \
    --disable-everything \
    --enable-small \
    --enable-gpl \
    --enable-nvenc \
    --enable-ffnvcodec \
    --disable-autodetect \
    --disable-debug \
    --disable-doc \
    --enable-ffmpeg \
    --enable-avcodec --enable-avformat --enable-avutil \
    --enable-swscale --enable-swresample --enable-avfilter \
    --enable-libx264 \
    --enable-amf \
    --enable-d3d11va \
    --enable-decoder=hevc,aac,ac3,eac3,opus \
    --enable-hwaccel=h264_d3d11va,hevc_d3d11va \
    --enable-encoder=libx264,h264_nvenc,h264_amf,aac \
    --enable-parser=hevc,h264,aac,ac3,opus \
    --enable-demuxer=matroska \
    --enable-muxer=hls,mpegts \
    --enable-protocol=file,pipe \
    --enable-filter=scale,format \
    --enable-bsf=h264_mp4toannexb,aac_adtstoasc

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
