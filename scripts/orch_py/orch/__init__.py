"""orch.sh's core, the nouns converted from bash (ADR-0067).

`orch.sh` stays the one entry point and runs a converted noun as
`python3 -m orch <noun> <verb> ...` would, through a `-c` bootstrap. Standard
library only at runtime, Python 3.9 or newer: `from __future__ import
annotations`, no `match` - all but the entry point, __main__.py, which every
python3 compiles, and this file.
"""
