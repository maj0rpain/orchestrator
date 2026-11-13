# shellcheck shell=bash
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# --- temporary failing section (#2822 gate evidence) -------------------------
echo
echo "temporary failing section"
bad "temporary failing section" "planted to show the gate; reverted next commit"
