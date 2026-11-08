"""Verify actual on-disk creation modes under inherited native umasks."""
from pathlib import Path
import os
import stat
import subprocess
import sys
import tempfile


def main():
    for mask in (0o027, 0o077):
        with tempfile.TemporaryDirectory(prefix="home-modes-", dir="/tmp") as directory:
            root = Path(directory)
            (root / "existing.txt").write_text("original", encoding="utf-8")
            (root / "existing.txt").chmod(0o640)
            (root / "existing-dir").mkdir(mode=0o750)
            (root / "existing-dir").chmod(0o750)
            (root / "link").symlink_to("existing.txt")
            previous = os.umask(mask)
            try:
                result = subprocess.run([sys.argv[1], "run", sys.argv[2], directory], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            finally:
                os.umask(previous)
            if result.returncode:
                print(result.stdout, end="")
                return result.returncode
            if result.stdout != "OK actual creation and invalid-mode checks\n":
                raise AssertionError("missing JS execution witness: " + result.stdout)
            expected = {"private": 0o600, "octal": 0o640, "logger": 0o644, "executable": 0o777, "default": 0o666, "null": 0o666, "bytes": 0o640, "leaf": 0o750, "parents": 0o755, "parents/child": 0o755, "existing-dir/child": 0o700}
            for name, mode in expected.items():
                actual = stat.S_IMODE((root / name).stat().st_mode)
                if actual != mode & ~mask:
                    raise AssertionError(f"{name}: actual {actual:o}, expected {mode & ~mask:o}")
            for name, mode in (("existing.txt", 0o640), ("existing-dir", 0o750)):
                if stat.S_IMODE((root / name).stat().st_mode) != mode:
                    raise AssertionError("creation mode changed an existing node: " + name)
            if (root / "existing.txt").read_text() != "through link":
                raise AssertionError("write did not follow the real symlink")
            if (root / "bytes").read_bytes() != b"\x00\x80\xff":
                raise AssertionError("custom mode lost actual view bytes")
            if list(root.glob("invalid-*")):
                raise AssertionError("invalid modes caused filesystem side effects")
    print("OK native file/directory creation modes, umasks, existing nodes and invalid-mode rejection")
    return 0


if __name__ == "__main__":
    sys.exit(main())
