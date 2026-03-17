#!/bin/bash
set -e

# ============================================
# FFmpeg 7.1 for Android - Using Existing NDK
# ============================================

# === Output Configuration ===
if [ -n "$GITHUB_WORKSPACE" ]; then
    WORKSPACE="$GITHUB_WORKSPACE"
else
    WORKSPACE="$(pwd)"
fi

DIST_DIR="$WORKSPACE/dist"
OUTPUT_DIR="$WORKSPACE/ffmpeg-android-output"
BUILD_DIR="/tmp/ffmpeg-android-build"

mkdir -p "$DIST_DIR" "$OUTPUT_DIR" "$BUILD_DIR"

# === Android SDK/NDK Environment ===
export ANDROID_HOME=/home/runner/android-sdk
export ANDROID_NDK_HOME=$ANDROID_HOME/ndk/26.1.10909125
export ANDROID_NDK=$ANDROID_NDK_HOME
export PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools
export TOOLCHAIN=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin
export RANLIB_aarch64_linux_android=$TOOLCHAIN/llvm-ranlib
export AR_aarch64_linux_android=$TOOLCHAIN/llvm-ar

# === Build Configuration ===
API_LEVEL=24  # Android 7.0 minimum
BUILD_DIR="/home/runner/ffmpeg-android-build"
OUTPUT_DIR="/home/runner/ffmpeg-android"
ARCHS="arm64-v8a armeabi-v7a"

# === Verify NDK ===
if [ ! -d "$ANDROID_NDK_HOME" ]; then
    echo "⚠️  NDK not found. Installing..."
    
    # Install Android command-line tools if not present
    if [ ! -d "$ANDROID_HOME/cmdline-tools/latest" ]; then
        echo "Installing Android command-line tools..."
        mkdir -p ~/android-sdk/cmdline-tools
        wget https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip -O cmdline-tools.zip
        unzip cmdline-tools.zip -d ~/android-sdk/cmdline-tools
        mv ~/android-sdk/cmdline-tools/cmdline-tools ~/android-sdk/cmdline-tools/latest
        rm cmdline-tools.zip
    fi
    
    # Install NDK
    echo "Installing NDK..."
    yes | $ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager --licenses > /dev/null 2>&1 || true
    $ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager "ndk;26.1.10909125"
    
    echo "✅ NDK installed: $ANDROID_NDK_HOME"
else
    echo "✅ Using NDK: $ANDROID_NDK_HOME"
fi

mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

# ----------------------------------------
# 1. Download FFmpeg
# ----------------------------------------
cd "$BUILD_DIR"
if [ ! -d "ffmpeg-7.1" ]; then
    echo "[1/3] Downloading FFmpeg 7.1..."
    wget -q --show-progress https://ffmpeg.org/releases/ffmpeg-7.1.tar.xz
    tar xf ffmpeg-7.1.tar.xz
else
    echo "[1/3] FFmpeg already downloaded..."
fi

