#!/usr/bin/env python3
"""Build local, pinned LGPL FFmpeg candidates. This script never publishes."""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import tarfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
LOCK = json.loads((ROOT / 'sources.lock.json').read_text())
SOURCES = LOCK['sources']
CACHE = ROOT / '.build/cache'
BUILD = ROOT / '.build/targets'
DIST = ROOT / 'dist/non-gpl-candidate'
TARGETS = ['macos-arm64', 'macos-x86_64', 'linux-x86_64', 'windows-x86_64',
           'android-arm64-v8a', 'android-armeabi-v7a']


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def runtime_notices():
    directory = ROOT / '.build/runtime-notices'
    directory.mkdir(parents=True, exist_ok=True)
    result = []
    for spec in LOCK.get('runtimeNotices', {}).values():
        path = directory / spec['filename']
        if not path.exists():
            urllib.request.urlretrieve(spec['url'], path)
        if digest(path) != spec['sha256']:
            raise RuntimeError(f'Runtime notice checksum mismatch: {path}')
        result.append(path)
    return result


def source_verification_files():
    result = []
    for spec in LOCK.get('verificationFiles', {}).values():
        path = CACHE / spec['filename']
        if not path.exists():
            urllib.request.urlretrieve(spec['url'], path)
        if digest(path) != spec['sha256']:
            raise RuntimeError(f'Source verification file checksum mismatch: {path}')
        result.append(path)
    return result


def fetch(name):
    spec = SOURCES[name]
    CACHE.mkdir(parents=True, exist_ok=True)
    archive = CACHE / spec['filename']
    if not archive.exists():
        temporary = archive.with_suffix(archive.suffix + '.download')
        urllib.request.urlretrieve(spec['url'], temporary)
        temporary.rename(archive)
    if digest(archive) != spec['sha256']:
        raise RuntimeError(f'Checksum mismatch: {archive}')
    return archive


def extract(name, directory):
    destination = directory / name
    if destination.exists():
        return destination
    archive = fetch(name)
    staging = directory / (name + '-extract')
    staging.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive) as package:
        package.extractall(staging, filter='data')
    children = list(staging.iterdir())
    if len(children) != 1 or not children[0].is_dir():
        raise RuntimeError(f'Unexpected source layout: {archive}')
    children[0].rename(destination)
    staging.rmdir()
    return destination


def execute(args, cwd, env, log):
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open('w') as output:
        output.write(shlex.join(map(str, args)) + '\n')
        output.flush()
        result = subprocess.run(list(map(str, args)), cwd=cwd, env=env,
                                stdout=output, stderr=subprocess.STDOUT)
    if result.returncode:
        tail = '\n'.join(log.read_text(errors='replace').splitlines()[-35:])
        raise RuntimeError(f'{log.name} failed ({result.returncode}):\n{tail}')


def which(name):
    found = shutil.which(name)
    if not found:
        raise RuntimeError(f'Required tool missing: {name}')
    return found


