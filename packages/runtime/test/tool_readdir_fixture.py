"""Prepare real OS directory nodes, then run the JS witness on the given host."""
from pathlib import Path
import os
import socket
import subprocess
import sys
import tempfile


def main():
    # Keep AF_UNIX's path below the platform limit regardless of build-cache path.
    with tempfile.TemporaryDirectory(prefix="home-readdir-", dir="/tmp") as directory:
        root = Path(directory)
        (root / "nested").mkdir()
        (root / "nested/child.txt").write_text("actual child", encoding="utf-8")
        (root / "plain.txt").write_text("actual file", encoding="utf-8")
        (root / "space 🟢.txt").write_text("actual Unicode", encoding="utf-8")
        for name, target in (("file-link", "plain.txt"), ("directory-link", "nested"), ("broken-link", "missing")):
            (root / name).symlink_to(target)
        os.mkfifo(root / "fifo")
        with socket.socket(socket.AF_UNIX) as endpoint:
            endpoint.bind(str(root / "socket"))
        # Python only creates native fixture nodes; JS always executes on the
        # passed Home artifact. No reference runtime or emulated listing.
        return subprocess.call([sys.argv[1], "run", sys.argv[2], directory])


if __name__ == "__main__":
    sys.exit(main())