# ----------------------------------------
# 2. Build OpenH264
# ----------------------------------------
build_openh264() {
    ARCH=$1
    OPENH264_DIR="$BUILD_DIR/openh264-$ARCH"
    
    echo "[2/3] Building OpenH264 for $ARCH..."
    
    cd "$BUILD_DIR"
    
    if [ -f "$OUTPUT_DIR/$ARCH/lib/libopenh264.a" ]; then
        echo "   Already built, skipping..."
        return
    fi
    
    if [ ! -d "$OPENH264_DIR" ]; then
        git clone --depth 1 https://github.com/cisco/openh264.git "$OPENH264_DIR"
    fi
    
    if [ "$ARCH" == "arm64-v8a" ]; then
        OPENH264_ARCH="arm64"
    else
        OPENH264_ARCH="arm"
    fi
    
    cd "$OPENH264_DIR"
    make clean 2>/dev/null || true
    make -j$(nproc) \
        OS=android \
        ARCH="$OPENH264_ARCH" \
        NDKROOT="$ANDROID_NDK_HOME" \
        TARGET="android-$API_LEVEL" \
        NDKLEVEL="$API_LEVEL" \
        PREFIX="$OUTPUT_DIR/$ARCH" \
        install-static \
        V=No

    if [ -f "$OUTPUT_DIR/$ARCH/lib/pkgconfig/openh264.pc" ]; then
        if grep -q '^Libs\.private:' "$OUTPUT_DIR/$ARCH/lib/pkgconfig/openh264.pc"; then
            sed -i 's/^Libs\.private:.*/Libs.private: -lc++_static/' "$OUTPUT_DIR/$ARCH/lib/pkgconfig/openh264.pc"
        else
            echo 'Libs.private: -lc++_static' >> "$OUTPUT_DIR/$ARCH/lib/pkgconfig/openh264.pc"
        fi
    fi
    
    echo "   ✅ OpenH264 built"
    cd ..
}
# ----------------------------------------
# 3. Build FFmpeg
# ----------------------------------------
build_ffmpeg() {
    ARCH=$1
    
    echo "[3/3] Building FFmpeg for $ARCH..."
    
    cd "$BUILD_DIR/ffmpeg-7.1"
    make distclean 2>/dev/null || true
    
    if [ "$ARCH" == "arm64-v8a" ]; then
        TARGET_ARCH="aarch64"
        CROSS_PREFIX="$TOOLCHAIN/aarch64-linux-android${API_LEVEL}-"
        CC="$TOOLCHAIN/aarch64-linux-android${API_LEVEL}-clang"
        CXX="$TOOLCHAIN/aarch64-linux-android${API_LEVEL}-clang++"
        AR="$TOOLCHAIN/llvm-ar"
        RANLIB="$TOOLCHAIN/llvm-ranlib"
        STRIP="$TOOLCHAIN/llvm-strip"
        NM="$TOOLCHAIN/llvm-nm"
        CPU="armv8-a"
        OPENH264_EXTRA_LIBS="-lc++_static -lc++abi -lunwind"
    else
        TARGET_ARCH="arm"
        CROSS_PREFIX="$TOOLCHAIN/armv7a-linux-androideabi${API_LEVEL}-"
        CC="$TOOLCHAIN/armv7a-linux-androideabi${API_LEVEL}-clang"
        CXX="$TOOLCHAIN/armv7a-linux-androideabi${API_LEVEL}-clang++"
        AR="$TOOLCHAIN/llvm-ar"
        RANLIB="$TOOLCHAIN/llvm-ranlib"
        STRIP="$TOOLCHAIN/llvm-strip"
        NM="$TOOLCHAIN/llvm-nm"
        CPU="armv7-a"
        OPENH264_EXTRA_LIBS="-lc++_static -lc++abi -lunwind -latomic"
    fi
    
    SYSROOT="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
    
    export PKG_CONFIG_PATH="$OUTPUT_DIR/$ARCH/lib/pkgconfig"
    export PKG_CONFIG_LIBDIR="$OUTPUT_DIR/$ARCH/lib/pkgconfig"

    PKG_CONFIG_WRAPPER="$BUILD_DIR/pkg-config-$ARCH.sh"
    cat > "$PKG_CONFIG_WRAPPER" <<EOF
#!/usr/bin/env bash
export PKG_CONFIG_PATH="$OUTPUT_DIR/$ARCH/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$OUTPUT_DIR/$ARCH/lib/pkgconfig"
output=\$(pkg-config "\$@")
status=\$?
if [ \$status -ne 0 ]; then
    exit \$status
fi

case " \$* " in
    *" --libs "*|*" --static "*)
        case " \$* " in
            *" openh264 "*)
                cleaned_output=\$(printf '%s\n' "\$output" | sed 's/-lstdc++//g')
                printf '%s %s\n' "\$cleaned_output" "$OPENH264_EXTRA_LIBS"
                ;;
            *)
                printf '%s\n' "\$output"
                ;;
        esac
        ;;
    *)
        printf '%s\n' "\$output"
        ;;
