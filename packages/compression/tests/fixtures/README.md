# Interoperability fixtures

`text.txt`, `binary.bin` and `empty.bin` are generated inputs (seeded random words and bytes). The
compressed files were written from them by the reference tools:

| Files | Command |
|---|---|
| `*.q0.br`, `*.q5.br`, `*.q11.br` | `brotli -q 0 / 5 / 11` (brotli 1.2.0) |
| `*.w10.br` | `brotli -q 9 -w 10` |
| `*.1.zst`, `*.19.zst` | `zstd -1 / -19` (zstd 1.5.7, content checksum on) |
| `*.nocheck.zst` | `zstd -3 --no-check` |
| `multi.zst` | `zstd text.txt` and `zstd binary.bin`, concatenated |
| `*.lz4` | `lz4` (lz4 1.11.1: independent blocks, content checksum) |
| `*.hc-linked.lz4` | `lz4 -9 -BD -BX --content-size` (linked blocks, block checksums) |
| `*.legacy.lz4` | `lz4 -l` (legacy frame format) |

`zig build test` decodes every one of them; `zig build interop` checks the other direction by
piping this package's output through `zstd -d`, `lz4 -d` and `brotli -d`.
