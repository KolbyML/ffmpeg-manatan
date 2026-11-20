#!/usr/bin/env python3
"""Verify archive layouts, target architectures and recorded binary checksums."""
import hashlib
import json
from pathlib import Path
import struct
import zipfile

ROOT = Path(__file__).resolve().parents[1]
DIST = ROOT / 'dist/non-gpl-candidate'
EXPECTED = {
    'ffmpeg-macos.zip': [('macos-arm64', 'arm64'), ('macos-x86_64', 'x86_64')],
    'ffmpeg-linux-static.zip': [('linux-x86_64', 'ffmpeg-linux-static')],
    'ffmpeg-win-static.zip': [('windows-x86_64', 'ffmpeg-win-static')],
    'ffmpeg-android.zip': [('android-arm64-v8a', 'ffmpeg-android/arm64-v8a'),
                           ('android-armeabi-v7a', 'ffmpeg-android/armeabi-v7a')],
}


def architecture(data, target):
    if target.startswith('macos-'):
        assert data[:4] == b'\xcf\xfa\xed\xfe'
        cpu = struct.unpack_from('<I', data, 4)[0]
        assert cpu == (0x100000c if target.endswith('arm64') else 0x1000007)
    elif target.startswith('windows-'):
        assert data[:2] == b'MZ'
        offset = struct.unpack_from('<I', data, 0x3c)[0]
        assert data[offset:offset+4] == b'PE\0\0'
        assert struct.unpack_from('<H', data, offset + 4)[0] == 0x8664
    else:
        assert data[:4] == b'\x7fELF' and data[5] == 1
        expected = 183 if target == 'android-arm64-v8a' else (40 if target == 'android-armeabi-v7a' else 62)
        assert struct.unpack_from('<H', data, 18)[0] == expected
        assert data[4] == (1 if expected == 40 else 2)
        if target.startswith('android-'):
            # These are standalone static executables with 16 KB-compatible loads.
            assert struct.unpack_from('<H', data, 16)[0] == 2
            if data[4] == 2:
                start = struct.unpack_from('<Q', data, 32)[0]
                size, count = struct.unpack_from('<HH', data, 54)
            else:
                start = struct.unpack_from('<I', data, 28)[0]
                size, count = struct.unpack_from('<HH', data, 42)
            for i in range(count):
                offset = start + i * size
                ptype = struct.unpack_from('<I', data, offset)[0]
                assert ptype != 3, 'Unexpected dynamic interpreter in Android archive'
                if ptype == 1:
                    alignment = struct.unpack_from('<Q' if data[4] == 2 else '<I', data, offset + (48 if data[4] == 2 else 28))[0]
                    assert alignment >= 16384


def inspect():
    results = []
    for archive_name, members in EXPECTED.items():
        with zipfile.ZipFile(DIST / archive_name) as archive:
            assert archive.testzip() is None
            for target, prefix in members:
                metadata = json.loads(archive.read(prefix + '/build-manifest.json'))
                validation = metadata['validation']
                assert metadata['target'] == target and validation['status'] == 'passed'
                assert metadata['gpl'] is False and metadata['nonfree'] is False
                config = archive.read(prefix + '/config.h').decode()
                assert '#define CONFIG_GPL 0' in config and '#define CONFIG_NONFREE 0' in config
                for required_notice in ['openh264-LICENSE', 'libxml2-Copyright']:
                    assert prefix + '/licenses/' + required_notice in archive.namelist()
                if target.startswith('windows-'):
                    assert prefix + '/licenses/nvcodec-header-NOTICES.txt' in archive.namelist()
                for name in ['ffmpeg', 'ffprobe']:
                    suffix = '.exe' if target.startswith('windows-') else ''
                    data = archive.read(prefix + '/bin/' + name + suffix)
                    assert hashlib.sha256(data).hexdigest() == validation['binarySha256'][name]
                    architecture(data, target)
                results.append({'target': target, 'archive': archive_name,
                                'archivePrefix': prefix, 'license': metadata['license'],
                                'validation': validation})
    summary = {'status': 'passed',
               'archives': results, 'hardwareEncodeExecutionTested': False}
    (DIST / 'validation-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    (DIST / 'SHA256SUMS').write_text(''.join(
        hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + path.name + '\n'
        for path in sorted(DIST.iterdir()) if path.is_file() and path.name != 'SHA256SUMS'))
    print(json.dumps({'status': 'passed', 'targets': len(results), 'archiveLayoutsAndArchitectures': 'verified'}))


if __name__ == '__main__':
    inspect()
