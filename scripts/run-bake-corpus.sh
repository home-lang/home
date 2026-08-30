#!/usr/bin/env bash
# Run the pinned, unchanged Bun Bake corpus through Home's native runtime.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORPUS="${REPO_ROOT}/packages/runtime/test/bun-corpus"
DEPENDENCIES="${REPO_ROOT}/packages/runtime/test/bake-dependencies"
HOME_BIN="${HOME_BIN:-${REPO_ROOT}/zig-out/bin/home-debug}"
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

WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/home-bake-corpus.XXXXXX")"
if [[ "${KEEP_BAKE_TEMP:-0}" == "1" ]]; then
  echo "Bake workspace: ${WORK_ROOT}"
else
  trap 'rm -rf "${WORK_ROOT}"' EXIT
fi

OVERLAY="${WORK_ROOT}/overlay"
BASE_INSTALL="${WORK_ROOT}/base-dependencies"
REACT_INSTALL="${WORK_ROOT}/react-dependencies"
TEST_TEMP="${WORK_ROOT}/test-temp"

mkdir -p "${OVERLAY}/test" "${BASE_INSTALL}" "${REACT_INSTALL}" "${TEST_TEMP}/.react-cache"
cp -R "${CORPUS}/." "${OVERLAY}/test/"
ln -s "${REPO_ROOT}/packages/runtime/upstream/src" "${OVERLAY}/src"

cp "${DEPENDENCIES}/base/package.json" "${DEPENDENCIES}/base/package-lock.json" "${BASE_INSTALL}/"
(
  cd "${BASE_INSTALL}"
  "${NPM_BIN}" ci --no-audit --no-fund
)

mkdir -p "${BASE_INSTALL}/node_modules/harness"
cat > "${BASE_INSTALL}/node_modules/harness/package.json" <<'EOF'
{"name":"harness","type":"module","exports":"./index.ts"}
EOF
cat > "${BASE_INSTALL}/node_modules/harness/index.ts" <<'EOF'
export * from "../../../overlay/test/harness.ts";
EOF
ln -s "${OVERLAY}/test/_util" "${BASE_INSTALL}/node_modules/_util"
ln -s "${BASE_INSTALL}/node_modules" "${OVERLAY}/test/node_modules"

cp "${DEPENDENCIES}/react/package.json" "${DEPENDENCIES}/react/package-lock.json" "${REACT_INSTALL}/"
(
  cd "${REACT_INSTALL}"
  "${NPM_BIN}" ci --no-audit --no-fund
)
cp "${REACT_INSTALL}/package.json" "${TEST_TEMP}/.react-cache/"
: > "${TEST_TEMP}/.react-cache/bun.lock"
cp -R "${REACT_INSTALL}/node_modules" "${TEST_TEMP}/.react-cache/"

TEST_FILES=()
if [[ "$#" -eq 0 ]]; then
  while IFS= read -r file; do
    TEST_FILES+=("${file#"${OVERLAY}/"}")
  done < <(find "${OVERLAY}/test/bake" -name '*.test.ts' -type f | sort)
else
  for file in "$@"; do
    file="${file#test/bake/}"
    TEST_FILES+=("test/bake/${file}")
  done
fi

echo "Bun corpus: ${EXPECTED_SHA}"
echo "Home:       ${HOME_BIN}"
echo "Node:       ${NODE_BIN}"
echo "Tests:      ${#TEST_FILES[@]} file(s)"

cd "${OVERLAY}"
HOME_NATIVE_VM=1 \
  BUN_DEV_SERVER_TEST_TEMP="${TEST_TEMP}" \
  BUN_DEV_SERVER_CLIENT_EXECUTABLE="${NODE_BIN}" \
  "${HOME_BIN}" test "${TEST_FILES[@]}"
