#!/bin/bash
set -e

# ============================================
# FFmpeg 7.1 for macOS with VideoToolbox
# Hardware Acceleration for Apple Silicon & Intel
# ============================================

# === Output Configuration ===
if [ -n "$GITHUB_WORKSPACE" ]; then
    WORKSPACE="$GITHUB_WORKSPACE"
else
    WORKSPACE="$(pwd)"
fi

DIST_DIR="$WORKSPACE/dist"
OUTPUT_DIR="$WORKSPACE/ffmpeg-macos-output"
BUILD_DIR="/tmp/ffmpeg-macos-build"

mkdir -p "$DIST_DIR" "$OUTPUT_DIR" "$BUILD_DIR"

# === Build Configuration ===
ARCHS="arm64 x86_64"

echo "================================================"
echo "FFmpeg 7.1 macOS Build with VideoToolbox"
echo "================================================"
echo "  WORKSPACE:   $WORKSPACE"
echo "  BUILD_DIR:   $BUILD_DIR"
echo "  OUTPUT_DIR:  $OUTPUT_DIR"
echo "  DIST_DIR:    $DIST_DIR"
echo "  ARCHS:      $ARCHS"
echo "================================================"

# ----------------------------------------
# 1. Install Dependencies
# ----------------------------------------
echo "[1/4] Installing dependencies..."

# Check if homebrew is available
if command -v brew &> /dev/null; then
    echo "Using Homebrew..."
    brew install yasm nasm pkg-config x264 2>/dev/null || true
else
    echo "Homebrew not found, using system tools..."
fi

# Install nasm if not available
if ! command -v nasm &> /dev/null; then
    echo "Installing NASM..."
    brew install nasm
fi

if ! command -v yasm &> /dev/null; then
    echo "Installing YASM..."
    brew install yasm
fi

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
build_x264() {
    ARCH=$1
    
    echo "[3/4] Building x264 for $ARCH..."
    
    cd "$BUILD_DIR"
    
    if [ -f "$OUTPUT_DIR/$ARCH/lib/libx264.a" ]; then
        echo "   Already built, skipping..."
        return
    fi
    
    if [ ! -d "x264" ]; then
        git clone --depth 1 https://code.videolan.org/videolan/x264.git
    fi
    
    cd x264
    make distclean 2>/dev/null || true
    
    if [ "$ARCH" == "arm64" ]; then
        ./configure \
            --prefix="$OUTPUT_DIR/$ARCH" \
            --host=aarch64-apple-darwin \
            --enable-static \
            --disable-cli \
            --disable-opencl \
            --extra-cflags="-arch arm64"
    else
        ./configure \
            --prefix="$OUTPUT_DIR/$ARCH" \
            --host=x86_64-apple-darwin \
            --enable-static \
            --disable-cli \
            --disable-opencl \
            --extra-cflags="-arch x86_64"
    fi
    
    make -j$(sysctl -n hw.ncpu)
    make install
    
    echo "   ✅ x264 built for $ARCH"
    cd ..
}

# ----------------------------------------
# 4. Build FFmpeg
# ----------------------------------------
build_ffmpeg() {
    ARCH=$1
    
    echo "[4/4] Building FFmpeg for $ARCH..."
    
    cd "$BUILD_DIR/ffmpeg-7.1"
    make distclean 2>/dev/null || true
    
    export PKG_CONFIG_PATH="$OUTPUT_DIR/$ARCH/lib/pkgconfig"
    export PKG_CONFIG_LIBDIR="$OUTPUT_DIR/$ARCH/lib/pkgconfig"
    
    if [ "$ARCH" == "arm64" ]; then
        ARCH_FLAGS="-arch arm64"
        TARGET="arm-apple-darwin"
    else
        ARCH_FLAGS="-arch x86_64"
        TARGET="x86_64-apple-darwin"
    fi
    
    ./configure \
        --prefix="$OUTPUT_DIR/$ARCH" \
        --target-os=darwin \
        --arch=$ARCH \
        --enable-cross-compile \
        --cc=clang \
        --cxx=clang++ \
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
        --enable-videotoolbox \
        --enable-libx264 \
        \
        --enable-decoder=hevc,av1,h264,aac,ac3,eac3,opus \
        --enable-decoder=h264_videotoolbox,hevc_videotoolbox \
        \
        --enable-hwaccel=h264_videotoolbox,hevc_videotoolbox \
        \
        --enable-encoder=libx264,aac \
        --enable-encoder=h264_videotoolbox \
        \
        --enable-parser=hevc,av1,h264,aac,ac3,opus \
        \
        --enable-demuxer=matroska,hls \
        --enable-muxer=hls,mpegts \
        \
        --enable-protocol=file,pipe,http,https,tcp,tls \
        \
        --enable-filter=scale,format \
        \
        --enable-bsf=h264_mp4toannexb,aac_adtstoasc \
        \
        --extra-cflags="-I$OUTPUT_DIR/$ARCH/include $ARCH_FLAGS" \
        --extra-ldflags="-L$OUTPUT_DIR/$ARCH/lib $ARCH_FLAGS"
    
    make -j$(sysctl -n hw.ncpu)
    make install
    
    echo "   ✅ FFmpeg built for $ARCH"
}

# ----------------------------------------
# 5. Build All Architectures
# ----------------------------------------
for ARCH in $ARCHS; do
    echo ""
    echo "================================================"
    echo "Building for $ARCH"
    echo "================================================"
    build_x264 $ARCH
    build_ffmpeg $ARCH
done

# ----------------------------------------
# 6. Create ZIP Package
# ----------------------------------------
echo ""
echo "================================================"
echo "Creating distribution package..."
echo "================================================"

cd "$OUTPUT_DIR"
zip -r "$DIST_DIR/ffmpeg-macos.zip" arm64 x86_64 2>/dev/null || \
zip -r "$DIST_DIR/ffmpeg-macos.zip" .

if [ -f "$DIST_DIR/ffmpeg-macos.zip" ]; then
    echo "✅ Package created: $DIST_DIR/ffmpeg-macos.zip"
    ls -lh "$DIST_DIR/ffmpeg-macos.zip"
else
    echo "❌ Failed to create package!"
    exit 1
fi

# ----------------------------------------
# 7. Summary
# ----------------------------------------
echo ""
echo "================================================"
echo "✅ BUILD COMPLETE!"
echo "================================================"
echo ""
echo "📦 Binary at:"
echo "   arm64: $OUTPUT_DIR/arm64/bin/ffmpeg"
echo "   x86_64: $OUTPUT_DIR/x86_64/bin/ffmpeg"
echo ""
echo "📦 ZIP Package:"
echo "   $DIST_DIR/ffmpeg-macos.zip"
echo ""
echo "📱 Features included:"
echo "   ✅ VideoToolbox (macOS HW decode/encode)"
echo "   ✅ libx264 (Software fallback)"
echo "   ✅ AV1, HEVC, H.264 decoding"
echo "   ✅ MKV input, HLS output"
echo ""
echo "================================================"
echo "⚠️ Note:"
echo "================================================"
echo "This is a universal binary with both arm64 and x86_64."
echo "On Apple Silicon Macs, the arm64 binary will be used."
echo "On Intel Macs, the x86_64 binary will be used."
echo "================================================"