esac
EOF
    chmod +x "$PKG_CONFIG_WRAPPER"

    "$PKG_CONFIG_WRAPPER" --exists openh264
    echo "   OpenH264 version: $("$PKG_CONFIG_WRAPPER" --modversion openh264)"
    echo "   OpenH264 libs: $("$PKG_CONFIG_WRAPPER" --libs --static openh264)"
    
    if ! ./configure \
        --prefix="$OUTPUT_DIR/$ARCH" \
        --target-os=android \
        --arch=$TARGET_ARCH \
        --cpu=$CPU \
        --cc=$CC \
        --cxx=$CXX \
        --ld=$CXX \
        --ar=$AR \
        --ranlib=$RANLIB \
        --strip=$STRIP \
        --nm=$NM \
        --cross-prefix=$CROSS_PREFIX \
        --sysroot=$SYSROOT \
        --pkg-config="$PKG_CONFIG_WRAPPER" \
        --pkg-config-flags="--static" \
        --enable-cross-compile \
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
        \
        --enable-mediacodec \
        --enable-jni \
        \
        --enable-libopenh264 \
        \
        --enable-decoder=hevc,av1,h264,aac,ac3,eac3,flac,opus,ass,ssa,subrip,webvtt,mov_text \
        --enable-decoder=h264_mediacodec,hevc_mediacodec,av1_mediacodec \
        \
        --enable-hwaccel=h264_mediacodec,hevc_mediacodec \
        \
        --enable-encoder=libopenh264,aac,webvtt \
        --enable-encoder=h264_mediacodec \
        \
        --enable-parser=hevc,av1,h264,aac,ac3,eac3,flac,opus \
        \
        --enable-demuxer=matroska,hls \
        --enable-muxer=hls,mpegts,webvtt \
        \
        --enable-protocol=file,pipe,http,https,tcp,tls \
        \
        --enable-filter=scale,format,aresample \
        \
        --enable-bsf=h264_mp4toannexb,aac_adtstoasc \
        \
        --extra-cflags="-I$OUTPUT_DIR/$ARCH/include -fPIC -DANDROID -D__ANDROID_API__=$API_LEVEL" \
        --extra-ldflags="-L$OUTPUT_DIR/$ARCH/lib -lm -llog" \
        --extra-libs="$OPENH264_EXTRA_LIBS"; then
        echo "   ❌ FFmpeg configure failed for $ARCH. Dumping ffbuild/config.log..."
        cat ffbuild/config.log
        return 1
    fi

    make -j$(nproc)
    make install
    
    echo "   ✅ FFmpeg built"
}

# ----------------------------------------
# 4. Build All Architectures
# ----------------------------------------
for ARCH in $ARCHS; do
    echo ""
    echo "================================================"
    echo "Building for $ARCH"
    echo "================================================"
    build_openh264 $ARCH
    build_ffmpeg $ARCH
done

# ----------------------------------------
# 5. Create ZIP Package
# ----------------------------------------
echo ""
echo "================================================"
echo "Creating distribution package..."
echo "================================================"

cd "$OUTPUT_DIR"
zip -r "$DIST_DIR/ffmpeg-android.zip" arm64-v8a armeabi-v7a 2>/dev/null || \
zip -r "$DIST_DIR/ffmpeg-android.zip" .

if [ -f "$DIST_DIR/ffmpeg-android.zip" ]; then
    echo "✅ Package created: $DIST_DIR/ffmpeg-android.zip"
    ls -lh "$DIST_DIR/ffmpeg-android.zip"
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
echo "📦 Libraries at:"
for ARCH in $ARCHS; do
    echo "   $OUTPUT_DIR/$ARCH/lib/"
done
echo ""
echo "📱 Features included:"
echo "   ✅ MediaCodec (Android HW decode/encode)"
echo "   ✅ libopenh264 (Software fallback)"
echo "   ✅ MKV input"