def build(target, jobs, ndk):
    directory = BUILD / target
    directory.mkdir(parents=True, exist_ok=True)
    logs = directory / 'logs'
    prefix = directory / 'install'
    env = dict(os.environ)
    # In particular, do not pick Android clang from the host PATH for macOS.
    for name in ['CC', 'CXX', 'CFLAGS', 'CXXFLAGS', 'CPPFLAGS', 'LDFLAGS',
                 'CPATH', 'C_INCLUDE_PATH', 'CPLUS_INCLUDE_PATH', 'LIBRARY_PATH', 'SDKROOT',
                 'PKG_CONFIG_SYSROOT_DIR']:
        env.pop(name, None)
    env['PKG_CONFIG_PATH'] = str(prefix / 'lib/pkgconfig')
    env['PKG_CONFIG_LIBDIR'] = env['PKG_CONFIG_PATH']
    extra_cflags = ['-I' + str(prefix / 'include')]
    extra_ldflags = ['-L' + str(prefix / 'lib')]
    cmake_args = []
    ffmpeg_args = []
    openh264_args = []
    additional_sources = []
    if target.startswith('macos-'):
        if platform.system() != 'Darwin':
            raise RuntimeError('macOS builds require the Apple SDK on macOS')
        arch = target.removeprefix('macos-')
        sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path']).decode().strip()
        cc = subprocess.check_output(['xcrun', '--find', 'clang']).decode().strip()
        cxx = subprocess.check_output(['xcrun', '--find', 'clang++']).decode().strip()
        env['PATH'] = str(Path(cc).parent) + os.pathsep + env['PATH']
        env['SDKROOT'] = sdk
        ar, ranlib, strip = '/usr/bin/ar', '/usr/bin/ranlib', '/usr/bin/strip'
        extra_cflags += ['-arch', arch, '-isysroot', sdk, '-mmacosx-version-min=11.0']
        extra_ldflags += ['-arch', arch, '-isysroot', sdk, '-mmacosx-version-min=11.0']
        cmake_args += ['-DCMAKE_OSX_ARCHITECTURES=' + arch, '-DCMAKE_OSX_SYSROOT=' + sdk,
                       '-DCMAKE_OSX_DEPLOYMENT_TARGET=11.0']
        openh264_args += ['OS=darwin', 'ARCH=' + arch,
                         'CC=' + shlex.join([cc, '-arch', arch, '-isysroot', sdk]),
                         'CXX=' + shlex.join([cxx, '-arch', arch, '-isysroot', sdk])]
        ffmpeg_args += ['--target-os=darwin', '--arch=' + arch, '--enable-cross-compile',
                       '--enable-securetransport', '--enable-videotoolbox',
                       '--enable-hwaccel=h264_videotoolbox,hevc_videotoolbox',
                       '--enable-encoder=h264_videotoolbox']
    elif target == 'windows-x86_64':
        cc, cxx = which('x86_64-w64-mingw32-gcc'), which('x86_64-w64-mingw32-g++')
        ar, ranlib, strip = [which('x86_64-w64-mingw32-' + suffix)
                            for suffix in ['gcc-ar', 'gcc-ranlib', 'strip']]
        cmake_args += ['-DCMAKE_SYSTEM_NAME=Windows', '-DCMAKE_RC_COMPILER=' + which('x86_64-w64-mingw32-windres')]
        openh264_args += ['OS=mingw_nt', 'ARCH=x86_64', 'CC=' + cc, 'CXX=' + cxx]
        extra_ldflags += ['-static']
        ffmpeg_args += ['--target-os=mingw32', '--arch=x86_64', '--enable-cross-compile',
                       '--cross-prefix=x86_64-w64-mingw32-', '--enable-schannel',
                       '--enable-d3d11va', '--enable-nvenc', '--enable-ffnvcodec', '--enable-amf',
                       '--enable-hwaccel=h264_d3d11va,hevc_d3d11va,av1_d3d11va',
                       '--enable-encoder=h264_nvenc,h264_amf']
        additional_sources += ['nvcodec', 'amf']
    elif target.startswith('android-'):
        if not ndk or not (ndk / 'source.properties').is_file():
            raise RuntimeError('Set ANDROID_NDK_HOME or --ndk to Android NDK r29')
        if '29.0.14206865' not in (ndk / 'source.properties').read_text():
            raise RuntimeError('The release toolchain is pinned to NDK 29.0.14206865')
        abi = target.removeprefix('android-')
        arm64 = abi == 'arm64-v8a'
        triple = 'aarch64-linux-android' if arm64 else 'armv7a-linux-androideabi'
        host = 'darwin-x86_64' if platform.system() == 'Darwin' else 'linux-x86_64'
        toolchain = ndk / 'toolchains/llvm/prebuilt' / host / 'bin'
        cc, cxx = str(toolchain / (triple + '24-clang')), str(toolchain / (triple + '24-clang++'))
        ar, ranlib, strip = [str(toolchain / ('llvm-' + suffix)) for suffix in ['ar', 'ranlib', 'strip']]
        cmake_args += ['-DCMAKE_TOOLCHAIN_FILE=' + str(ndk / 'build/cmake/android.toolchain.cmake'),
                       '-DANDROID_ABI=' + abi, '-DANDROID_PLATFORM=android-24', '-DANDROID_STL=c++_static']
        openh264_args += ['OS=android', 'ARCH=' + ('arm64' if arm64 else 'arm'),
                         'NDKROOT=' + str(ndk), 'NDKLEVEL=24', 'TARGET=android-24',
                         'CC=' + cc, 'CXX=' + cxx]
        # Standalone Bionic executables need neither a sibling C++ runtime nor
        # a specific device's dynamic linker layout. MediaCodec/JNI is not used
        # by this public backend's software-transcode command.
        extra_ldflags += ['-static', '-static-libstdc++', '-Wl,-z,max-page-size=16384']
        ffmpeg_args += ['--target-os=android', '--arch=' + ('aarch64' if arm64 else 'arm'),
                       '--enable-cross-compile', '--enable-pic', '--enable-version3', '--enable-mbedtls']
        additional_sources += ['mbedtls']
    else:
        if platform.system() != 'Linux' or platform.machine() not in ['x86_64', 'amd64']:
            raise RuntimeError('Linux x86_64 builds run in a dedicated Linux x86_64 container')
        cc, cxx = which('gcc'), which('g++')
        ar, ranlib, strip = which('ar'), which('ranlib'), which('strip')
        # Host pkg-config is used only for the explicitly enabled VAAPI/DRM system APIs.
        env['PKG_CONFIG_LIBDIR'] += ':/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/share/pkgconfig'
        openh264_args += ['OS=linux', 'ARCH=x86_64', 'CC=' + cc, 'CXX=' + cxx]
        ffmpeg_args += ['--enable-version3', '--enable-mbedtls', '--enable-vaapi', '--enable-libdrm',
                       '--enable-hwaccel=h264_vaapi,hevc_vaapi,av1_vaapi', '--enable-encoder=h264_vaapi',
                       '--enable-filter=scale_vaapi,hwupload']
        additional_sources += ['mbedtls']
    if not target.startswith('android-'):
        cmake_args += ['-DCMAKE_C_COMPILER=' + cc, '-DCMAKE_CXX_COMPILER=' + cxx]
    for name in ['ffmpeg', 'openh264', 'libxml2'] + additional_sources:
        extract(name, directory)
    cmake = which('cmake')

    def cmake_library(name, options):
        output = directory / (name + '-build')
        command = [cmake, '-S', directory / name, '-B', output, '-G', 'Ninja',
                   '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_INSTALL_PREFIX=' + str(prefix),
                   '-DCMAKE_INSTALL_LIBDIR=lib', '-DCMAKE_POSITION_INDEPENDENT_CODE=ON',
                   '-DBUILD_SHARED_LIBS=OFF'] + cmake_args + options
        execute(command, directory, env, logs / (name + '-configure.log'))
        execute([cmake, '--build', output, '--parallel', jobs], directory, env, logs / (name + '-build.log'))
        execute([cmake, '--install', output], directory, env, logs / (name + '-install.log'))

    print(target + ': building dependencies', flush=True)
    cmake_library('libxml2', ['-DLIBXML2_WITH_PYTHON=OFF', '-DLIBXML2_WITH_PROGRAMS=OFF',
                            '-DLIBXML2_WITH_TESTS=OFF', '-DLIBXML2_WITH_ICONV=OFF',
                            '-DLIBXML2_WITH_ZLIB=OFF', '-DLIBXML2_WITH_LZMA=OFF',
                            '-DLIBXML2_WITH_HTTP=OFF', '-DLIBXML2_WITH_FTP=OFF'])
    execute(['make', '-j' + str(jobs), *openh264_args, 'AR=' + ar, 'RANLIB=' + ranlib,
             'PREFIX=' + str(prefix), 'install-static', 'V=No'], directory / 'openh264', env,
            logs / 'openh264-build.log')
    if target.startswith('android-'):
        # The backend extracts only the two executables. Avoid a runtime dependency
        # on a sibling libc++_shared.so that it cannot install or locate.
        pc = prefix / 'lib/pkgconfig/openh264.pc'
        pc.write_text(pc.read_text().replace('-lc++_shared', '-lc++_static -lc++abi')
                      .replace('-lstdc++', '-lc++_static -lc++abi'))
    if 'mbedtls' in additional_sources:
        cmake_library('mbedtls', ['-DENABLE_PROGRAMS=OFF', '-DENABLE_TESTING=OFF',
                                 '-DUSE_SHARED_MBEDTLS_LIBRARY=OFF', '-DUSE_STATIC_MBEDTLS_LIBRARY=ON',
                                 '-DMBEDTLS_FATAL_WARNINGS=OFF'])
    if 'nvcodec' in additional_sources:
        execute(['make', 'PREFIX=' + str(prefix), 'install'], directory / 'nvcodec', env, logs / 'nvcodec-install.log')
        shutil.copytree(directory / 'amf/amf/public/include', prefix / 'include/AMF', dirs_exist_ok=True)
    args = ['./configure', '--prefix=' + str(prefix), '--cc=' + cc, '--cxx=' + cxx,
            '--ld=' + cxx, '--ar=' + ar, '--ranlib=' + ranlib, '--strip=' + strip,
            '--enable-static', '--disable-shared', '--disable-everything',
            '--disable-gpl', '--disable-nonfree', '--disable-autodetect',
            '--enable-small', '--disable-debug', '--disable-doc',
            '--enable-ffmpeg', '--enable-ffprobe', '--enable-libopenh264', '--enable-libxml2',
            '--enable-avcodec', '--enable-avformat', '--enable-avutil', '--enable-avfilter',
            '--enable-swscale', '--enable-swresample',
            '--enable-decoder=hevc,av1,h264,mjpeg,aac,ac3,eac3,flac,opus,pcm_s16le,ass,ssa,subrip,webvtt,movtext',
            '--enable-encoder=libopenh264,aac,pcm_s16le,rawvideo,webvtt',
            '--enable-parser=hevc,av1,h264,mjpeg,aac,ac3,eac3,flac,opus',
            '--enable-demuxer=dash,hls,matroska,mov,mpegts,aac,wav',
            '--enable-muxer=dash,hls,mpegts,mp4,rawvideo,wav,webvtt',
            '--enable-protocol=file,pipe,http,https,tcp,tls,crypto,data,httpproxy',
            '--enable-filter=scale,format,aresample',
            '--enable-bsf=h264_mp4toannexb,aac_adtstoasc', '--pkg-config=' + which('pkg-config'),
            '--pkg-config-flags=--static',
            '--extra-cflags=' + shlex.join(extra_cflags),
            '--extra-ldflags=' + shlex.join(extra_ldflags), *ffmpeg_args]
    print(target + ': configuring FFmpeg', flush=True)
    execute(args, directory / 'ffmpeg', env, logs / 'ffmpeg-configure.log')
    config = (directory / 'ffmpeg/config.h').read_text()
    if '#define CONFIG_GPL 0' not in config or '#define CONFIG_NONFREE 0' not in config:
        raise RuntimeError('Refusing a GPL or nonfree build')
    (directory / 'configure-arguments.json').write_text(json.dumps(args, indent=2) + '\n')
    print(target + ': compiling FFmpeg', flush=True)
    execute(['make', '-j' + str(jobs)], directory / 'ffmpeg', env, logs / 'ffmpeg-build.log')
    execute(['make', 'install'], directory / 'ffmpeg', env, logs / 'ffmpeg-install.log')
    metadata = {
        'target': target, 'ffmpegVersion': SOURCES['ffmpeg']['version'],
        'license': 'LGPL-3.0-or-later' if 'mbedtls' in additional_sources else 'LGPL-2.1-or-later',
        'gpl': False, 'nonfree': False, 'configureArguments': args,
        'sources': {name: SOURCES[name] for name in ['ffmpeg', 'openh264', 'libxml2'] + additional_sources},
        'compiler': subprocess.check_output([cc, '--version'], env=env).decode().splitlines()[0],
        'sourceTree': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT).decode().strip(),
        'sourceTreeHasLocalChanges': bool(subprocess.check_output(
            ['git', 'status', '--porcelain=v1', '--untracked-files=all'], cwd=ROOT).strip()),
        'builtAtUtc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'validation': 'compiled; runtime validation required before publication',
    }
    (directory / 'build-manifest.json').write_text(json.dumps(metadata, indent=2) + '\n')
    if target.startswith('android-'):
        notices = directory / 'runtime-notices'
        notices.mkdir(exist_ok=True)
        shutil.copy2(ndk / 'toolchains/llvm/prebuilt' / host / 'sysroot/NOTICE', notices / 'android-runtime-NOTICE')
        shutil.copy2(ndk / 'toolchains/llvm/prebuilt' / host / 'NOTICE', notices / 'llvm-runtime-NOTICE')
        shutil.copy2(ndk / 'sources/android/cpufeatures/NOTICE', notices / 'ndk-cpufeatures-NOTICE')
    package_target(target)
    print(target + ': candidate ready', flush=True)


