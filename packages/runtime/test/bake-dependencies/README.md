# Bake corpus dependencies

These manifests pin the third-party packages required by Bun's Bake tests. The
test sources remain a verbatim mirror of the pinned Bun corpus.

`base/package.json` provides packages imported directly by the tests and their
browser client. `react/package.json` pre-populates the React cache consumed by
the unchanged Bake harness. React experimental versions are exact because the
upstream harness otherwise resolves the moving `experimental` npm tags at run
time.

The checked-in npm locks make third-party materialization deterministic. The
checked-in Bun locks are genuine Home-generated migrations of those same
manifests and npm locks, not placeholder cache markers. The runner validates
them with Home's frozen lockfile mode and copies the real React lock into the
upstream harness cache. npm only materializes modules; Home executes all tests
and child servers, with Node used for the upstream browser simulator.

The runner retains a native suite journal outside its temporary overlay and
requires independent report validation. It verifies all selected source bytes
through the corpus integrity audit and does not alter upstream assertions,
fixtures, workloads or individual test deadlines.
