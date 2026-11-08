"""Prepare actual inherited descriptors and inspect resulting native file bytes."""
import errno
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    with tempfile.TemporaryDirectory(prefix="home-descriptors-", dir="/tmp") as directory:
        root = Path(directory)
        (root / "seed").write_text("seed", encoding="utf-8")
        borrowed = os.open(root / "borrowed", os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        reader, broken = os.pipe()
        os.close(reader)
        try:
            os.write(borrowed, b"parent:")
            try:
                os.fsync(broken)
            except OSError as error:
                sync_code = errno.errorcode[error.errno]
            else:
                raise AssertionError("pipe unexpectedly supports fsync")
            result = subprocess.run([sys.argv[1], "run", sys.argv[2], directory, str(borrowed), str(broken), sync_code], pass_fds=(borrowed, broken), text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            if result.returncode:
                print(result.stdout, end="")
                return result.returncode
            if result.stdout != "OK actual descriptor writes, append, fsync, close and OS failures\n":
                raise AssertionError("missing actual JS witness: " + result.stdout)
            expected = {"sequence": b"A\x00\xf0\x9f\x9f\xa2\x00\x80\xffZ", "append": b"first:second:third", "seed": b"seed", "exclusive": b"once", "borrowed": b"parent:child", "path-append": b"first:second", "data-view": b"\x00\x80\xff"}
            for name, data in expected.items():
                if (root / name).read_bytes() != data:
                    raise AssertionError("actual bytes differ: " + name)
            # A child close must not close the parent's independently inherited FD.
            os.write(borrowed, b":parent-alive")
            if (root / "borrowed").read_bytes() != b"parent:child:parent-alive":
                raise AssertionError("borrowed descriptor state differs")
        finally:
            os.close(borrowed)
            os.close(broken)
    print("OK native descriptors, exact bytes, kernel append, inherited handles and syscall errors")
    return 0


if __name__ == "__main__":
    sys.exit(main())
