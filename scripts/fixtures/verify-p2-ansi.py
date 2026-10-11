import os
import pathlib
import subprocess
import sys

script = pathlib.Path(sys.argv[1]) / "scripts/strip-ansi.pl"
for opener in b"PX^_":
    payload = b"A\x1b" + bytes([opener]) + b"hidden\nmore\x1b\\B"
    for size in range(1, len(payload) + 1):
        result = subprocess.run(["perl", str(script)], input=payload, capture_output=True,
                                env={**os.environ, "WASPFLOW_STRIP_ANSI_CHUNK_SIZE": str(size)}, check=True)
        assert result.stdout == b"AB", (opener, size, result.stdout)
