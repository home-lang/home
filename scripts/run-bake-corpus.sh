#!/usr/bin/env bash
# Run the pinned, unchanged Bun Bake corpus through Home's native runtime.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORPUS="${REPO_ROOT}/packages/runtime/test/test"
DEPENDENCIES="${REPO_ROOT}/packages/runtime/test/bake-dependencies"
HOME_BIN="${HOME_BIN:-${REPO_ROOT}/zig-out/bin/home}"
NODE_BIN="${BUN_DEV_SERVER_CLIENT_EXECUTABLE:-$(command -v node || true)}"
NPM_BIN="${NPM_BIN:-$(command -v npm || true)}"
EXPECTED_SHA="4982b91e3702094330f3be3883354c52b8c01323"
ACTUAL_SHA="$(tr -d '[:space:]' < "${CORPUS}/UPSTREAM_SHA.txt")"

if [[ "${ACTUAL_SHA}" != "${EXPECTED_SHA}" ]]; then
  echo "error: Bake corpus SHA ${ACTUAL_SHA} does not match ${EXPECTED_SHA}" >&2
  exit 1
fi
if [[ ! -x "${HOME_BIN}" ]]; then
  echo "error: JSC-enabled Home executable not found at ${HOME_BIN}" >&2
  echo "       build it with ./pantry/.bin/zig build -Denable_jsc=true" >&2
  exit 2
fi
if [[ -z "${NODE_BIN}" || ! -x "${NODE_BIN}" ]]; then
  echo "error: Node.js executable not found; set BUN_DEV_SERVER_CLIENT_EXECUTABLE" >&2
  exit 2
fi
if [[ -z "${NPM_BIN}" || ! -x "${NPM_BIN}" ]]; then
  echo "error: npm executable not found; set NPM_BIN" >&2
  exit 2
fi

python3 "${REPO_ROOT}/scripts/audit-bun-corpus-integrity.py"

WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/home-bake-corpus.XXXXXX")"
if [[ "${KEEP_BAKE_TEMP:-0}" == "1" ]]; then
  echo "Bake workspace: ${WORK_ROOT}"
else
  trap 'rm -rf "${WORK_ROOT}"' EXIT
fi

OVERLAY="${WORK_ROOT}/overlay/packages/runtime/test"
BASE_INSTALL="${WORK_ROOT}/base-dependencies"
REACT_INSTALL="${WORK_ROOT}/react-dependencies"
TEST_TEMP="${WORK_ROOT}/test-temp"

mkdir -p "${OVERLAY}/test" "${BASE_INSTALL}" "${REACT_INSTALL}" "${TEST_TEMP}/.react-cache"
cp -R "${CORPUS}/." "${OVERLAY}/test/"
ln -s "${REPO_ROOT}/packages/runtime/upstream/src" "${OVERLAY}/src"

cp "${DEPENDENCIES}/base/package.json" "${DEPENDENCIES}/base/package-lock.json" "${DEPENDENCIES}/base/bun.lock" "${BASE_INSTALL}/"
(
  cd "${BASE_INSTALL}"
  "${NPM_BIN}" ci --no-audit --no-fund
)

(
  cd "${BASE_INSTALL}"
  HOME_NATIVE_VM=1 "${HOME_BIN}" install --frozen-lockfile --lockfile-only --ignore-scripts
)
cmp "${DEPENDENCIES}/base/bun.lock" "${BASE_INSTALL}/bun.lock"

mkdir -p "${BASE_INSTALL}/node_modules/harness"
cat > "${BASE_INSTALL}/node_modules/harness/package.json" <<'EOF'
{"name":"harness","type":"module","exports":"./index.ts"}
EOF
python3 - "${BASE_INSTALL}/node_modules/harness/index.ts" "${OVERLAY}/test/harness.ts" <<'PYTHON'
from pathlib import Path
import json
import sys
Path(sys.argv[1]).write_text('export * from ' + json.dumps(sys.argv[2]) + ';\n')
PYTHON
ln -s "${OVERLAY}/test/_util" "${BASE_INSTALL}/node_modules/_util"
ln -s "${BASE_INSTALL}/node_modules" "${OVERLAY}/test/node_modules"

cp "${DEPENDENCIES}/react/package.json" "${DEPENDENCIES}/react/package-lock.json" "${REACT_INSTALL}/"
(
  cd "${REACT_INSTALL}"
  "${NPM_BIN}" ci --no-audit --no-fund
)
cp "${REACT_INSTALL}/package.json" "${TEST_TEMP}/.react-cache/"
cp "${DEPENDENCIES}/react/bun.lock" "${REACT_INSTALL}/"
(
  cd "${REACT_INSTALL}"
  HOME_NATIVE_VM=1 "${HOME_BIN}" install --frozen-lockfile --lockfile-only --ignore-scripts
)
cmp "${DEPENDENCIES}/react/bun.lock" "${REACT_INSTALL}/bun.lock"
cp "${REACT_INSTALL}/bun.lock" "${TEST_TEMP}/.react-cache/"
cp -R "${REACT_INSTALL}/node_modules" "${TEST_TEMP}/.react-cache/"

TEST_FILES=()
if [[ "$#" -eq 0 ]]; then
  while IFS= read -r file; do
    TEST_FILES+=("${file}")
  done < <(rg --files "${OVERLAY}/test/bake" | rg '\.test\.ts$' | sort)
else
  for file in "$@"; do
    file="${file#test/bake/}"
    TEST_FILES+=("${OVERLAY}/test/bake/${file}")
  done
fi

echo "Bun corpus: ${EXPECTED_SHA}"
echo "Home:       ${HOME_BIN}"
echo "Node:       ${NODE_BIN}"
echo "Tests:      ${#TEST_FILES[@]} file(s)"

if [[ -z "${HOME_BUN_CORPUS_REPORT_DIR:-}" ]]; then
  mkdir -p "${REPO_ROOT}/zig-out/bake-corpus-reports"
  REPORT_PARENT="$(mktemp -d "${REPO_ROOT}/zig-out/bake-corpus-reports/run.XXXXXX")"
  export HOME_BUN_CORPUS_REPORT_DIR="${REPORT_PARENT}/native"
fi
if [[ -e "${HOME_BUN_CORPUS_REPORT_DIR}" ]]; then
  echo "error: use a fresh report directory: ${HOME_BUN_CORPUS_REPORT_DIR}" >&2
  exit 2
fi
echo "Evidence:   ${HOME_BUN_CORPUS_REPORT_DIR}"

# The suite coordinator captures one native process, source inventory, JUnit,
# exact case identities and terminal counters. It launches Home internally.
cd "${OVERLAY}"
unset HOME_NATIVE_VM
set +e
BUN_DEV_SERVER_TEST_TEMP="${TEST_TEMP}" \
  BUN_DEV_SERVER_CLIENT_EXECUTABLE="${NODE_BIN}" \
  "${HOME_BIN}" test --reporter=dots --cwd "${OVERLAY}" "${TEST_FILES[@]}"
TEST_STATUS=$?
python3 "${REPO_ROOT}/scripts/summarize-bun-corpus.py" "${HOME_BUN_CORPUS_REPORT_DIR}"
VALIDATION_STATUS=$?
set -e
if [[ "${TEST_STATUS}" != "0" ]]; then exit "${TEST_STATUS}"; fi
exit "${VALIDATION_STATUS}"
