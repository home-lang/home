# Inspector null-key controls — 2026-10-13

The null-key/context-ID source (`311f18d42`) and subsequent draft bridge (`0d4df1f1f`) each completed a normal 56/56-step Debug build. Compilation does not establish runtime compatibility.

Six corrected Node controls passed. The pinned null-key Home executable passed enumeration/evaluation and metadata disable/re-enable. Its unchanged ordinary object control exited 1 with a JavaScript TypeError: JSC returned no CDP `result` property array. The earlier native abort did not recur in that control. Later Home controls were not executed after this failure.

Node rejects foreign-world remote-object arguments with -32000; the initial success expectation was incorrect. The corrected control also requires same-world success. Both versions are preserved. The pending repair (`6e08014c7`) rejects foreign-world arguments and translates the native property response using the request method. Its build and raw-response diagnostic were queued when this checkpoint was archived; this manifest gives them no runtime pass credit.

[Issue #888](https://github.com/home-lang/home/issues/888) tracks realm routing and lifetime. [Issue #428](https://github.com/home-lang/home/issues/428) tracks inspector acceptance. [Issue #66](https://github.com/home-lang/home/issues/66) remains the full Bun parity goal. Controller roots, retirement, asynchronous/backend behavior, broader unchanged originals, platforms, and full suite acceptance remain incomplete.

Each compressed artifact has its uncompressed byte count and SHA-256 in [the manifest](./manifest.json). The driver stops on failure and the result list records only controls that ran.
