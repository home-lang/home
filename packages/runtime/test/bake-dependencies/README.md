# Bake corpus dependencies

These manifests pin the third-party packages required by Bun's Bake tests. The
test sources remain a verbatim mirror of the pinned Bun corpus.

`base/package.json` provides packages imported directly by the tests and their
browser client. `react/package.json` pre-populates the React cache consumed by
the unchanged Bake harness. React experimental versions are exact because the
upstream harness otherwise resolves the moving `experimental` npm tags at run
time.

The checked-in npm lockfiles make dependency setup deterministic. npm is used
only to materialize third-party modules; the corpus itself executes exclusively
through Home.
