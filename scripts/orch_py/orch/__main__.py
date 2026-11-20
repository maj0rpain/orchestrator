"""`python3 -m orch <noun> <verb> ...`: runs orch.cli's main."""
from __future__ import annotations

import sys

from orch.cli import main

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
