# Reviewers filter known items after a blind review

Amends ADR-0018: a reviewer's prompt carries a sixth variable, `Known
items: <path>`. Amends ADR-0002: the Spec reviewer now sees the deviations; a
recorded deviation still outranks it. Amends ADR-0029: a review pass's reviewers
are told the pass's known items.

Every reviewer prompt used to carry nothing about earlier iterations, so each
look was independent. The cost was re-raising: in #1120's loop about eight
findings recurred across three to five iterations, each already waiting to be
filed or covered by a deviation, and each triaged again by the same driver to
the same outcome. The second opinion blindness promised never arrived, because
the same rule ruled it each time. Blindness also cost the deviations their
review: a reviewer that cannot see a deviation cannot check what was built in
its place.

A reviewer now reviews the diff blind, as before, and opens the known items only
when writing its report. It drops each finding that a known item already
carries - same file, same claim, or the same claim alone for an item with no
location - and re-raises one only when its location or cause has changed, marked
as re-raised. It reports how many it held back. The Spec reviewer reads the
deviations before its review, as things to verify. The driver's own filters -
demotion, met again, a pass's earlier declines - stay as the backstop.

## Considered Options

- **Keep the reviewers blind and make the driver's matching cheaper.** Rejected:
  the waste is the reviewers' repeated output, and deviations would stay
  unverified.
- **Give the reviewers the known items before they review.** Rejected: a
  reviewer told a region is known reads past it, and misses a different defect
  beside the known one. The deviations are the one exception: the Spec reviewer
  reads them first, because verifying what was built in their place is the
  point.
