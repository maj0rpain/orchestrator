# shellcheck shell=bash
# global.sh - orch.sh's nouns with no module of their own: slug, status,
# archive and help. Its tests: scripts/test/orch/global.sh, save status's,
# which live in scripts/test/orch/side-checkout.sh; help has none of its own.
# Sourced by orch.sh, after common.sh and the ROOT block.

cmd_slug() {
  local raw="${1:-}" slug
  [ -n "$raw" ] || die "usage: orch.sh slug <text>"
  slug="$(normalize_slug "$raw")"
  note "$slug"
}

# --- lifecycle --------------------------------------------------------------

cmd_status() {
  if [ ! -f "$STATE" ]; then
    note "No active flow. Run $(flow_cmd start) from an approved plan."
  else
    status_flow
  fi
  status_others
}

# Lists every other checkout holding a flow, and every side checkout without
# one - the main checkout's flow included when run from a side checkout -
# under a heading of its own. Ticket worktrees, a hand-made worktree with no
# flow and a quick implementation in the main checkout hold no flow and carry
# no marker, so they never appear; with nothing to list, nothing is printed.
status_others() {
  local path lines=""
  while IFS= read -r path; do
    [ "$path" != "$ROOT" ] || continue
    checkout_has_flow "$path" || is_side_checkout "$path" || continue
    lines+="  $path $(checkout_holding "$path")"$'\n'
  done < <(checkout_paths)
  [ -n "$lines" ] || return 0
  note ""
  note "other checkouts:"
  printf '%s' "$lines"
}

