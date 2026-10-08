# Native competitor profiles

The optional JSON registry adds compilers without replacing TypeScript 6,
native TypeScript 7, or Home. Commands are argument vectors, not shell scripts.
Paths resolve against the profile file. Every profile requires an exact Git
revision, executable SHA-256, complete payload-directory inventory pin, version
probe of that same executable, and explicit positive-output policy.

The [Darwin ARM64 profile](darwin-arm64.json) uses these verified upstreams:

| Compiler | Source revision | Native mode |
|---|---|---|
| [Rust tsc-rs v0.1.0](https://github.com/pingdotgg/ts-rust/releases/tag/v0.1.0) | `72b339e412f2560549033cea8db337b1bd44c312` | `tsc --noEmit -p` |
| [Bun canary](https://github.com/oven-sh/bun/commit/bd599f5af912512b83bba0ef387d1ba3a7d5e550) | `bd599f5af912512b83bba0ef387d1ba3a7d5e550` | `bun check --no-pretty --all --noEmit -p` |

Place the unmodified Rust executable and every adjacent lib file in
`bench/vs_tsgo/.tools/extras/tsc_rs/`, and the Bun executable in
`bench/vs_tsgo/.tools/extras/bun_canary/`. Both directories are ignored build
inputs. The registry rejects missing, added, or changed payload files. Its
inventory digest is SHA-256 of canonical JSON mapping every relative filename
to its byte size and SHA-256, sorted by filename with compact separators.

Verified release archive SHA-256 values:

- Rust Darwin ARM64 v0.1.0: `96920e12262ebe390dfa4876c3cf8ed03aa594ce99222a00e0f1517e945ba205`.
- Bun canary Darwin ARM64 archive containing the pinned revision:
  `87f2d32f3189c67781e0cf81dac6ad91c014798317b078b2e0dbc3cba8c4bd09`.

The Bun `canary` download label moves. A newer download is not this pin:
archive, executable, payload, and revision must all match before measurement.
Do not replace the expected hashes just to make a changed compiler run.

The source-pinned OnlySpecs C++ candidate is not registered: its unmodified
`8fd72a2a` CLI accepts all eight existing negative-control projects silently
with exit 0. Positive acceptance alone cannot establish equivalent checking.
The [complete admission report](../../../docs/docs/TS_PERFORMANCE.md#cpp-admission-and-current-source-profile-2026-10-08-utc)
retains the failures and exact inputs. No C++ timing or canonical-upstream
selection is claimed.

```sh
./bench/vs_tsgo/run.sh setup
./bench/vs_tsgo/run.sh corpus
./bench/vs_tsgo/run.sh cold --runs 30 --warmup 3 \
  --competitor-manifest bench/vs_tsgo/profiles/darwin-arm64.json
./bench/vs_tsgo/run.sh report
./bench/vs_tsgo/run.sh evidence
```

`silent` requires completely empty output from a successful positive check.
`checked-files` requires exactly one complete zero-error status line with a
nonzero file count, on one stream only. It does not discard diagnostics or
unknown notes. Both policies retain original output, and negative controls
always require the same exact diagnostic-code multisets and normal exits.

Run from a directory without a package `check` script when using the Bun
profile: that name can otherwise dispatch a package script. Project context
is fingerprinted, and the admission controls must still pass. The canonical
command was also checked with a valid top-level throw to establish that project
type checking does not execute the source program.

Every added compiler is measured in every round; a failed admission prevents
all timing. Raw admission commands, exits, stdout, and stderr are retained and
verified again when reporting and packaging. Published admission records
normalize only known private path prefixes; diagnostic messages and all
measurement samples remain present. Candidate admission is not a speed claim.
