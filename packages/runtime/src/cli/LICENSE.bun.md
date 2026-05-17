# Bun source — MIT License

Source files in this directory and sibling subdirectories under
`packages/runtime/src/` originate from the Bun project
(https://github.com/oven-sh/bun) at upstream commit
`fd0b6f1a271fca0b8124b69f230b100f4d636af6` and are redistributed
under Bun's MIT license. Each copied file carries a header
referencing its upstream path and SHA. Imports are rewritten at
copy time (`@import("bun")` → `@import("home_rt")`).

Per user direction (2026-05-17), Home owns this copy as native
source — no submodule, no vendor directory. The Phase 12 plan
in `docs/TS_PARITY_PLAN.md` tracks the copy front edge and the
acceptance gate (Home must pass 100 % of Bun's test suite).

MIT License

Copyright (c) 2019-2025 Bun

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
