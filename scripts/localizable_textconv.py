#!/usr/bin/env python3
"""Convert .strings files to UTF-8 for git diff."""
from __future__ import annotations

import pathlib
import sys
from typing import Iterable

ENCODINGS: Iterable[str] = ("utf-8", "utf-16", "utf-16le", "utf-16be")

def read_input() -> bytes:
    if len(sys.argv) > 1:
        return pathlib.Path(sys.argv[1]).read_bytes()
    return sys.stdin.buffer.read()

def main() -> int:
    data = read_input()
    for encoding in ENCODINGS:
        try:
            text = data.decode(encoding)
            break
        except UnicodeDecodeError:
            continue
    else:
        text = data.decode("latin-1", "ignore")
    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
