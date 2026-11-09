"""Prepare real metadata and errno oracles; execute JS on the supplied Home host."""
from contextlib import contextmanager
import errno
import json
import os
from pathlib import Path
import socket
import stat
import subprocess
import sys
import tempfile


@contextmanager
def prepared_cases():
    with tempfile.TemporaryDirectory(prefix="home-stat-", dir="/tmp") as directory:
        root = Path(directory)
        (root / "nested").mkdir()
        (root / "plain").write_bytes(b"actual\x00bytes")
        (root / "space 🟢.txt").write_text("native Unicode", encoding="utf-8")
        for name, target in (("file-link", "plain"), ("directory-link", "nested"),
                             ("broken-link", "missing"), ("loop-a", "loop-b"), ("loop-b", "loop-a")):
            (root / name).symlink_to(target)
        os.mkfifo(root / "fifo")
        with socket.socket(socket.AF_UNIX) as endpoint:
            endpoint.bind(str(root / "socket"))
            paths = [directory, "/dev/null", ""] + [str(root / name) for name in (
                "plain", "nested", "space 🟢.txt", "file-link", "directory-link", "broken-link",
                "loop-a", "missing", "plain/child", "plain/", "fifo", "socket")]
            cases = []
            for path in paths:
                for follow in (True, False):
                    try:
                        info = os.stat(path, follow_symlinks=follow)
                        kinds = ((stat.S_ISREG, "file"), (stat.S_ISDIR, "directory"),
                                 (stat.S_ISLNK, "sym_link"), (stat.S_ISBLK, "block_device"),
                                 (stat.S_ISCHR, "character_device"), (stat.S_ISFIFO, "named_pipe"),
                                 (stat.S_ISSOCK, "unix_domain_socket"))
                        expected = {"kind": next(kind for predicate, kind in kinds if predicate(info.st_mode)),
                                    "size": info.st_size, "ino": info.st_ino, "nlink": info.st_nlink,
                                    "mtimeMs": info.st_mtime_ns / 1_000_000,
                                    "ctimeMs": info.st_ctime_ns / 1_000_000}
                    except OSError as error:
                        expected = {"code": errno.errorcode[error.errno]}
                    cases.append([path, follow, expected])
            yield directory, cases


def main():
    with prepared_cases() as (directory, cases):
        return subprocess.call([sys.argv[1], "run", sys.argv[2], directory, json.dumps(cases, ensure_ascii=False)])


if __name__ == "__main__":
    sys.exit(main())
