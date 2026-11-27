# shellcheck shell=bash
# filed-finding.sh - the Filed finding module: a concept module with no orch.sh
# noun of its own, holding what the bash side still asks of a filed finding -
# whether an issue's labels mark one, and whether finding triage has yet to
# triage it - for autopilot's untriaged-finding gate, its one caller. The
# converted nouns keep their own copy of the rest - a filed finding's
# severities, labels, categories and issue body, and the filing checks
# (orch/filed_finding.py). Its tests: scripts/test/orch/filed-finding.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# review_labels <labels>: each label in the newline-separated list that marks
# a review finding - review: in any casing, followed by at least one character.
review_labels() {
  printf '%s\n' "$1" | grep -i '^review:.' || true
}

# has_review_label <labels>: whether any label marks a review finding, at any
# severity - filed today or not.
has_review_label() {
  [ -n "$(review_labels "$1")" ]
}

# finding_untriaged <labels>: whether the issue is a filed finding finding
# triage has not yet triaged - it carries a review label and none of
# ready-for-agent, ready-for-human or wontfix. The quick autopilot's
# candidates' gate; issue triage, a converted noun's verb, keeps its own copy
# (orch/filed_finding.py).
finding_untriaged() {
  local role label
  has_review_label "$1" || return 1
  for role in ready-for-agent ready-for-human wontfix; do
    triage_label_into label "$role"
    ! label_listed "$1" "$label" || return 1
  done
}
