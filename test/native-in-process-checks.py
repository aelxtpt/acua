"""Run the in-process check suites compiled into the signed service.

Each hidden `--native-*` flag makes the service run one check suite inside its own
signed process and write a JSON report. These suites exercise real product code
(coordinates, actions, target resolution, errors, screenshots, policy) with the
native side effects intercepted, so they need no physical input or UI.

The expected case counts are part of the contract: a suite that silently runs fewer
cases is a placebo, so a count mismatch fails the run. Update the count together
with the suite when a case is added or removed.

Some flags run several suites in sequence; the later ones write their own report
next to the main one. Those chained reports are checked the same way, so a later
suite cannot shrink unnoticed behind a passing first one.

Target stop, frontmost window and service dispatch are not listed here because the
lifecycle group already runs them. Checks that launch fixture applications into a
live session (keyboard, paste, rich conversion, live snapshot, PIP renderer,
instance routing) or serve a socket to an external consumer (usage, coordinator,
permission ingress and live automation wires) belong to the physical batches.
"""

from dataclasses import dataclass
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


PROJECT = Path(__file__).resolve().parents[1]
FIXTURES = PROJECT / "test/fixtures"
CHECK_TIMEOUT_SECONDS = 60
CHECK_PASSED_EXIT_CODE = 0
DISABLED_ACUA_CONFIGURATION = "[apps]\nenabled = false\n"


@dataclass(frozen=True)
class FixtureFile:
    """A versioned input copied into the run, because the launcher only accepts owned paths."""
    source: Path


@dataclass(frozen=True)
class OwnedDirectory:
    """An empty directory inside the run that the suite may write into."""


@dataclass(frozen=True)
class ChainedReport:
    """A report a later suite of the same flag writes beside the main report."""
    file_name: str
    expected_cases: int


@dataclass(frozen=True)
class NativeCheckSuite:
    flag: str
    expected_cases: int
    arguments: tuple = ()
    disabled_acua_home: bool = False
    chained_reports: tuple = ()


WIRE_ERROR_FIXTURE = FixtureFile(FIXTURES / "error-classification/wire-fixtures.json")
DRAG_EVENTS_FIXTURE = FixtureFile(PROJECT / "test/native-drag-events-expected.json")

SUITES = (
    NativeCheckSuite("--native-refetch-only-checks", 39),
    NativeCheckSuite("--native-string-writer-checks", 13),
    NativeCheckSuite("--native-field-operation-checks", 7,
                     chained_reports=(ChainedReport("field-operation-writer-regression.json", 13),)),
    NativeCheckSuite("--native-secondary-scroll-checks", 16),
    NativeCheckSuite("--native-selection-checks", 17),
    NativeCheckSuite("--native-pasteboard-checks", 17),
    NativeCheckSuite("--native-coordinate-checks", 49, (DRAG_EVENTS_FIXTURE,),
                     chained_reports=(ChainedReport("native-binding-result.json", 13),)),
    NativeCheckSuite("--native-element-click-corrections", 29,
                     chained_reports=(ChainedReport("inherited-lower-result.json", 36),
                                      ChainedReport("inherited-click-result.json", 22),
                                      ChainedReport("inherited-cursor-result.json", 23))),
    NativeCheckSuite("--native-app-snapshot-request-checks", 23, (OwnedDirectory(),),
                     chained_reports=(ChainedReport("native-binding-result.json", 31),)),
    NativeCheckSuite("--native-action-request-checks", 65),
    NativeCheckSuite("--native-coordinator-error-checks", 30),
    NativeCheckSuite("--native-screenshot-file-checks", 15,
                     chained_reports=(ChainedReport("core-result.json", 43),
                                      ChainedReport("refetch-result.json", 39))),
    NativeCheckSuite("--native-screenshot-buffer-checks", 2,
                     chained_reports=(ChainedReport("configuration-result.json", 26),
                                      ChainedReport("core-result.json", 80))),
    NativeCheckSuite("--native-error-codec-checks", 115, (WIRE_ERROR_FIXTURE,)),
    NativeCheckSuite("--native-error-classification-checks", 226, (WIRE_ERROR_FIXTURE,)),
    NativeCheckSuite("--native-lock-preparation-checks", 41, (WIRE_ERROR_FIXTURE,)),
    NativeCheckSuite("--native-default-policy", 5, disabled_acua_home=True),
    NativeCheckSuite("--native-launch-state-checks", 18,
                     chained_reports=(ChainedReport("native-binding-result.json", 29),)),
    NativeCheckSuite("--native-legacy-offscreen-checks", 18, (OwnedDirectory(),)),
    # The cursor checks use borderless panels at 0.001 alpha that ignore the mouse and the
    # permission presenter windows are never shown; nothing is clicked and the service is
    # never activated.
    NativeCheckSuite("--native-request-controller-executor-window", 17,
                     chained_reports=(ChainedReport("C106-native-window-result.json", 11),
                                      ChainedReport("C107-native-window-result.json", 20),
                                      ChainedReport("C108-native-window-result.json", 7),
                                      ChainedReport("C109-native-window-result.json", 10))),
)

