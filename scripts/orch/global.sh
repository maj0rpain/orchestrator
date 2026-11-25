# shellcheck shell=bash
# global.sh - once orch.sh's bare global commands with no module of their own.
# slug, status, archive and help are converted nouns now (orch/slug.py,
# orch/status.py, orch/archive.py, orch/help.py), so it defines nothing. Its
# test file, scripts/test/orch/global.sh, holds the sections about orch.sh
# itself. Sourced by orch.sh, after common.sh and the ROOT block.
