# The in-memory half of the ORCH_GH_ADAPTER seam.
#
# Sourced into orch.sh's own process via ORCH_GH_ADAPTER, this redefines the
# adapter functions orch.sh calls instead of shelling out to `gh` - so a test
# exercises orch.sh's decision logic without spawning a subprocess for every
# GitHub call. Parameterized by the same GH_STUB_* vocabulary orch_test.sh's
# subprocess fake (`stub_gh`) already answers to, so a test switches between
# the two fakes without learning a second vocabulary, and an assertion written
# against one reads the other's output too.
#
# Label creation is the only primitive covered so far - the narrowest slice
# that proves the seam works end to end (issue #91, first of the #78
# breakdown). Later tickets extend this file as more gh call sites move
# behind adapter functions; each addition should keep mirroring whatever
# GH_STUB_* variable already drives that call's subprocess behaviour in
# stub_gh, rather than inventing a parallel vocabulary.
#
# adapter_label_create - mirrors stub_gh's `label create` branch:
#   GH_STUB_MODE=labelfail   fails the call, like a `gh` that cannot create it
#   GH_STUB_FILED            when set, appended with "label create <args...>",
#                             the same line shape stub_gh writes, so an
#                             assertion against GH_STUB_FILED does not care
#                             which fake produced it
adapter_label_create() {
  if [ "${GH_STUB_MODE:-ok}" = labelfail ]; then return 1; fi
  if [ -n "${GH_STUB_FILED:-}" ]; then printf 'label create %s\n' "$*" >>"$GH_STUB_FILED"; fi
  return 0
}
