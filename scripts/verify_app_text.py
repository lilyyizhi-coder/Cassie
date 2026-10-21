"""Check representative Chinese UI and permission strings in an archive."""
from pathlib import Path
import plistlib
import sys


def main():
    app = Path(sys.argv[1])
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    executable = (app / info['CFBundleExecutable']).read_bytes()
    expected = [
        '\u628a\u65e5\u5e38\u5c0f\u4e8b\u4ea4\u7ed9\u6211',
        '\u6309\u4e0b\u5f00\u59cb\u8bf4\u8bdd',
        '\u5e38\u7528\u529f\u80fd',
    ]
    for text in expected:
        if text.encode('utf-8') not in executable:
            raise ValueError('Expected Chinese UI string missing: ' + ascii(text))
    for key in ['NSPhotoLibraryUsageDescription', 'NSMicrophoneUsageDescription',
                'NSSpeechRecognitionUsageDescription', 'NSCalendarsFullAccessUsageDescription']:
        text = info.get(key, '')
        if not text or '\ufffd' in text or not any('\u4e00' <= char <= '\u9fff' for char in text):
            raise ValueError('Missing or damaged Chinese permission description: ' + key)
    if info.get('CFBundleShortVersionString') != '0.1.1':
        raise ValueError('Unexpected version: ' + str(info.get('CFBundleShortVersionString')))
    print('PASS: Chinese UI strings and four Chinese permission descriptions in app version 0.1.1.')


if __name__ == '__main__':
    main()
