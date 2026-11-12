"""Extract cgo preambles from the generated Go files and syntax-check them with
clang, the same class of error the release build keeps catching.

Portable across the dev box and CI: point CLANG at a compiler (NDK clang on
Android, the runner's clang elsewhere). Without one the check is skipped with a
notice so a missing toolchain never hides a real compile error.
"""
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "buildScript" / "core-patch" / "core" / "mobile"
TMP = ROOT / "build" / "preamble_check"
WINDOWS_NDK_CLANG = (
    "C:/Users/ljlgg/AppData/Local/Android/Sdk/ndk/27.0.12077973/"
    "toolchains/llvm/prebuilt/windows-x86_64/bin/clang.exe"
)


def find_clang() -> str | None:
    for candidate in (os.environ.get("CLANG"), shutil.which("clang"), WINDOWS_NDK_CLANG):
        if candidate and Path(candidate).exists():
            return candidate
    return None


def main() -> int:
    clang = find_clang()
    if clang is None:
        print("notice: no clang available; skipping the cgo preamble check")
        return 0

    # An NDK clang needs an Android target; a host clang must not be given one
    # (it has no matching sysroot).
    target = ["--target=aarch64-linux-android21"] if "ndk" in clang.lower() else []
    TMP.mkdir(parents=True, exist_ok=True)
    ok = True
    for go_file in sorted(PATCH.glob("*.go")):
        src = go_file.read_text(encoding="utf-8")
        # the cgo preamble is the first /* ... */ block after the package clause
        m = re.search(r"package mobile\s*\n\n/\*(.*?)\*/", src, re.S)
        if not m:
            print(f"{go_file.name}: no cgo preamble, skip")
            continue
        c_body = re.sub(r"^\s*#cgo.*$", "", m.group(1), flags=re.M)
        out_c = TMP / (go_file.stem + "_preamble.c")
        out_c.write_bytes(c_body.encode("utf-8"))
        cmd = [clang, "-fsyntax-only", "-I", str(PATCH),
               "-I", str(PATCH / "dartbridge" / "include"),
               *target, "-std=c11", "-Werror", str(out_c)]
        r = subprocess.run(cmd, capture_output=True, text=True)
        print(f"{go_file.name}: {'OK' if r.returncode == 0 else 'FAIL'}")
        if r.returncode != 0:
            ok = False
            for line in (r.stderr or "").splitlines():
                if "error" in line:
                    print("   ", line)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
