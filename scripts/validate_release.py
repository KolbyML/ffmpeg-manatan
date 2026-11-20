#!/usr/bin/env python3
"""Exercise the compiled release binaries; save evidence without publishing."""
import argparse
import functools
import hashlib
import http.server
import json
import math
import os
from pathlib import Path
import shlex
import shutil
import ssl
import struct
import subprocess
import threading
import tempfile
import wave

ROOT = Path(__file__).resolve().parents[1]


def validate(target, wine=None, adb=None, qemu=None):
    build = ROOT / '.build/targets' / target
    metadata = json.loads((build / 'build-manifest.json').read_text())
    metadata['validation'] = {'status': 'running'}
    (build / 'build-manifest.json').write_text(json.dumps(metadata, indent=2) + '\n')
    work = ROOT / '.build/validation' / target
    work.mkdir(parents=True, exist_ok=True)
    evidence = build / 'validation'
    evidence.mkdir(exist_ok=True)
    suffix = '.exe' if wine else ''
    executables = {name: build / 'install/bin' / (name + suffix) for name in ['ffmpeg', 'ffprobe']}
    environment = dict(os.environ)
    environment.update(WINEDEBUG='-all', WINEPREFIX=os.environ.get(
        'FFMPEG_WINE_PREFIX', str(Path(tempfile.gettempdir()) / 'codex_ffmpeg_wine_01a1f643')))
    remote = '/data/local/tmp/codex_ffmpeg_01a1f643/' + target
    if adb:
        subprocess.run(['adb', '-s', adb, 'shell', 'mkdir', '-p', remote + '/bin', remote + '/work'], check=True, capture_output=True)
        for name, path in executables.items():
            subprocess.run(['adb', '-s', adb, 'push', str(path), remote + '/bin/' + name], check=True, capture_output=True)
        subprocess.run(['adb', '-s', adb, 'shell', 'chmod', '755', remote + '/bin/ffmpeg', remote + '/bin/ffprobe'], check=True, capture_output=True)
    sequence = 0

    def run(name, args):
        nonlocal sequence
        sequence += 1
        strings = [str(arg) for arg in args]
        if adb:
            subprocess.run(['adb', '-s', adb, 'push', str(work) + '/.', remote + '/work/'], check=True, capture_output=True)
            strings = [arg.replace(str(work), remote + '/work') for arg in strings]
            command = ['adb', '-s', adb, 'shell', shlex.join([remote + '/bin/' + name, *strings])]
        elif wine:
            # FFmpeg's DASH muxer needs forward slashes when deriving segment paths.
            strings = [('Z:' + arg) if arg.startswith('/') else arg for arg in strings]
            command = [wine, str(executables[name]), *strings]
        elif qemu:
            command = [qemu, str(executables[name]), *strings]
        else:
            command = [str(executables[name]), *strings]
        result = subprocess.run(command, capture_output=True, env=environment, timeout=120)
        log = {'command': command, 'exitCode': result.returncode,
               'stdout': result.stdout.decode(errors='replace'),
               'stderr': result.stderr.decode(errors='replace')}
        (evidence / f'{sequence:02d}-{name}.json').write_text(json.dumps(log, indent=2) + '\n')
        if result.returncode:
            raise RuntimeError(f'{target}: {shlex.join(command)}\n{log["stderr"]}')
        if adb:
            subprocess.run(['adb', '-s', adb, 'pull', remote + '/work/.', str(work)], check=True, capture_output=True)
        return result.stdout.decode(errors='replace')

    license_text = run('ffmpeg', ['-hide_banner', '-L'])
    assert 'GNU Lesser General Public License' in ' '.join(license_text.split()), license_text
    probe_license = run('ffprobe', ['-hide_banner', '-L'])
    assert 'GNU Lesser General Public License' in ' '.join(probe_license.split()), probe_license
    config = run('ffmpeg', ['-hide_banner', '-buildconf'])
    assert '--disable-gpl' in config and '--disable-nonfree' in config
    for forbidden in ['--enable-gpl', '--enable-nonfree', '--enable-libx264', '--enable-libx265', '--enable-libfdk-aac']:
        assert forbidden not in config, forbidden
    probe_config = run('ffprobe', ['-hide_banner', '-buildconf'])
    assert '--disable-gpl' in probe_config and '--disable-nonfree' in probe_config
    assert '--enable-gpl' not in probe_config and '--enable-nonfree' not in probe_config
    encoders = run('ffmpeg', ['-hide_banner', '-encoders'])
    for needed in ['libopenh264', 'aac', 'rawvideo', 'webvtt']:
        assert needed in encoders, needed
    assert 'libx264' not in encoders and 'libx265' not in encoders
    for name, expected in [('protocols', ['https', 'tls', 'crypto', 'data']),
                           ('demuxers', ['dash', 'mov,mp4', 'matroska']),
                           ('muxers', ['mpegts', 'mp4', 'webvtt']),
                           ('filters', ['aresample', 'scale'])]:
        text = run('ffmpeg', ['-hide_banner', '-' + name])
        for item in expected:
            assert item in text, (name, item)
    hardware = {'macos': ['h264_videotoolbox'], 'windows': ['h264_nvenc', 'h264_amf'], 'linux': ['h264_vaapi']}
    for prefix, names in hardware.items():
        if target.startswith(prefix):
            assert all(name in encoders for name in names)

    wav = work / 'input.wav'
    with wave.open(str(wav), 'wb') as audio:
        audio.setparams((1, 2, 44100, 0, 'NONE', 'not compressed'))
        audio.writeframes(b''.join(struct.pack('<h', int(12000 * math.sin(2 * math.pi * 440 * sample / 44100)))
                                   for sample in range(4 * 44100)))
    fixture = ROOT / '.build/validation-fixtures/input.mp4'
    if not fixture.is_file():
        raise RuntimeError('Generate the synthetic video fixture with scripts/make_test_fixture.py first')
    shutil.copy2(fixture, work / 'input.mp4')
    clip = work / 'video.ts'
    run('ffmpeg', ['-nostdin', '-hide_banner', '-loglevel', 'error', '-y', '-ss', '1', '-i', work / 'input.mp4',
                   '-map', '0:v:0', '-map', '0:a:0?', '-c:v', 'libopenh264', '-b:v', '6M', '-pix_fmt', 'yuv420p',
                   '-level', '4.1', '-g', '48', '-keyint_min', '48', '-force_key_frames', 'expr:gte(t,0)',
                   '-c:a', 'aac', '-ac', '2', '-b:a', '128k', '-t', '1.5', '-output_ts_offset', '1', '-f', 'mpegts', clip])
    info = json.loads(run('ffprobe', ['-v', 'error', '-show_streams', '-show_format', '-of', 'json', clip]))
    assert next(stream for stream in info['streams'] if stream['codec_type'] == 'video')['codec_name'] == 'h264'
    audio = next(stream for stream in info['streams'] if stream['codec_type'] == 'audio')
    assert audio['codec_name'] == 'aac' and audio['channels'] == 2
    assert 1.2 < float(info['format']['duration']) < 2
    image = work / 'frame.rgb'
    run('ffmpeg', ['-v', 'error', '-y', '-i', work / 'input.mp4', '-frames:v', '1', '-an', '-pix_fmt', 'rgb24', '-f', 'rawvideo', image])
    assert image.stat().st_size == 160 * 96 * 3

    manifest = work / 'manifest.mpd'
    run('ffmpeg', ['-v', 'error', '-y', '-i', wav, '-c:a', 'aac', '-f', 'dash', '-seg_duration', '1',
                   '-use_template', '1', '-use_timeline', '1', manifest])
    playlist = work / 'playlist.m3u8'
    run('ffmpeg', ['-v', 'error', '-y', '-i', wav, '-c:a', 'aac', '-f', 'hls', '-hls_time', '1', playlist])
    cert, key = work / 'localhost.crt', work / 'localhost.key'
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-sha256', '-days', '1',
                    '-subj', '/CN=localhost', '-keyout', str(key), '-out', str(cert)], check=True, capture_output=True)

    class Handler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *args):
            pass

    handler = functools.partial(Handler, directory=str(work))
    servers = []
    cases = []
    try:
        for secure in [False, True]:
            server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
            if secure:
                context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                context.load_cert_chain(cert, key)
                server.socket = context.wrap_socket(server.socket, server_side=True)
            servers.append(server)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            port = server.server_address[1]
            if adb:
                subprocess.run(['adb', '-s', adb, 'reverse', f'tcp:{port}', f'tcp:{port}'], check=True, capture_output=True)
            scheme = 'https' if secure else 'http'
            for format_name, input_file in [('dash', manifest), ('hls', playlist)]:
                output = work / f'{format_name}-{scheme}.m4a'
                # This is a local transport smoke test using a self-signed test certificate.
                tls_args = ['-tls_verify', '0'] if secure else []
                run('ffmpeg', ['-v', 'error', '-y', '-protocol_whitelist', 'file,http,https,tcp,tls,crypto,data,httpproxy',
                               *tls_args, '-ss', '0.25', '-i', f'{scheme}://127.0.0.1:{port}/{input_file.name}',
                               '-t', '1.25', '-map', '0:a:0', '-vn', '-c:a', 'aac', '-b:a', '128k', '-ac', '2',
                               '-movflags', 'frag_keyframe+empty_moov+default_base_moof', '-f', 'mp4', output])
                assert output.read_bytes()[4:8] == b'ftyp'
                probe = json.loads(run('ffprobe', ['-v', 'error', '-show_streams', '-show_format', '-of', 'json', output]))
                assert probe['streams'][0]['codec_name'] == 'aac'
                assert probe['streams'][0]['channels'] == 2
                assert 1 < float(probe['format']['duration']) < 1.6
                cases.append(f'{format_name}-{scheme}')
    finally:
        for server in servers:
            if adb:
                subprocess.run(['adb', '-s', adb, 'reverse', '--remove', f'tcp:{server.server_address[1]}'], capture_output=True)
            server.shutdown()
            server.server_close()
    result = {'target': target, 'status': 'passed', 'binaryLicense': metadata['license'],
              'gpl': False, 'nonfree': False, 'checks': ['actual-binary-license', 'actual-binary-buildconf',
              'encoder-and-format-capabilities', 'h264-stereo-aac-segment', 'rawvideo-frame', *cases],
              'runtime': 'Android emulator' if adb else ('Wine' if wine else (
                  'QEMU user-mode Android executable' if qemu else 'native macOS/Linux')),
              'hardwareEncodeExecutionTested': False,
              'binarySha256': {name: hashlib.sha256(path.read_bytes()).hexdigest()
                               for name, path in executables.items()}}
    (evidence / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    metadata['validation'] = result
    (build / 'build-manifest.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print(json.dumps(result), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', required=True)
    parser.add_argument('--wine')
    parser.add_argument('--adb')
    parser.add_argument('--qemu')
    args = parser.parse_args()
    validate(args.target, args.wine, args.adb, args.qemu)
