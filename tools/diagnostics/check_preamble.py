"""Extract cgo preambles from the generated Go files and syntax-check them with
the NDK clang, the same class of error the release build keeps catching."""
import re
import subprocess
import sys
from pathlib import Path

PATCH = Path('buildScript/core-patch/core/mobile')
CLANG = 'C:/Users/ljlgg/AppData/Local/Android/Sdk/ndk/27.0.12077973/toolchains/llvm/prebuilt/windows-x86_64/bin/clang.exe'
TMP = Path('build/preamble_check')
TMP.mkdir(parents=True, exist_ok=True)

ok = True
for go_file in sorted(PATCH.glob('*.go')):
    src = go_file.read_text(encoding='utf-8')
    # the cgo preamble is the first /* ... */ block after the package clause
    m = re.search(r'package mobile\s*\n\n/\*(.*?)\*/', src, re.S)
    if not m:
        print(f'{go_file.name}: no cgo preamble, skip')
        continue
    c_body = re.sub(r"^\s*#cgo.*$", "", m.group(1), flags=re.M)
    out_c = TMP / (go_file.stem + '_preamble.c')
    out_c.write_text(c_body, encoding='utf-8')
    cmd = [CLANG, '-fsyntax-only', '-I', str(PATCH), '-I', str(PATCH / 'dartbridge' / 'include'),
           '--target=aarch64-linux-android21', '-std=c11', str(out_c)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    status = 'OK' if r.returncode == 0 else 'FAIL'
    if r.returncode != 0:
        ok = False
    print(f'{go_file.name}: {status}')
    if r.returncode != 0:
        for line in (r.stderr or '').splitlines():
            if 'error' in line:
                print('   ', line)

sys.exit(0 if ok else 1)
