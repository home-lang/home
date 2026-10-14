# Owned HTTPS controls

These localhost test credentials retain Home’s renewed fixtures from `f0327d43445cd8ec7ed4ce3c4488940daf82cc8c`. The leaf is valid from August 25, 2026 through August 1, 2126. They support maintained HTTPS/ALPN/resource-timing controls independently of the pinned Bun corpus.

The pinned Bun leaf in `packages/runtime/test/test/js/node/http/fixtures` expired August 25, 2026. The Bun Git pin preserves its original bytes. Home’s imported corpus retains the adopted #710 revision, declared in `packages/runtime/test/HOME_FIXTURE_REVISIONS.json`. A passing maintained control with these owned fixtures does not establish that unchanged originals using the expired leaf pass.
