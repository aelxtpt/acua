#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
if [[ ${1:-} == --review ]]; then
  shift
  exec python3 test/review-suite.py "$@"
fi
if [[ ${1:-} == --list ]]; then
  exec python3 test/review-suite.py --list
fi
make -C service bundle || exit $?
exec python3 test/review-suite.py service/.build/current/dist "$@"
