#!/bin/bash
set -e

# ============================================
# FFmpeg 7.1 for Linux with VAAPI
# Hardware Acceleration for Intel/AMD GPUs
# ============================================

# === Output Configuration ===
if [ -n "$GITHUB_WORKSPACE" ]; then
    WORKSPACE="$GITHUB_WORKSPACE"
else
    WORKSPACE="$(pwd)"
fi

DIST_DIR="$WORKSPACE/dist"
OUTPUT_DIR="$WORKSPACE/ffmpeg-linux-output"
BUILD_DIR="$WORKSPACE/ffmpeg-linux-build"

mkdir -p "$DIST_DIR" "$OUTPUT_DIR" "$BUILD_DIR"

echo "================================================"
echo "FFmpeg 7.1 Linux Build with VAAPI"
echo "================================================"
echo "  WORKSPACE:   $WORKSPACE"
echo "  BUILD_DIR:   $BUILD_DIR"
echo "  OUTPUT_DIR:  $OUTPUT_DIR"
echo "  DIST_DIR:    $DIST_DIR"
echo "================================================"
echo "FFmpeg 7.1 Linux Build with VAAPI"
echo "================================================"

# ----------------------------------------
# 1. Install Dependencies
# ----------------------------------------
echo "[1/4] Installing dependencies..."

sudo apt-get update -qq
sudo apt-get install -y -qq \
    build-essential \
    pkg-config \
    yasm \
    nasm \
    git \
    wget \
    autoconf \
    automake \
    libtool \
    cmake \
    libva-dev \
    libva-drm2 \
    libva-x11-2 \
    vainfo \
    libdrm-dev \
    zlib1g-dev

# ----------------------------------------
# 2. Download FFmpeg
# ----------------------------------------
cd "$BUILD_DIR"
if [ ! -d "ffmpeg-7.1" ]; then
    echo "[2/4] Downloading FFmpeg 7.1..."
    wget -q --show-progress https://ffmpeg.org/releases/ffmpeg-7.1.tar.xz
    tar xf ffmpeg-7.1.tar.xz
else
    echo "[2/4] FFmpeg already downloaded..."
fi

# ----------------------------------------
# 3. Build x264
# ----------------------------------------
echo "[3/4] Building x264..."

cd "$BUILD_DIR"

if [ -f "$OUTPUT_DIR/lib/libx264.a" ]; then
    echo "   Already built, skipping..."
else
    if [ ! -d "x264" ]; then
        git clone --depth 1 https://code.videolan.org/videolan/x264.git
    fi
    
    cd x264
    make distclean 2>/dev/null || true
    
    ./configure \
        --prefix="$OUTPUT_DIR" \
        --enable-static \
        --enable-pic \
        --disable-cli \
        --disable-opencl
    
    make -j$(nproc)
    make install
    
    echo "   ✅ x264 built"
    cd ..
fi

# ----------------------------------------
# 4. Build FFmpeg
# ----------------------------------------
echo "[4/4] Building FFmpeg..."

cd "$BUILD_DIR/ffmpeg-7.1"
make distclean 2>/dev/null || true

# Set PKG_CONFIG_PATH so FFmpeg finds x264
export PKG_CONFIG_PATH="$OUTPUT_DIR/lib/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$OUTPUT_DIR/lib/pkgconfig"

./configure \
    --prefix="$OUTPUT_DIR" \
    --enable-static \
    --disable-shared \
    --disable-everything \
    --enable-small \
    --enable-gpl \
    --disable-autodetect \
    --disable-debug \
    --disable-doc \
    --enable-ffmpeg \
    --enable-avcodec --enable-avformat --enable-avutil \
    --enable-swscale --enable-swresample --enable-avfilter \
    \
    --enable-vaapi \
    --enable-libdrm \
    \
    --enable-libx264 \
    \
    --enable-decoder=hevc,av1,h264,aac,ac3,eac3,opus,ass,ssa,subrip,webvtt,mov_text \
    \
    --enable-hwaccel=h264_vaapi,hevc_vaapi,av1_vaapi \
    \
    --enable-encoder=libx264,aac,webvtt \
    --enable-encoder=h264_vaapi \
    \
    \
    --enable-parser=hevc,av1,h264,aac,ac3,opus \
    \
    --enable-demuxer=matroska,hls \
    --enable-muxer=hls,mpegts,webvtt \
    \
    \
    --enable-protocol=file,pipe,http,https,tcp,tls \
    \
    --enable-filter=scale,format,scale_vaapi \
    \
    --enable-bsf=h264_mp4toannexb,aac_adtstoasc \
    \
    --extra-cflags="-I$OUTPUT_DIR/include" \
    --extra-ldflags="-L$OUTPUT_DIR/lib"

