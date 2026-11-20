"""orch.sh's core, the nouns converted from bash (ADR-0067).

`orch.sh` stays the one entry point and hands a converted noun to
`python3 -m orch <noun> <verb> ...`. Standard library only at runtime,
Python 3.9 or newer: `from __future__ import annotations`, no `match`.
"""
