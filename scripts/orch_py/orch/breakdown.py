"""The breakdown concept's module (scripts/orch/breakdown.sh), kept to what
the ticket module's retire reaches so far: where a spec issue's breakdown save
point lives, copied from bash's breakdown_dir. The bash copy stays while a
bash caller remains (ADR-0067).
"""
from __future__ import annotations

from orch.common import ORCH_DIR_NAME


def breakdown_dir(root: str, n: str) -> str:
    """Spec issue <n>'s breakdown save point under the checkout at <root>."""
    return "%s/%s/breakdown/%s" % (root, ORCH_DIR_NAME, n)
