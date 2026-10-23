# shellcheck shell=bash
# global.sh - orch.sh's bare global commands with no module of their own:
# slug, status, archive and help. Its tests: scripts/test/orch/global.sh, save
# status's, which live in scripts/test/orch/side-checkout.sh; help has none of
# its own.
# Sourced by orch.sh, after common.sh and the ROOT block.

cmd_slug() {
  local raw="${1:-}" slug
  [ -n "$raw" ] || die "usage: orch.sh slug <text>"
  slug="$(normalize_slug "$raw")"
  note "$slug"
}

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
  local list kind flow _branch path lines=""
  list="$(checkouts)" || die "could not read the checkouts - git worktree list failed"
  while read -r kind flow _branch path; do
    [ "$path" != "$ROOT" ] || continue
    [ "$flow" = 1 ] || [ "$kind" = side ] || continue
    lines+="  $path $(checkout_holding "$path")"$'\n'
  done <<<"$list"
  [ -n "$lines" ] || return 0
  note ""
  note "other checkouts:"
  printf '%s' "$lines"
}

# Full detail on the current checkout's flow.
status_flow() {
  local slug phase issue branch pr iteration redo_count base budget
  slug="$(state_get slug)";       phase="$(state_get phase)"
  issue="$(state_get issue)";     branch="$(state_get branch)"
  pr="$(state_get pr)";           iteration="$(state_get iteration)"
  redo_count="$(state_get redo_count)"
  base="$(flow_base)" || die "cannot read the flow's base branch from $STATE"
  budget="$(review_budget)" || die "cannot read the flow's review budget from $STATE"
  issue="${issue:--}";            branch="${branch:--}";  pr="${pr:--}"
  note "flow:      $slug"
  note "phase:     $phase"
  note "issue:     $issue"
  note "base:      $base"
  note "branch:    $branch"
  note "PR:        $pr"
  # Against the budget, not alone: "iteration 3" does not say how far along
  # the loop is, and the budget is the one number a human chose.
  note "review:    iteration $iteration of $budget"
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
  local archive_home
  archive_home="$(archive_root "$ROOT")" || die "could not read the checkouts - nothing was archived"
  archive_flow "$ROOT" "$archive_home"
  # Only a side checkout archives anywhere but in place.
  if [ "$archive_home" != "$ROOT" ]; then side_checkout_remove_after_archive "$ROOT" "$archive_home"; fi
}

