"""Prepare native access cases and oracle results; execute JS only on the given host."""
import ctypes
import errno
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    native = ctypes.CDLL(None, use_errno=True).access
    native.argtypes = (ctypes.c_char_p, ctypes.c_int)
    native.restype = ctypes.c_int
    with tempfile.TemporaryDirectory(prefix="home-access-", dir="/tmp") as directory:
        root = Path(directory)
        for name, mode in (("plain.txt", 0o644), ("readonly", 0o444), ("executable", 0o755), ("denied", 0), ("space 🟢.txt", 0o600)):
            path = root / name
            path.write_text("actual bytes", encoding="utf-8")
            path.chmod(mode)
        for name, target in (("file-link", "plain.txt"), ("broken-link", "missing"), ("loop-a", "loop-b"), ("loop-b", "loop-a")):
            (root / name).symlink_to(target)
        paths = [directory] + [str(root / name) for name in ("plain.txt", "readonly", "executable", "denied", "space 🟢.txt", "file-link", "broken-link", "loop-a", "missing", "plain.txt/child")] + ["", str(root / "plain.txt") + "/"]
        cases = []
        for path in paths:
            for mode in range(8):
                result = native(os.fsencode(path), mode)
                code = None if result == 0 else errno.errorcode[ctypes.get_errno()]
                cases.append([path, mode, code])
        # os.access cannot distinguish failure errno; libc supplies an actual
        # permission/existence oracle even when CI runs with elevated privileges.
        return subprocess.call([sys.argv[1], "run", sys.argv[2], directory, json.dumps(cases, ensure_ascii=False)])


if __name__ == "__main__":
    sys.exit(main())
