"""`python3 -m orch <noun> <verb> ...` and `python3 -m orch --call <noun>
<func> ...`: the interpreter check, then orch.cli's main or call_func.

main(argv) takes `<noun> <verb> ...` as orch.sh's orch_python hands them on,
or `--call <noun> <func> ...` as orch_python_call hands them on. Below Python
3.9 it dies before doing anything, exit 1, naming the noun and version found.

This file is in syntax every python3 compiles - no annotations, f-strings or
`from __future__` imports - and imports the package's other modules only after
the check, so an older Python dies with the check's message, never a syntax
error. For the same reason its message is written here by hand rather than
through orch.common's die, the one such line on the Python side.
"""
import sys

MIN_PYTHON = (3, 9)


def require_python(noun):
    """Dies, exit 1, when the running Python is older than MIN_PYTHON - exit
    1 even for a verb that reserves 1 for a "no", the carve-out in
    coding-standards rule 2."""
    if tuple(sys.version_info[:2]) >= MIN_PYTHON:
        return
    found = ".".join(str(part) for part in sys.version_info[:3])
    sys.stdout.flush()
    sys.stderr.write(
        "orch: orch.sh %s needs python3 3.9 or newer (found %s) - run orch.sh doctor\n"
        % (noun, found)
    )
    sys.exit(1)


def main(argv):
    if argv and argv[0] == "--call":
        require_python(argv[1] if len(argv) > 1 else "")
        from orch.cli import call_func

        return call_func(argv[1:])
    require_python(argv[0] if argv else "")
    from orch.cli import main as run_noun

    return run_noun(argv)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
