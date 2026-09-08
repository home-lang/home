#!/usr/bin/env bash
# Exercise the provisioning wrapper's integrity check without registry access.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/scripts" "$fixture/packages/runtime/test/test" \
    "$fixture/packages/runtime/upstream/packages/bun-plugin-svelte"
cp "$ROOT/scripts/provision-corpus-deps.sh" "$fixture/scripts/"
printf '{}\n' > "$fixture/packages/runtime/test/bun.lock"
printf '{}\n' > "$fixture/packages/runtime/test/test/bun.lock"
printf '{}\n' > "$fixture/packages/runtime/upstream/packages/bun-plugin-svelte/package.json"
git -C "$fixture" init --quiet
git -C "$fixture" add .
git -C "$fixture" -c user.name='Fixture' -c user.email='fixture@example.invalid' \
    -c core.hooksPath=/dev/null commit --quiet -m fixture

# A pre-existing unstaged change must not hide a further installer mutation.
printf '\n' >> "$fixture/packages/runtime/test/test/bun.lock"
cat > "$fixture/installer" <<'INSTALLER'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == install && "$2" == --cwd && "$4" == --frozen-lockfile ]]
mkdir -p "$3/node_modules/react" "$3/node_modules/bun-plugin-svelte"
printf '{}\n' > "$3/node_modules/react/package.json"
printf '{}\n' > "$3/node_modules/bun-plugin-svelte/package.json"
if [[ "${MUTATE_LOCK:-0}" == 1 && "$3" == */test/test ]]; then
    printf '\n' >> "$3/bun.lock"
fi
INSTALLER
chmod +x "$fixture/installer"
HOME_CORPUS_INSTALL_EXECUTABLE="$fixture/installer" \
    bash "$fixture/scripts/provision-corpus-deps.sh" > "$fixture/unchanged.log" 2>&1
if HOME_CORPUS_INSTALL_EXECUTABLE="$fixture/installer" MUTATE_LOCK=1 \
    bash "$fixture/scripts/provision-corpus-deps.sh" > "$fixture/mutated.log" 2>&1; then
    echo 'FAIL: provisioning accepted an installer mutation of an already-dirty lockfile' >&2
    exit 1
fi
if ! rg -q 'a pinned bun.lock changed during provisioning' "$fixture/mutated.log"; then
    cat "$fixture/mutated.log" >&2
    exit 1
fi
echo 'provisioning lock integrity controls passed (unchanged accepted, mutation rejected)'