def package_target(target):
    directory = BUILD / target
    metadata = json.loads((directory / 'build-manifest.json').read_text())
    stage = directory / 'package'
    if stage.exists():
        shutil.rmtree(stage)
    (stage / 'bin').mkdir(parents=True)
    for executable in ['ffmpeg', 'ffprobe']:
        suffix = '.exe' if target == 'windows-x86_64' else ''
        shutil.copy2(directory / 'install/bin' / (executable + suffix), stage / 'bin')
    licenses = stage / 'licenses'
    licenses.mkdir()
    for name in metadata['sources']:
        source = directory / name
        for candidate in ['COPYING.LGPLv2.1', 'COPYING.LGPLv3', 'LICENSE', 'LICENSE.txt',
                          'COPYING', 'LICENSE.md', 'Copyright', 'COPYRIGHT', 'NOTICE']:
            path = source / candidate
            if path.is_file():
                shutil.copy2(path, licenses / (name + '-' + candidate))
        if name == 'nvcodec':
            # This header-only dependency stores its MIT notices in the headers.
            blocks = []
            for header in sorted((source / 'include/ffnvcodec').glob('*.h')):
                text = header.read_text()
                if text.startswith('/*'):
                    blocks.append(header.name + '\n' + text[:text.index('*/') + 2] + '\n')
            (licenses / 'nvcodec-header-NOTICES.txt').write_text('\n'.join(blocks))
        if name == 'mbedtls':
            (licenses / 'mbedtls-selected-license.txt').write_text(
                'This build uses mbedTLS under the Apache-2.0 option of its dual license.\n'
                'The original upstream LICENSE is included unchanged.\n')
    if target.startswith(('windows-', 'linux-')):
        for path in runtime_notices():
            shutil.copy2(path, licenses / path.name)
    for path in (directory / 'runtime-notices').glob('*'):
        shutil.copy2(path, licenses / path.name)
    shutil.copy2(directory / 'build-manifest.json', stage / 'build-manifest.json')
    shutil.copy2(directory / 'ffmpeg/config.h', stage / 'config.h')
    (stage / 'SOURCE.txt').write_text('Exact source archives, build scripts, and the source lock are in ffmpeg-corresponding-source.tar.xz supplied alongside the binary archives.\nNo FFmpeg or dependency source patches were applied.\n')
    return stage


