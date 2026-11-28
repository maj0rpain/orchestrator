# shellcheck shell=bash
# The gh fake's file store layout (#280), the one statement of it.
#
# The store is a directory, named by ORCH_GH_FAKE_STORE, so what one process
# wrote is there for the next. The Python package's fake, orch/gh_fake.py's
# FakeGh, answers every adapter operation from it and its FakeStore seeds it;
# the operation names the failure files take are the adapter's (adapter_*).
# This file holds no code: the bash fake's operations went with the bash gh
# adapter. Its layout:
#
#   labels           one label per line,
#                    "<name><TAB><colour><TAB><description>";
#                    absent, the repo has no labels
#   issues/<n>/state  OPEN or CLOSED
#   issues/<n>/labels one label per line
#   issues/<n>/title  the title; absent, an empty one
#   issues/<n>/body   the body, byte for byte; absent, an empty one
#   issues/<n>/reason a closed issue's reason: completed, not planned or
#                     duplicate
#   issues/<n>/duplicate_of
#                     the issue a duplicate close named; absent, none
#   issues/<n>/pull   present, #n is a pull request, not an issue
#   issues/<n>/author, issues/<n>/association, issues/<n>/editor,
#   issues/<n>/renamer
#                     the issue author's login and authorAssociation, the
#                     login of the body's last editor and of the title's
#                     latest renamer; absent, the author is fake-gh as OWNER
#                     and the body is never edited nor the title renamed
#   issues/<n>/comments/<k>/{author,created,body}
#                     the issue's k-th comment
#   next_issue        the number the next created issue takes; absent, one
#                     past the highest the store holds
#   issues/<n>/created_at
#                     the UTC timestamp the issue was created at; absent, the
#                     epoch
#   prs/<n>/state     OPEN, CLOSED or MERGED
#   prs/<n>/head, prs/<n>/base
#                     the head and base branch names
#   prs/<n>/title     the title
#   prs/<n>/body      the body, byte for byte; absent, an empty one
#   prs/<n>/mergeable MERGEABLE, CONFLICTING or UNKNOWN; absent, UNKNOWN
#   prs/<n>/merged_at the UTC timestamp the PR merged at; absent, the epoch
#   prs/<n>/closing   the issue numbers the PR's closingIssuesReferences lists,
#                     one per line; absent, none
#   prs/<n>/draft     present, the PR is a draft
#   prs/<n>/labels    the PR's label names, one per line
#   pr_label_drops    label names, one per line, a PR create never stores -
#                     as a gh whose label mutation did not land
#   prs/<n>/head_oid  the head commit's SHA; absent, forty zeros; empty, as
#                     GitHub's null head
#   prs/<n>/url       the PR's URL; absent, https://github.com/o/r/pull/<n>
#   prs/<n>/commits   the PR's commit SHAs, one per line, oldest first;
#                     absent, the head alone, or none when the head is empty
#   prs/<n>/diff      the PR's diff, byte for byte; absent, an empty one
#   prs/<n>/comments/<k>/{author,created,body}
#                     the PR's k-th comment
#   next_pr           the number the next opened PR takes; absent, one past
#                     the highest issue or PR number the store holds
#   subs/<parent>     the parent's sub-issues, one number per line, in the
#                     order they were linked
#   blocked_by/<n>    the issues #n is blocked by, one number per line, in the
#                     order the edges were added
#   fail/<operation>  present, every call of that operation fails, non-zero,
#                     with the file's contents as gh's stderr
#   fail/<operation>.after
#                     a countdown: while above zero, each call of that
#                     operation succeeds despite fail/<operation> and counts it
#                     down
#   fail/<operation>.times
#                     a countdown: each failing call counts it down, and the
#                     call that reaches zero lifts fail/<operation> - a
#                     transient failure that clears on its own
#   lag/<operation>   a countdown: while above zero, each call of that
#                     operation answers stale and counts it down
#   lag/<operation>.after
#                     a countdown: while above zero, each call of that
#                     operation answers current, before its lag starts, and
#                     counts it down
#   lag/<operation>.stale
#                     the stale answer, where the operation takes one
#   comment_reads     one line per issue-comments read the Python fake made
#   default_branch    the answer to the repo's default branch, byte for byte;
#                     absent, gh cannot answer for the repo
#   checks/<n>/<scope>
#                     PR #n's scripted checks answers for a scope, required
#                     or all, one per line - green, failing, cancel,
#                     external, pending, none or boom - consumed one per
#                     call, the last repeating; absent, no checks
#   checks/<n>/<scope>.n
#                     how many calls the script has answered
#                     (this cursor, comment_reads, prs/<n>/evidence_reads and
#                     checks/<n>/reads are read-side bookkeeping)
#   checks/<n>/reads  one line per read of PR #n's checks, scripted scope or
#                     not; rescripting a scope never resets it
#   job_logs/<job>    the failed-step log of Actions job <job>; absent, the
#                     log cannot be read
#   protection/<branch>
#                     the check contexts classic protection requires on the
#                     branch, one per line; absent, the branch is unprotected
#   rules/<branch>    the type of each ruleset rule on the branch, one per
#                     line; absent, none
#   check_runs, statuses
#                     the refs (SHAs or branch names) that have a check run,
#                     or a commit status, one per line; absent, none do
#   prs/<n>/evidence_reads
#                     one line per adapter_pr_commits_checked read of PR #n
#   prs/<n>/evidence_raw
#                     present, that read's whole answer, printed as stored
#   prs/<n>/no_base_ref
#                     present, that read's base tip answer is empty
#   reruns            the Actions run ids rerun, one per line, in order
#   claims/<issue>    the issue's claim, one TSV line
#                     "<issue><TAB><host><TAB><pid><TAB><phase><TAB><started>";
#                     absent, the issue is unclaimed
#   local_default     gh's own local default repo, as OWNER/REPO; absent,
#                     none is set
#   no_dependency_summary
#                     issue numbers, one per line, whose dependency summary
#                     GitHub leaves off: adapter_issue_open_blockers answers
#                     nothing for them
#   no_sub_issues     present, the sub-issues endpoint refuses every issue
#   no_comment_url    present, the Python fake's issue comment URL post
#                     answers no URL
#   offline           present, every operation fails with a connection error
#   ratelimit         present, every operation but the rate_limit read fails
#                     as a GitHub API rate limit, with the file's contents as
#                     gh's stderr
#   quota             the rate_limit read's answer, one
#                     "<pool><TAB><remaining><TAB><limit><TAB><reset>" line
#                     per pool; absent, full pools
#   noauth            present, gh is not authenticated: every operation fails
#                     as unauthorised (the Python fake's auth status read
#                     fails saying so)