# Full detail on the current checkout's flow.
status_flow() {
  local slug phase issue branch pr iteration redo_count
  slug="$(state_get slug)";       phase="$(state_get phase)"
  issue="$(state_get issue)";     branch="$(state_get branch)"
  pr="$(state_get pr)";           iteration="$(state_get iteration)"
  redo_count="$(state_get redo_count)"
  issue="${issue:--}";            branch="${branch:--}";  pr="${pr:--}"
  note "flow:      $slug"
  note "phase:     $phase"
  note "issue:     $issue"
  note "base:      $(flow_base)"
  note "branch:    $branch"
  note "PR:        $pr"
  # Against the budget, not alone: "iteration 3" does not say how far along
  # the loop is, and the budget is the one number a human chose.
  note "review:    iteration $iteration of $(review_budget)"
  # Unconditional, like every other line here: a flow that has never been
  # redone still has an answer - 0 - rather than a line that only appears once
  # something has happened.
  note "redo:      $redo_count"
  note ""
  note "handoffs:"
  local f
  for f in "$HANDOFF_DIR"/*.md; do
    [ -e "$f" ] || { note "  (none yet)"; break; }
    note "  ${f#"$ROOT"/}"
  done
}

# Archive rather than delete: the moment you want a handoff back is precisely
# the moment you just threw it away. The directory is git-excluded anyway.
# In a side checkout, git worktree remove would delete the archive with the
# worktree - it deletes ignored files - so the flow moves to the main
# checkout's archive first, and only then is the worktree removed (ADR-0037).
cmd_archive() {
  require_state
  archive_flow "$ROOT"
  if is_side_checkout "$ROOT"; then side_checkout_remove_after_archive "$ROOT"; fi
}

# Removes the side checkout at <path> once its flow is archived, never with
# force. A dirty worktree is reported and kept: the archive has still
# succeeded. When this command ran inside the removed worktree, the session
# working there is told to close.
side_checkout_remove_after_archive() {
  local path="$1" err here
  # Read before the removal: once the worktree is gone, so is this directory.
  here="$(pwd -P)"
  if ! err="$(git -C "$(main_checkout)" worktree remove "$path" 2>&1)"; then
    warn "kept side checkout $path - it was not removed: $(first_line "$err")
     Commit or discard its changes, then run orch.sh side-checkout remove $(basename "$path")."
    return 0
  fi
  note "removed side checkout $path"
  side_checkout_close_note "$path" "$here"
}

cmd_help() {
  cat <<'USAGE'
orch.sh - deterministic operations for the orchestrator flow

  doctor [--env|--flow]       diagnose the machine, the repo, and the active flow
  default-branch [--sha]      resolve the repo's default branch, as GitHub
                              reports it; --sha prints the default SHA instead,
                              origin/<default>'s tip as it stands, unfetched
  base set <branch>           set this checkout's base branch - the branch
                              flows and quick implementations fork from and
                              open PRs against; refuses a branch origin does
                              not have. Shared by every worktree, never
                              committed; the default branch's name clears it.
                              An active flow keeps the base it started with
  base set <branch> --flow    correct the active flow's own base branch
                              instead, leaving the checkout setting alone;
                              only while the flow has no branch (before
                              branch create, or after redo review). Stores
                              the name as given; refuses a name that is not
                              a valid branch or that origin does not have
  base show                   print the base branch in effect and its source:
                              set, or default
  base clear                  remove the setting, falling back to the default
                              branch; succeeds when nothing was set
  parallel show               print the parallel cap, how many ticket
                              subagents a frontier runs at once: git config
                              orchestrator.parallel, else 3; 1 is sequential.
                              Dies naming the key and value when it is not a
                              positive integer
  repo show [--name|--host]   print the GitHub repo orch.sh works on and its
                              source: GH_REPO when set, else the checkout's
                              origin - never gh's default repo. --name prints
                              the bare [HOST/]OWNER/REPO alone, for gh -R;
                              --host its host alone, github.com for an
                              OWNER/REPO repo, for gh api --hostname.
                              Exits 1, naming GH_REPO, when neither resolves
  init <slug> [--issue N]     start a flow (refuses with exit 3 if one is
                              active, unless it is done - a done flow is archived, unless a
                              ticket worktree is left, and the
                              new one starts over it, or if the working tree
                              has changes outside the planning allowlist);
                              --issue adopts an already-open,
                              ready-for-agent issue N as the flow's spec
                              instead of leaving it unset. Records the base
                              branch in effect as the flow's own
  slug <text>                 normalise text to the kebab-case slug init would
                              store - lowercase, non-alphanumeric runs collapsed
                              to a hyphen, trimmed
  state get [key]             print state.json, or one key
  state set <key> <value>     update one of issue, budget, flake_rerun_used
                              (all digits store a number). Any other key is
                              refused, naming the command that owns it -
                              phase moves only through phase advance,
                              review ready, and redo
  phase advance               leave the current phase: validate the handoff
                              it writes for the next one (02-spec.md from
                              spec, 03-implement.md from implement) and the
                              state the next one needs (issue; branch,
                              base_sha, pr), then record the next phase and
                              print the boundary. On a FAIL the phase stays.
                              Refuses at review (use review ready) and done
  phase boundary              print the block that ends a phase - the
                              handoff the current phase reads, and the
                              host's Next line
  handoff path <phase>        print the handoff path for a phase
  handoff validate <file>     check required sections exist and are non-empty
  handoff section <file> <heading>
                              print the body of the section headed
                              `## <heading>`, blank lines trimmed; a missing
                              file, a missing heading, or a repeated heading
                              is an error
  branch create               create orch/<issue>-<slug> off the flow's base
                              branch, recorded at init, recording that base
                              and its tip as the base SHA in state and in
                              the branch's git config, as branch off does
  branch off <name>           create and check out <name> off the base branch
                              in effect, recording that base on the branch
                              (branch.<name>.orchestrator-base in local git
                              config) and its tip at branching as the base
                              SHA (branch.<name>.orchestrator-base-sha), and
                              no state - for a quick implementation, which
                              keeps none. Refuses with exit 3, as init does,
                              while a flow is mid-pipeline
  branch base-sha             print the current branch's base SHA as branch
                              off, branch create or branch sync recorded it;
                              a branch without one falls
                              back to the merge-base with its recorded base
                              branch (else the base branch in effect), on
                              origin if there, else local
  branch sync                 merge origin's tip of the current plugin-made
                              branch's base into it (never a rebase, never
                              the local base), record that tip as its base
                              SHA (branch config, and state when this
                              checkout's flow holds it), and push when it
                              has an upstream. Exit 3 on a conflict, the
                              merge left in progress; exit 1 on a dirty
                              tree, failed fetch, detached HEAD, a merge
                              already in progress, a branch that is its own
                              base, or a branch the plugin did not make,
                              nothing moved; exit
                              1 on a failed push, the merge recorded - rerun
                              to push
  branch retire <old> <new>   rename <old> aside to <new>, republishing it on
                              origin and deleting the old remote ref, without
                              force-pushing over anything
  issue publish <title> <body-file>
                              create a GitHub issue under ready-for-agent
                              and verify its title and label by reading them
                              back - recording no state; prints the number
  issue fetch <n> <file> [--json]
                              write issue <n>'s body to <file>, recording no
                              state; with --json, the issue as one JSON
                              object {number, title, body, labels: [<name>],
                              comments: [{author, createdAt, body}]}
  issue update <n> <file>     replace issue <n>'s body with <file>, recording
                              no state
  issue comment <n> <file>    post <file> as a comment on issue <n>,
                              recording no state
  issue comments <n> <file>   write every comment on issue <n> to <file>, in
                              order, each opened by a line
                              <!-- comment @<login> <createdAt> --> - recording
                              no state; no comments is an empty file
  issue triage <n> [--override]
                              move open issue <n> to ready-for-agent, removing
                              its other triage labels, verify by reading the
                              labels back, and post one comment saying so -
                              recording no state. Exit 0 when moved, or when
                              it already carries ready-for-agent (nothing
                              changed); exit 2, printing the label, on
                              wontfix or ready-for-human without --override;
                              exit 1 on a closed issue, a filed finding not yet
                              triaged (finding triage moves those) or a gh
                              failure.
                              A failed comment only warns
  issue ready <n>             exit 0 when issue <n> carries the repo's
                              ready-for-agent label, 1 when it does not, 2 on
                              a usage error or a gh failure - recording no
                              state
  pr open <title> <body-file> push and open a draft PR against the flow's base
                              branch - Closes its issue into the default
                              branch, Refs it into any other
  pr publish <issue> <title> <body-file>
                              push the current branch and open a non-draft PR
                              against the base branch branch off recorded for
                              it (else the base branch in effect) - Closes
                              <issue> into the default branch, Refs it into any
                              other - recording no state; prints the PR number
                              - for a quick implementation whose review pass
                              already ran
  pr release [--force] <title> <body-file>
                              open the release PR: a non-draft PR from the
                              base branch in effect into the default branch,
                              its body one Closes line per still-open issue
                              any PR merged into the base branch refers to
                              (Refs/Closes/Fixes/Resolves #N), then
                              <body-file>. Refuses on the default branch,
                              while a release PR is already open (printing
                              it), and with nothing to close unless --force;
                              pushes nothing, records no state; prints the
                              PR number
  pr comment <file>           post <file> as a comment on the current
                              branch's open PR, recording no state; prints
                              the PR number. Exits 1 printing nothing when
                              the branch has no open PR, 2 when GitHub
                              cannot be read, the post fails, or the call
                              is wrong (no file, detached HEAD)
  pr comments <file>          write every comment on the current branch's
                              open PR to <file>, as issue comments does -
                              recording no state; no comments is an empty
                              file. Exits 1 writing nothing when the branch
                              has no open PR, 2 when GitHub cannot be read
                              or the call is wrong
  pr fetch <file>             write the current branch's open PR body to
                              <file>, recording no state
  pr update <file>            replace the current branch's open PR body with
                              <file>, recording no state. Refuses, leaving
                              the body unchanged, unless <file> opens with
                              the PR's existing Closes/Refs #<issue> line
  ticket publish <parent> <title> <body-file> [--blocked-by N,N,...]
                              create a ticket, link it as a sub-issue of
                              <parent>, add a blocking edge for every
                              --blocked-by issue, apply ready-for-agent, and
                              verify the links it just wrote by reading them
                              back - recording no state; prints the number
  ticket next <parent>       print <parent>'s open sub-issues with zero open
                              blockers, in the order they were published
  ticket list <parent>       print every sub-issue of <parent>, open or
                              closed, as <n> open|closed, in the order they
                              were published
  ticket close <n>           close ticket <n>
  ticket reset <parent>      reopen every sub-issue of <parent> that is
                              currently closed, and only those
  ticket parent <n>          print <n>'s parent issue number, or nothing
                              when <n> is not a sub-issue
  ticket exists <parent>      whether <parent> already has a ticket
                              breakdown: prints sub-issues (it has any, open
                              or closed) or collapsed (none, but its body has
                              a line that is exactly `## Ticket` outside a
                              code fence); exits 1 printing nothing when
                              neither, 2 when GitHub cannot be read, on a
                              usage error, or when <parent> is not a plain
                              number
  ticket retire <parent>      retire <parent>'s ticket breakdown: close each
                              open sub-issue as not planned, comment on every
                              one, unlink it, and cut every `## Ticket`
                              section from the body; afterwards ticket exists
                              exits 1. A repeat changes nothing
  ticket block <n> --by N,N,...
                              add a blocking edge on open ticket <n> for every
                              --by sibling (a sub-issue of <n>'s parent; a
                              closed one is fine) it lacks, verify the edges
                              by reading them back, and rewrite <n>'s body's
                              `## Blocked by` section to match. A repeat
                              writes no edge; re-running a failed run
                              finishes it
  ticket unblock <n> --by N,N,...
                              remove the blocking edge on open ticket <n> for
                              every --by sibling it has, verify the rest by
                              reading them back, and rewrite <n>'s body's
                              `## Blocked by` section to match (`None (can
                              start immediately)` once none is left). A repeat
                              removes no edge; re-running a failed run
                              finishes it
  ticket merge <n>            land ticket <n>'s branch on the branch it was
                              forked from: rebase it onto that branch's tip
                              inside its ticket worktree, then fast-forward
                              that branch in whichever checkout has it - no
                              merge commit. Exits 1, changing nothing, when
                              the ticket worktree or that checkout is dirty,
                              or the branch is checked out nowhere; on a
                              rebase conflict aborts the rebase and exits 3,
                              both branches at their prior tips. A rebase
                              that fails any other way is aborted and exits
                              1, naming git's first line; an abort that fails
                              exits 1, leaving the worktree mid-rebase
  ticket-worktree add <n>     fork <current-branch>--t<n> from the current
                              branch's tip, record the forked-from branch on
                              it in local git config, check it out at
                              .orchestrator/worktrees/t<n> under this
                              checkout's top level, git-exclude .orchestrator/
                              in the clone's shared info/exclude, and print
                              the worktree's absolute path. Refuses when that
                              worktree or branch already exists; a failure
                              after the branch is made leaves nothing behind
  ticket-worktree list        print <n> <path> for each ticket worktree under
                              this checkout's .orchestrator/worktrees/ only;
                              nothing, exit 0, when there are none
  ticket-worktree remove <n> [--unmerged]
                              remove ticket <n>'s worktree and delete its
                              ticket branch, never with --force. Refuses a
                              dirty worktree and, without
                              --unmerged, a branch not merged into its
                              forked-from branch, before removing anything;
                              --unmerged first aborts a rebase in progress
                              there, then deletes a clean worktree's
                              unmerged branch
  side-checkout add <slug> [--issue N]
                              run side-checkout prune first (its report on
                              stderr; a failed sweep is reported and add
                              carries on), then fetch the base branch in
                              effect, add a worktree
                              on no branch at origin/<base> under the main
                              checkout's .orchestrator/checkouts/<slug>, mark
                              it as a side checkout, git-exclude .orchestrator/
                              in the clone's shared info/exclude, and print its
                              path. --issue N records N, a quick
                              implementation's issue, in the marker; without
                              it the marker is empty. Refuses a missing or
                              non-numeric --issue before the sweep, and a path
                              that already exists; a failed fetch or marker
                              write leaves no worktree
  side-checkout list          print <slug> <path> and then its flow
                              (flow <slug> <phase> #<issue>), its branch
                              (branch <name>), or (no branch), for each side
                              checkout of the clone - marked worktrees only -
                              followed by quick #<N> when it records an issue
  side-checkout issue         print the issue this side checkout records
                              (side-checkout add --issue); exits 1 in a
                              checkout that is no side checkout, or records
                              no plain issue number, and 2 on a usage error
  side-checkout remove <slug> remove side checkout <slug>, never with --force.
                              Refuses an unknown slug, a worktree without the
                              side-checkout marker, uncommitted changes or
                              untracked files, and a ticket worktree inside it,
                              before anything moves; then archives any flow
                              into the main checkout's .orchestrator/archive/
                              and removes the worktree, leaving its branch.
                              Exits 1, the archive standing, when the removal
                              still fails
  side-checkout prune         the finished sweep:
                              for each side checkout whose PR GitHub reports
                              merged into its base, its tree clean and any
                              flow at done, archive the flow into the main
                              checkout, remove the worktree (never --force)
                              and delete its branch with -D; archive the main
                              checkout's finished flow in place, its branch
                              left checked out. Reports every skip with its
                              reason, and a hand-made worktree holding a flow
                              as left alone. Removes nothing, exiting 1, when
                              GitHub cannot be read; exits 1 after a failed
                              step, which leaves that checkout as it stands
  review begin                claim the next iteration, refusing once the
                              flow's budget is spent (5 when none is set)
  review path [n]             record path, .orchestrator/review/iteration-NN.md,
                              creating the directory if it is not there yet
  review file <major|nit> <title> --axis <spec|standards> --body-file <file>
                              file a finding as a GitHub issue labelled
                              review:<severity>, the repo's needs-triage, and
                              bug (spec axis) or enhancement (standards axis),
                              creating the labels if missing; prints the number
  review ci                   classify the PR's checks: green, failing, none, or
                              unreachable; exits non-zero on the last two
  review rerun <pr>           rerun the failed jobs of the Actions run behind
                              the PR's first failed or cancelled check; prints
                              the run id. Exits 1 when that check is no Actions
                              run, 2 on any other failure
  review ready                mark the draft PR ready and set the phase to done,
                              printing the PR number; in a side checkout, a
                              pointer to the finish command on stderr
  review terminal             classify the last iteration: none, pending,
                              interrupted, malformed, ready, or stop; exits
                              non-zero on the first four
  review retire <n>           move every iteration-*.md into pre-redo-<n>/
  spec fetch <file>           write the spec issue's body to <file>
  spec update <file>          replace the spec issue's body with <file>
  spec comment <file>         post <file> as a comment on the spec issue
  spec comments <file>        write every comment on the spec issue to
                              <file>, as issue comments does
                              all four act on the active flow's issue,
                              refusing once the flow is done; for any other
                              issue use issue <op> <n> <file>
  spec-review begin <n>       start a standalone spec review of issue <n>:
                              refuse while an active flow holds <n> - at spec
                              (pointing at next) or at implement or review
                              (pointing at redo) - and otherwise empty
                              .orchestrator/spec-review/<n>/ and print its
                              path. Reads state.json only to compare, and
                              never writes it
  review-pass begin <issue>   start a review pass of the current branch
                              against issue <issue>: refuse on a detached
                              HEAD, on the base branch, and while an active
                              flow holds <issue> or the branch (pointing at
                              next, or at doctor --flow for an unknown phase);
                              otherwise print the next free report prefix
                              .orchestrator/review-pass/<branch>/iteration-NN,
                              branch name used whole, git-excluding
                              .orchestrator/. Never wipes; reads state.json
                              only to compare, and never writes it
  finding-triage scan [--all] [<issue> | --pr <n>]
                              read-only: fetch origin/<default> and sort each
                              open review:<severity> finding still in the
                              repo's needs-triage - or the one <issue>, or
                              those whose **PR:** is <n> - one line apiece:
                              <issue> TAB <pr> TAB <file>:<line> TAB <result>
                              TAB <detail> TAB <state>; result unchanged,
                              changed (detail: the newest touching commit's
                              full SHA), gone, or unknown (detail: why), an
                              empty pr or detail printed -, fetching
                              refs/pull/<pr>/head before calling a SHA
                              unreachable; state: the triage-role labels the
                              issue carries, comma-joined in role order
                              (needs-triage, needs-info, ready-for-agent,
                              ready-for-human, wontfix), or - for none.
                              --all: every open review:<severity> finding
                              whatever its triage label - the re-check - and
                              an explicit <issue> need not be in needs-triage
  finding-triage apply <issue> <close-fixed|wontfix> --comment-file <file>
  finding-triage apply <issue> <ready-for-agent|ready-for-human>
                       --category <bug|enhancement> --comment-file <file>
                              finding triage's one write: post <file> under
                              the AI disclaimer, remove every other
                              triage-role label it carries, then close it as
                              completed (close-fixed) or as not planned
                              labelled wontfix,
                              or label it with that state, keeping
                              review:<severity> and leaving exactly the one
                              category - created only where missing, never
                              with --force. --category is required on the open
                              outcomes and refused on the closing ones; state
                              labels are the repo's names for the roles
  finding-triage bundle --title <t> --body-file <f> --state <ready-for-agent|ready-for-human>
                       --category <bug|enhancement> <member>...
  finding-triage bundle --into <B> <member>...
                              group already-triaged filed findings: create
                              one bundle issue, titled <t> with <f> as its
                              body, labelled finding-bundle (created where
                              missing), the state and the category - never a
                              review: label - and print its number; then
                              comment each member "Bundled into #B" under the
                              AI disclaimer and close it as a duplicate of the
                              bundle (gh 2.102 or newer), keeping its labels.
                              Every member is checked first, nothing written
                              on a refusal: open, a filed review:<severity>,
                              exactly one of ready-for-agent and
                              ready-for-human, none of needs-triage,
                              needs-info and wontfix; at least 2 for a new
                              bundle. --state may not be ready-for-agent with
                              a ready-for-human member, nor --category
                              enhancement with a bug member. A member failure
                              dies naming the members left open and the
                              --into command that resumes. --into <B>: close
                              the members (one is enough) into the open
                              finding-bundle issue B, never editing it, nor
                              commenting a member twice
  redo review                 retire the branch and PR, reopen the spec
                              issue's closed tickets, reset the loop, retire
                              03-implement.md into handoff/pre-redo-<n>/, and
                              step the flow back to implement - refuses unless
                              the review loop has reached a terminal state
  redo spec [--new-issue]     step the flow back to spec, keeping the existing
                              issue by default and retiring its ticket
                              breakdown (ticket retire) so the redone spec is
                              broken down again; --new-issue closes it and
                              clears state.issue so orch-to-spec starts fresh;
                              02-spec.md and any 03-implement.md move into
                              handoff/pre-redo-spec-<UTC timestamp>/
  status                      human-readable summary of this checkout's flow,
                              then one line for every other checkout holding
                              a flow and every side checkout
  archive                     move the live flow into .orchestrator/archive/,
                              leaving archive/ and checkouts/ in place
                              (refuses, naming each, while a ticket worktree
                              is left under this checkout). In a side
                              checkout, the flow moves to the main checkout's
                              .orchestrator/archive/ and the worktree is then
                              removed, never with --force: a dirty one is
                              reported and kept, the archive still made
USAGE
}