# Reports name their case list differently; all of them are lists of {name, passed}.
CASE_LIST_KEYS = ("checks", "cases", "results")


def case_rows(report):
    for key in CASE_LIST_KEYS:
        rows = report.get(key)
        if isinstance(rows, list):
            return rows

    return []


def suite_name(suite):
    return suite.flag.removeprefix("--native-")


def prepare_arguments(suite, directory):
    arguments = []

    for index, argument in enumerate(suite.arguments):
        if isinstance(argument, FixtureFile):
            copy = directory / f"input-{index}-{argument.source.name}"
            shutil.copy2(argument.source, copy)
            arguments.append(str(copy))
            continue

        owned = directory / f"owned-{index}"
        owned.mkdir()
        arguments.append(str(owned))

    return arguments


def prepare_environment(suite, directory):
    environment = os.environ.copy()

    if not suite.disabled_acua_home:
        return environment

    acua_home = directory / "acua-home"
    acua_home.mkdir()
    (acua_home / "config.toml").write_text(DISABLED_ACUA_CONFIGURATION)
    environment["ACUA_HOME"] = str(acua_home)
    return environment


def run_suite(suite, launcher, root):
    directory = root / suite_name(suite)
    directory.mkdir()
    report_path = directory / "report.json"
    command = [str(launcher), suite.flag, str(report_path), *prepare_arguments(suite, directory)]

    try:
        process = subprocess.run(command, cwd=PROJECT, env=prepare_environment(suite, directory),
                                 capture_output=True, text=True, timeout=CHECK_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        return [f"timed out after {CHECK_TIMEOUT_SECONDS}s"]

    problems = []

    if process.returncode != CHECK_PASSED_EXIT_CODE:
        problems.append(f"exit code {process.returncode}: {process.stderr.strip()[-300:]}")

    problems.extend(report_problems(report_path, suite.expected_cases))

    for chained in suite.chained_reports:
        chained_problems = report_problems(directory / chained.file_name, chained.expected_cases)
        problems.extend(f"{chained.file_name}: {problem}" for problem in chained_problems)

    return problems


def report_problems(report_path, expected_cases):
    if not report_path.is_file():
        return ["wrote no report"]

    report = json.loads(report_path.read_text())
    rows = case_rows(report)
    failed = [row.get("name") for row in rows if row.get("passed") is not True]
    problems = []

    if report.get("passed") is not True:
        problems.append("report is not passed")

    if failed:
        problems.append(f"failed cases: {failed[:5]}")

    if len(rows) != expected_cases:
        problems.append(f"ran {len(rows)} cases, expected {expected_cases}")

    return problems


def main():
    launcher = Path(os.environ["CUA_REVIEW_LAUNCHER"])
    root = Path(os.environ["CUA_REVIEW_RUN"]) / "t/native-in-process-checks"
    shutil.rmtree(root, ignore_errors=True)
    root.mkdir(parents=True)

    failures = 0

    for suite in SUITES:
        problems = run_suite(suite, launcher, root)

        if problems:
            failures += 1
            print(f"FAIL {suite_name(suite)}: " + "; ".join(problems))
            continue

        print(f"PASS {suite_name(suite)} ({suite.expected_cases} cases)")

    print(f"{len(SUITES) - failures}/{len(SUITES)} native in-process suites passed")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
