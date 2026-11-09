"""Own a temporary directory; the supplied Home host performs every file read/write."""
import subprocess
import sys
import tempfile


def main():
    with tempfile.TemporaryDirectory(prefix="home-read-buffer-", dir="/tmp") as root:
        return subprocess.call([sys.argv[1], "run", sys.argv[2], root])


if __name__ == "__main__":
    sys.exit(main())
