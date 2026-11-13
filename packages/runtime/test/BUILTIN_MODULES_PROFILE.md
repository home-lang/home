# Builtin namespace discovery

`node:module.builtinModules` is a frozen snapshot of the Node namespaces
actually registered by Home. Names with an equivalent bare alias use that
alias; a namespace available only with `node:` retains its prefix. The export
property remains writable, enumerable and configurable, matching Node's
property shape. Replacing that property does not register modules or alter the
real loader. Bun namespaces are excluded.

This describes available namespaces, not completeness of every API inside
each namespace. Missing HTTP, HTTPS, TLS, workers and inspector modules remain
unadvertised and genuinely fail to load. This does not implement Bun's shell,
bundler or native addons. The upstream node-fallbacks builder still requires
those separate capabilities and must not receive passing build credit merely
because its initial builtin enumeration works.

Run `zig build home-tool-builtin-modules` for the maintained fixture, also
included in `home-tool-smoke`. Its CJS and ESM portions perform 42 and 7 checks,
including 30 existing namespace loads, actual resolution/alias identity,
descriptors, frozen mutation and replacement isolation. The Home profile
additionally loads every advertised namespace, verifies no filesystem cache
entries are forged, and executes the unsupported namespace refusals. The
common fixture runs on Node as a reference; other references retain their
actual failures instead of weakening the contract.