make -j$(nproc)
make install

# Strip binary for smaller size
strip "$OUTPUT_DIR/bin/ffmpeg"

echo "   ✅ FFmpeg built"

# ----------------------------------------
# 5. Verify VAAPI
# ----------------------------------------
echo ""
echo "================================================"
echo "Checking VAAPI Support..."
echo "================================================"

# Check if VAAPI device exists
if [ -e "/dev/dri/renderD128" ]; then
    echo "✅ VAAPI device found: /dev/dri/renderD128"
    
    # Check vainfo
    if command -v vainfo &>/dev/null; then
        echo ""
        echo "VAAPI Info:"
        vainfo 2>/dev/null | head -20 || echo "   ⚠️ vainfo failed (might need GPU)"
    fi
else
    echo "⚠️ VAAPI device not found at /dev/dri/renderD128"
    echo "   This is normal on WSL without GPU passthrough"
    echo "   VAAPI will work on real Linux with Intel/AMD GPU"
fi

# ----------------------------------------
# 5. Create ZIP Package
# ----------------------------------------
echo ""
echo "================================================"
echo "Creating distribution package..."
echo "================================================"

cd "$OUTPUT_DIR"
zip -r "$DIST_DIR/ffmpeg-linux-static.zip" bin/ lib/ include/ 2>/dev/null || \
zip -r "$DIST_DIR/ffmpeg-linux-static.zip" .

if [ -f "$DIST_DIR/ffmpeg-linux-static.zip" ]; then
    echo "✅ Package created: $DIST_DIR/ffmpeg-linux-static.zip"
    ls -lh "$DIST_DIR/ffmpeg-linux-static.zip"
else
    echo "❌ Failed to create package!"
    exit 1
fi

# ----------------------------------------
# 6. Summary
# ----------------------------------------
echo ""
echo "================================================"
echo "✅ BUILD COMPLETE!"
echo "================================================"
echo ""
echo "📦 Binary at:"
echo "   $OUTPUT_DIR/bin/ffmpeg"

if [ -f "$OUTPUT_DIR/bin/ffmpeg" ]; then
    SIZE=$(ls -lh "$OUTPUT_DIR/bin/ffmpeg" | awk '{print $5}')
    echo "   Size: $SIZE"
fi

echo ""
echo "📦 Libraries at:"
echo "   $OUTPUT_DIR/lib/"
ls -lh "$OUTPUT_DIR/lib/"*.a 2>/dev/null | awk '{print "      " $9 " (" $5 ")"}'

echo ""
echo "================================================"
echo "🎬 Usage Examples:"
echo "================================================"
echo ""
echo "# Check VAAPI support:"
echo "$OUTPUT_DIR/bin/ffmpeg -hwaccels"
echo ""
echo "# VAAPI Transcode (Intel/AMD GPU):"
echo "$OUTPUT_DIR/bin/ffmpeg -hwaccel vaapi -hwaccel_device /dev/dri/renderD128 \\"
echo "  -hwaccel_output_format vaapi -i input.mkv \\"
echo "  -c:v h264_vaapi -c:a aac -f hls output.m3u8"
echo ""
echo "# Software Fallback:"
echo "$OUTPUT_DIR/bin/ffmpeg -i input.mkv \\"
echo "  -c:v libx264 -c:a aac -f hls output.m3u8"
echo ""
echo "================================================"
echo "📱 Features included:"
echo "================================================"
echo "   ✅ VAAPI (Linux HW decode/encode - Intel/AMD)"
echo "   ✅ libx264 (Software fallback)"
echo "   ✅ HLS output"
echo "   ✅ MKV input"
echo "   ✅ scale_vaapi filter"
echo ""
echo "================================================"
echo "⚠️ WSL Note:"
echo "================================================"
echo "VAAPI requires actual GPU access."
echo "On WSL2, you need GPU passthrough configured."
echo "Without GPU, use software encoding (libx264)."
echo "================================================"