# side_checkout_remove_after_archive <path> <main-root>: removes the side
# checkout at <path>, through the main checkout at <main-root>, once its flow
# is archived, never with force. A dirty worktree is reported and kept: the
# archive has still succeeded. When this command ran inside the removed
# worktree, the session working there is told to close.
side_checkout_remove_after_archive() {
  local path="$1" main_root="$2" err here
  # Read before the removal: once the worktree is gone, so is this directory.
  here="$(pwd -P)"
  if ! err="$(git -C "$main_root" worktree remove "$path" 2>&1)"; then
    warn "kept side checkout $path - it was not removed: ${err%%$'\n'*}
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
  autopilot show              print the autopilot settings, each with its
                              source: orchestrator.autopilot.permission-mode
                              (no default), .cap (3), .handle (the repo's
                              owner), .rounds (2), .budget (3). Dies naming
                              the key and value when one is out of range
  autopilot active            exit 0 in an autopilot session (ORCH_AUTOPILOT=1),
                              1 otherwise
  autopilot rounds            print the Rounds line of the flow's issue's
  autopilot budget            plan comment (budget: its Budget line)
  autopilot start <issue> <plan-file>
                              the planning close's last step: refuse an issue
                              without ready-for-agent or with a phase label,
                              validate the plan (## Autopilot block included),
                              post it as the plan handoff comment, then add
                              orch:spec
  autopilot tick              one watcher pass: ensure the six labels, clean up
                              this host's stale claims, then claim each open
                              phase-labelled issue (oldest first, below the
                              cap), make or reuse its side checkout and start
                              `autopilot run` detached. Claude Code only;
                              needs orchestrator.autopilot.permission-mode
  autopilot watch [--every <seconds>]
                              repeat tick (default 60 s) until interrupted;
                              one live watch per clone (a pidfile under the
                              git common directory), a failed tick reported
                              on stderr and the loop carried on
  autopilot run <issue>       the session wrapper a tick starts: runs claude -p
                              in the issue's side checkout, logging under
                              .orchestrator/autopilot/logs/, and fails the
                              issue when the claim is still held at its exit
  autopilot ask <phase> <file>
                              post <file> as the phase's question comment
                              (@mentioning the handle), add needs-human, then
                              release the claim
  autopilot answer <phase> <file>
                              write the newest question and every later
                              comment to <file>; exit 1 when none follows
  agent set <role> [--model <m>] [--effort <e>] [--global] [--host junie]
                              set a role's agent setting in local config,
                              or global with --global. Roles: implementer,
                              lens, reviewer, fixer, closer, resolver; models:
                              sonnet, opus, haiku, fable; efforts: low,
                              medium, high, xhigh, max; inherit clears the
                              key at that scope. Validates everything before
                              writing; refuses a call with neither flag.
                              --host junie sets the Junie keys instead:
                              any name Junie's /model picker and --model
                              flag take, efforts low, medium, high
  agent show                  print each role's model and effort with each
                              one's source: local, global or inherit; a
                              disallowed hand-set value is marked invalid;
                              then the same for Junie, each line prefixed
                              junie
  agent clear <role> [--model] [--effort] [--global] [--host junie]
                              clear both keys, or only the one named, in
                              local config, or global with --global;
                              succeeds silently when nothing was set
  agent get <role> [--host junie]
                              print exactly `model <alias|inherit>` and
                              `effort <level|inherit>`, each looked up local,
                              then global, else inherit; refuses a
                              disallowed value, naming its key
  agent sync                  write, refresh and delete this checkout's
                              .junie/agents/ copies of the plugin's agents
                              to match the Junie agent setting; refuses an
                              unmarked orch-*.md in the way, changing nothing
  suite-cost run -- <cmd> [args...]
                              run <cmd> in the current directory, its stdout,
                              stderr and exit code passed through and nothing
                              added on stdout; on exit 0 alone, append its
                              suite cost to the clone-wide record under the
                              git common directory (orchestrator/suite-cost),
                              one line of five tab-separated fields: HEAD's
                              full SHA at the start, suffixed -dirty when
                              git status --porcelain printed anything then
                              (untracked files count, ignored paths do
                              not), CPU seconds (user plus
                              system, children included), wall seconds, the
                              UTC time in ISO 8601, and the command. An
                              append that fails warns and records nothing.
                              A run another suite-cost run overlapped, in
                              any checkout of the clone, is not recorded,
                              and warns; so is one that could not register
                              as active (orchestrator/suite-cost.active).
                              No run waits for another
  suite-cost check -- <cmd> [args...]
                              print one verdict line comparing the head's
                              lowest sample of <cmd> with the baseline's
                              lowest, exiting 0. The head sample is the
                              lowest CPU seconds among the recorded runs on
                              the commit of the newest head record (on HEAD
                              or an ancestor not on the base, or a dirty one
                              on HEAD or any ancestor; <sha>-dirty and <sha>
                              are different commits); the baseline sample
                              the lowest on the commit of the newest
                              baseline record (a clean one, never a dirty
                              one, on the base commit itself:
                              state.base_sha in a flow, else branch base-sha).
                              Verdicts: off (baseline below git config
                              orchestrator.suiteCost.floor, else 60 CPU
                              seconds), ok, grew <pct> - <finding text> (past
                              orchestrator.suiteCost.growth, else 15 percent),
                              or unmeasured. A growth is confirmed by
                              measuring head and base once more, in
                              temporary worktrees at HEAD and the baseline
                              sample's commit, and comparing again; the
                              head is run only to confirm a growth. A base
                              commit with no clean record of its own is
                              measured once, never an ancestor's record
                              reused, in a temporary
                              worktree. Each such run first runs
                              git config orchestrator.suiteCost.setup there,
                              untimed, when it is set. Such a base or
                              confirming run is not recorded when another
                              suite-cost run overlaps it, or when it could
                              not register as active, and the verdict is
                              then unmeasured. A verdict confirmed this way
                              is stored (orchestrator/suite-cost.verdicts)
                              and reused, printed with nothing run, while
                              the clean HEAD, base commit, command, floor
                              and growth are unchanged; a dirty tree never
                              reuses one. Dies naming the key and
                              value when an override is not a non-negative
                              number
  suite-cost history          print the record's lines, oldest first, or
                              nothing when there is no record
  repo show [--name|--host]   print the GitHub repo orch.sh works on and its
                              source: GH_REPO when set, else the checkout's
                              origin - never gh's default repo. --name prints
                              the bare [HOST/]OWNER/REPO alone, for gh -R;
                              --host its host alone, github.com for an
                              OWNER/REPO repo, for gh api --hostname.
                              Exits 1, naming GH_REPO, when neither resolves
  init <slug> [--issue N]     start a flow (refuses with exit 3 in a busy
                              checkout: a flow mid-pipeline - a done flow is
                              archived, unless a ticket worktree is left, and
                              the new one starts over it - or a branch the
                              plugin made with no PR yet; refuses with exit 1
                              if the working tree has changes outside the
                              planning allowlist);
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
                              it writes for the next one (the spec handoff
                              from spec, the implement handoff from
                              implement; orch.sh handoff path <next phase>
                              prints its file) and the state the next one
                              needs (issue; branch, base_sha, pr), then record
                              the next phase and print the boundary. On a
                              FAIL the phase stays. Refuses at review (use
                              review ready) and done
  phase boundary              print the block that ends a phase - the
                              handoff the current phase reads, and the
                              host's Next line
  handoff path <phase>        print the handoff path for a phase (in an
                              autopilot flow: fetch the handoff comment into a
                              scratch file under .orchestrator/ and print it)
  handoff post <name> <file>  in an autopilot flow: validate <file> and post
                              it as the issue comment tagged
                              `<!-- orch:handoff <name> -->` (01-plan,
                              02-spec, 03-implement); the newest wins, and a
                              failed post posts nothing
  handoff fetch <name> <file> in an autopilot flow: write the newest such
                              comment's body, marker stripped, to <file>; a
                              newest one tagged retired is no handoff
  handoff validate <file>     check required sections exist and are non-empty
  handoff section <file> <heading>
                              print the body of the section headed
                              `## <heading>`, blank lines trimmed; a missing
                              file, a missing heading, or a repeated heading
                              is an error
  glossary terms              print every term name in the root GLOSSARY.md,
                              one per line, in glossary order
  glossary show <term>...     print the named entries exactly as written, in
                              the order asked, each once. A term matches its
                              name, case ignored, else an avoided alias
                              (scoped ones included), with # alias of <Term>
                              on stderr. Exits 1 naming each term with no
                              entry, every found entry still printed
  glossary match <file>...    print every entry whose term or unscoped avoided
                              alias the files mention - case ignored, from a
                              word boundary, any ending, any whitespace run
                              for a space - in glossary order, each once.
                              Exits 2 on a missing or unreadable file.
                              show and match put one blank line between
                              entries. An entry starts at a **<Term>**: line,
                              optionally after a - or * bullet, alone or with
                              its definition after it, and runs to the next
                              entry start, the next # line or EOF; an
                              indented _Avoid_: line gives it aliases.
                              With no root GLOSSARY.md, terms and match print
                              nothing; show exits 2. A root GLOSSARY.md with
                              no entries is an error: all three exit 2
  branch create               create orch/<issue>-<slug> off the flow's base
                              branch, recorded at init, recording that base
                              and its tip as the base SHA in state and in
                              the branch's git config, as branch off does.
                              Refuses with exit 3 in a busy checkout, its own
                              flow aside, changing nothing
  branch off <name>           create and check out <name> off the base branch
                              in effect, recording that base on the branch
                              (branch.<name>.orchestrator-base in local git
                              config) and its tip at branching as the base
                              SHA (branch.<name>.orchestrator-base-sha), and
                              no state - for a quick implementation, which
                              keeps none. Refuses with exit 3 in a busy
                              checkout (see branch busy), changing nothing
  branch busy                 tell whether this checkout is a busy checkout,
                              from local git and state only: a flow
                              mid-pipeline, a branch the plugin made with no
                              PR yet (no branch.<name>.orchestrator-pr), or
                              changes outside the planning allowlist, checked
                              in that order. Exit 0 printing nothing when
                              free; exit 3 printing the first that holds; exit
                              1 when the working tree cannot be read
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
                              state; with --json, for scripts, the issue as
                              one JSON object {number, title, body, labels:
                              [<name>], comments: [{author, createdAt, body}]}
  issue update <n> <file>     replace issue <n>'s body with <file>, recording
                              no state
  issue comment <n> <file>    post <file> as a comment on issue <n>,
                              recording no state
  issue comments <n> <file>   write every comment on issue <n> to <file>, in
                              order, each opened by a line
                              <!-- comment @<login> <createdAt> --> - recording
                              no state; a comment whose body opens with the
                              ## Spec review heading is left out; no comments
                              is an empty file
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
  issue triage <n> --check    the same read and walk, writing nothing: print
                              ready (it carries ready-for-agent), the held
                              label (wontfix ahead of ready-for-human), or
                              movable, exit 0; exit 1 where the write would
                              die. Not with --override
  issue close <n> (--completed | --duplicate-of <m>) --comment-file <file>
                              close issue <n> as completed, or as a duplicate
                              of <m> (gh 2.102 or newer), with <file> as its
                              closing comment, in one gh call - reading
                              nothing back, labels unchanged, recording no
                              state
  issue ready <n>             exit 0 when issue <n> carries the repo's
                              ready-for-agent label, 1 when it does not, 2 on
                              a usage error or a gh failure - recording no
                              state
  pr open <title> <body-file> [--label <name>]...
                              push and open a draft PR against the flow's base
                              branch - Closes its issue into the default
                              branch, Refs it into any other. --label,
                              repeatable, opens it carrying that label, read
                              back once the PR is recorded: one missing, or a
                              failed read, fails naming the PR
  pr publish <issue> <title> <body-file> [--draft] [--label <name>]...
                              push the current branch and open a non-draft PR
                              against the base branch branch off recorded for
                              it (else the base branch in effect) - Closes
                              <issue> into the default branch, Refs it into any
                              other - recording no state; prints the PR number
                              - for a quick implementation whose review pass
                              already ran. --draft opens it as a draft, for a
                              pass that met a spec question. --label as pr
                              open's
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
  pr draft                    turn the current branch's open PR into a draft,
                              recording no state. Exits 0 when done or the PR
                              is already a draft (saying so), 1 when the branch
                              has no open PR, 2 when GitHub cannot be read or
                              the call fails (relaying gh's reason), the call
                              is wrong, or an active flow holds the branch
  pr ready                    mark the current branch's open PR ready, as pr
                              draft does: 0 also when it is already ready
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
  ticket close <n> [--unmerged]
                              close ticket <n>; refuses while ticket <n>'s
                              ticket worktree exists under this checkout and
                              its ticket branch has not merged into its
                              forked-from branch (or records none), leaving
                              the issue open - --unmerged closes it anyway
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
  review file <major|nit> <title> --axis <spec|standards|suite-cost>
              --finding-file <f> --severity-reason <r>
              --location <file>:<line|suite> --sha <sha>
              --pr <url> --why <reason> [--spec-question <q>]
                              file a finding as a GitHub issue labelled
                              review:<severity>, the repo's needs-triage, and
                              bug (spec axis) or enhancement (standards or
                              suite-cost axis),
                              creating the labels if missing; prints the number.
                              The body is rendered from the parts - the finding
                              file, then one labelled line per flag - and
                              refused before any write unless it parses back
                              to them. <line> is N or N-M
  review known-items <path> <loop boundary>
                              write the loop's known-items file to <path>,
                              overwriting it: ## Deviations from the implement
                              handoff, then ## Known items - Waiting to be
                              filed from each record above the boundary, Filed
                              from each at or below it, and the plan's
                              Rejected alternatives, each tagged with its
                              source; an empty heading reads None. Refused,
                              writing nothing, without either handoff
  review standards            print the reviewers' Standards: line - root
                              CLAUDE.md and AGENTS.md (with neither,
                              CODING_STANDARDS.md and CONTRIBUTING.md), then
                              the .md paths they mention in backticks or
                              Markdown links, then those mentioned there: two
                              hops, each path once, only paths that exist,
                              joined by ", "; Standards: none when none do
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
  spec pause                  stop the spec phase's session once the spec is
                              written: write handoff/spec-paused naming the
                              flow's issue, then print the stop block naming
                              the host's way to start a fresh session; the
                              phase stays spec. Refuses without a recorded
                              issue, outside the spec phase, or once the flow
                              is done
  spec pause --round <k>/<n>  stop a flow's spec review session after round k
                              of n, k < n, has applied: write handoff/
                              spec-round naming the flow's issue, k+1 and n,
                              then print the stop block - a failed write
                              prints no block. The last round never pauses.
                              Refuses a malformed <k>/<n>, k not below n, and
                              as spec pause does
  spec round-dir <k>/<n>      make a flow's spec review round k of n ready
                              and print its directory, .orchestrator/
                              spec-rounds/<k>/: emptied (created when
                              missing); on round 1 every other round's
                              directory deleted; on a later round round
                              k-1's agent-lens (round 1's lens setting),
                              map-implementability.md and settled.md
                              copied in, each when it exists. Then write
                              handoff/spec-round naming the flow's issue, k
                              and n - a failed write prints no path.
                              Idempotent. Refuses a malformed <k>/<n>, k past
                              n, and as spec pause does
  spec round                  print the round a resumed spec review runs
                              next, from handoff/spec-round: "<k> <n>" - k+1
                              once round k's directory holds round-complete -
                              or "done <n>" once round n's does. Exits 1,
                              printing nothing, with no marker or one naming
                              another issue; 2 on a malformed marker and on
                              every refusal spec pause makes
  spec-review begin <n> [--carry]
                              start a standalone spec review of issue <n>:
                              refuse while an active flow holds <n> - at spec
                              (pointing at next) or at implement or review
                              (pointing at redo) - and otherwise empty
                              .orchestrator/spec-review/<n>/ and print its
                              path. --carry, on rounds 2 and later, keeps
                              its map-implementability.md and settled.md
                              through the wipe, each when it exists.
                              Reads state.json only to compare, and never
                              writes it
  spec-review check <dir> [--tickets | --full <n>...]
                              validate a round's <dir>/batch.md before the
                              batch question: its grammar, the lens files and
                              their citations, every anchor (each item's and
                              each decision option's) matching exactly once,
                              and a dry run of the all answer, against
                              <dir>/spec.fetched.md, else <dir>/spec.md.
                              Writes only <dir>/view.md, touches no GitHub,
                              reads no flow state. Exit 1 with one orch:
                              line per error, each naming its batch.md or
                              lens-<name>.md line where it has one - the first
                              grammar error only, every anchor problem; exit
                              0 with the batch view on stdout, the same
                              bytes in <dir>/view.md (overwritten), and a
                              one-line summary on stderr naming view.md by
                              absolute path and saying to end the turn on
                              one plain-text reply with no tool call: the
                              view word for word, then the question.
                              --tickets validates
                              <dir>/tickets.md instead, before the ticket
                              question, as apply --tickets would take the all
                              answer: its grammar, each ticket item's anchor
                              against ticket-<t>.fetched.md, else
                              ticket-<t>.md, each ## Ticket item's against
                              <dir>/spec.md, and each edge against its
                              ticket's ## Blocked by - one orch: line per
                              problem, each naming its tickets.md line, or the
                              ticket view on stdout and in view.md - or, with
                              no open ticket affected, the stub, with any
                              earlier view.md removed and none named. The
                              checks that need GitHub stay in apply.
                              --full <n>... validates batch.md the same way,
                              then prints only the named items, any in
                              batch.md, each in full (findings and comments
                              quoted, Current and Proposed whole), in the
                              order named, that view in view.md; never with
                              --tickets
  spec-review wait <dir> <lens>...
                              block until <dir>/lens-<lens>.md exists for
                              every named lens (fidelity, consistency,
                              testability, implementability), then print
                              "lenses back: <lens> <count>, ..." in the order
                              named, <count> the file's @@ finding lines. Run
                              in the response that starts the lenses. Exit 1,
                              nothing on stdout, naming the lenses still
                              missing after ORCH_SPEC_REVIEW_WAIT_TIMEOUT
                              seconds (default 900), polling every
                              ORCH_SPEC_REVIEW_WAIT_INTERVAL (default 5)
  spec-review prompt <dir> <lens>
                              print <lens>'s whole prompt, for the session
                              to pass unchanged: one "<label>: <path>" line
                              per path in its lens-table row, every path
                              absolute, the findings file last. A missing
                              input (glossary.md, docs/adr/, settled.md, the
                              previous map-implementability.md) prints
                              "<label>: none"; Map file: and Findings file:
                              are always given. <dir> is a standalone
                              review's or a flow round's directory and must
                              hold spec.md and comments.md. fidelity only in
                              a directory under .orchestrator/spec-rounds/,
                              its Plan handoff what handoff path spec prints;
                              dies when that fails, and on an unknown lens
  spec-review apply <dir> <answer> --round <k>/<n> [--reasons <file>]
                    [--tickets <answer> [--ticket-reasons <file>]]
                    [--issue <n>] [--unattended] [--host-fallbacks <file>]
                              apply a spec review round's answer - recommended,
                              all, none, or an Other list of departures from
                              the recommendation such as 3B, -4, +2 (<n><letter>
                              a decision's option, -<n> an item declined or a
                              decision left undecided, +<n> a recommend-decline
                              item applied, every item not named as
                              recommended) - to <dir>/batch.md's items: each
                              accepted edit by exact anchor on
                              <dir>/spec.fetched.md (copied from spec.md on
                              the first run) into spec.md,
                              then the body published when it changed and
                              <dir>/changelog.md written and posted. Every
                              check runs before the first write: a malformed
                              batch or lens-<name>.md file, an anchor matching
                              no text or more than once, an unknown item or
                              option, or a bad --reasons line refuses it all.
                              With an applied edit and a ticket breakdown it
                              pauses before any GitHub write, printing the
                              breakdown kind, exit 3; the rerun's --tickets -
                              recommended, all, none, retire, or a list such
                              as 1, 3 - answers <dir>/tickets.md's items, each
                              ticket text edit applied to ticket-<n>.fetched.md
                              (copied from ticket-<n>.md on the first run that
                              finds it) or to the body's ## Ticket section.
                              Writes: ticket text edits, then ticket
                              block/unblock, then the body, then any ticket
                              retire, then the comment, then the changelog
                              appended to <dir>/settled.md, then, last, an
                              empty <dir>/round-complete. The issue is state's,
                              through spec update/comment, or --issue's,
                              through issue update/comment, never reading
                              state.json. Each GitHub write lands in
                              <dir>/applied.log; a failed one dies naming those
                              landed, and a non-empty applied.log is refused
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
  review-pass known-items <issue> <path> [--deviations <file>]
                              write the pass's known-items file to <path>,
                              overwriting it: ## Deviations from the PR body,
                              or the --deviations file in its place, then
                              ## Known items - the declines under Review in
                              the PR body and in each comment with both Review
                              and Host fallbacks, and the Spec rulings lines
                              of the PR's comments and the issue's
                              "Spec ruling:" comments, each tagged with its
                              source; an empty heading reads None. With no
                              open PR, only the rulings and --deviations are
                              read. Refused, writing nothing, on a missing
                              --deviations file or an unreadable GitHub
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
                              the implement handoff (orch.sh handoff path
                              review) into handoff/pre-redo-<n>/, and step the
                              flow back to implement - refuses unless the
                              review loop has reached a terminal state
  redo spec [--new-issue]     step the flow back to spec, keeping the existing
                              issue by default and retiring its ticket
                              breakdown (ticket retire) so the redone spec is
                              broken down again; --new-issue closes it and
                              clears state.issue so orch-to-spec starts fresh;
                              the spec handoff and any implement handoff
                              (orch.sh handoff path implement, and review)
                              move into handoff/pre-redo-spec-<UTC timestamp>/
  status                      human-readable summary of this checkout's flow,
                              then one line for every other checkout holding
                              a flow and every side checkout
  archive                     move the live flow into .orchestrator/archive/,
                              leaving archive/, checkouts/, spec-review/ and
                              review-pass/ in place
                              (refuses, naming each, while a ticket worktree
                              is left under this checkout). In a side
                              checkout, the flow moves to the main checkout's
                              .orchestrator/archive/ and the worktree is then
                              removed, never with --force: a dirty one is
                              reported and kept, the archive still made
USAGE
}