def package_release():
    DIST.mkdir(parents=True, exist_ok=True)
    for target in TARGETS:
        build_dir = BUILD / target
        metadata = json.loads((build_dir / 'build-manifest.json').read_text())
        validation = metadata['validation']
        if not isinstance(validation, dict) or validation.get('status') != 'passed':
            raise RuntimeError(f'{target}: runtime validation is required before packaging')
        binaries = build_dir / 'install/bin'
        if not binaries.exists():
            binaries = build_dir / 'package/bin'
        for name, expected in validation['binarySha256'].items():
            suffix = '.exe' if target == 'windows-x86_64' else ''
            if digest(binaries / (name + suffix)) != expected:
                raise RuntimeError(f'{target}: {name} changed after runtime validation')
    groups = {
        'ffmpeg-macos.zip': [('macos-arm64', 'arm64'), ('macos-x86_64', 'x86_64')],
        'ffmpeg-linux-static.zip': [('linux-x86_64', 'ffmpeg-linux-static')],
        'ffmpeg-win-static.zip': [('windows-x86_64', 'ffmpeg-win-static')],
        # Exact historical extractor paths are essential: its filename-only
        # fallback could otherwise choose arm64 when the caller needs ARMv7.
        'ffmpeg-android.zip': [('android-arm64-v8a', 'ffmpeg-android/arm64-v8a'),
                               ('android-armeabi-v7a', 'ffmpeg-android/armeabi-v7a')],
    }
    for name, members in groups.items():
        for target, _ in members:
            if (BUILD / target / 'ffmpeg').exists():
                package_target(target)
        with zipfile.ZipFile(DIST / name, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            for target, subdir in members:
                stage = BUILD / target / 'package'
                for path in sorted(stage.rglob('*')):
                    if path.is_file():
                        archive.write(path, str(Path(subdir) / path.relative_to(stage)))
                for path in sorted((BUILD / target / 'validation').glob('*.json')):
                    archive.write(path, str(Path(subdir) / 'validation' / path.name))
    with tarfile.open(DIST / 'ffmpeg-corresponding-source.tar.xz', 'w:xz') as archive:
        for name in SOURCES:
            archive.add(fetch(name), arcname='sources/' + SOURCES[name]['filename'])
        for path in [ROOT / 'sources.lock.json',
                     *sorted((ROOT / 'scripts').glob('*.py')), *sorted(ROOT.glob('build-ffmpeg*.sh')),
                     *sorted((ROOT / '.github/workflows').glob('*.yml'))]:
            archive.add(path, arcname='build/' + str(path.relative_to(ROOT)))
        for path in runtime_notices():
            archive.add(path, arcname='runtime-notices/' + path.name)
        for path in [*source_verification_files(), CACHE / 'ffmpeg-signature-verification.txt']:
            if path.exists():
                archive.add(path, arcname='verification/' + path.name)
    hashes = ''.join(f'{digest(path)}  {path.name}\n' for path in sorted(DIST.iterdir())
                     if path.is_file() and path.name != 'SHA256SUMS')
    (DIST / 'SHA256SUMS').write_text(hashes)
    print('Local release candidate: ' + str(DIST), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', action='append', choices=TARGETS)
    parser.add_argument('--jobs', type=int, default=6)
    parser.add_argument('--ndk', type=Path, default=os.environ.get('ANDROID_NDK_HOME'))
    parser.add_argument('--package', action='store_true')
    parser.add_argument('--stage-only', action='store_true')
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error('--jobs must be positive')
    for target in args.target or []:
        if args.stage_only:
            package_target(target)
        else:
            build(target, args.jobs, Path(args.ndk) if args.ndk else None)
    if args.package:
        package_release()
    if not args.target and not args.package:
        parser.error('Choose --target or --package')
