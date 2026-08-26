---
layout: home
title: Home Programming Language
description: A systems language with native binaries, no garbage collector, and a toolchain that also type-checks and builds your TypeScript.
hero:
  text: Systems code that reads like TypeScript
  tagline: Native binaries with no garbage collector. The same toolchain type-checks and builds the TypeScript you already have.
  announcement:
    tag: Parity
    text: See how Home measures against tsc, Node and Bun
    link: /docs/CAPABILITY_MATRIX
  actions:
    - theme: brand
      text: Get started
      link: /docs/guide/getting-started
    - theme: alt
      text: GitHub
      link: https://github.com/home-lang/home
  code:
    - file: users.home
      lang: home
      content: |
        struct User {
          id: int,
          name: string,
        }

        async fn users(): Result<[]User, Error> {
          let res = await http.get("/api/users")?
          return await res.json()
        }

        async fn main() {
          match await users() {
            Ok(list) => print("{list.len()} users"),
            Err(e) => print("failed: {e}"),
          }
        }
    - file: server.ts
      lang: ts
      content: |
        // Plain TypeScript, run by the same binary.
        import { readFile } from 'node:fs/promises'

        interface Config {
          host: string
          port: number
        }

        const raw = await readFile('home.json', 'utf8')
        const config: Config = JSON.parse(raw)

        console.log(`${config.host}:${config.port}`)
    - file: terminal
      lang: bash
      content: |
        # A native binary, with no runtime beside it
        home build src/main.home -o app

        # The same compiler checks your TypeScript
        home tsc --noEmit

        # And runs it on Home's own JS runtime
        home run server.ts
features:
  - title: One compiler, two languages
    span: 2
    icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M4 5h16v14H4z"/><path d="M8 10h4M10 10v5M14 15h3v-5h-3"/></svg>'
    details: Home compiles Home. It also parses, type-checks and emits TypeScript, so a mixed codebase needs one toolchain instead of two.
    link: /docs/features/typescript
    linkText: How the TypeScript path works
  - title: Every case, or it does not compile
    icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M4 7h5l3 5 3-5h5M4 17h5l3-5"/></svg>'
    details: Exhaustive match over enums, tuples and ranges, with guards and bindings. A missing branch is a compile error, not a runtime surprise.
    link: /docs/features/pattern-matching
    linkText: See pattern matching
  - title: Memory without a collector
    icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="7" width="16" height="10" rx="2"/><path d="M8 7V5M12 7V5M16 7V5M8 19v-2M12 19v-2M16 19v-2"/></svg>'
    details: Ownership and borrowing settle lifetimes at compile time. No pauses, no hand-rolled arenas, no runtime to ship beside the binary.
    link: /docs/advanced/memory
    linkText: See the memory model
  - title: Compile time is just code
    span: 2
    icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="8"/><path d="M12 8v4l3 2"/></svg>'
    details: Comptime runs real Home during compilation. Build lookup tables, specialise generics and validate configuration before the binary exists.
    link: /docs/advanced/comptime
    linkText: See comptime
  - title: A Bun and Node compatible runtime, in progress
    span: 3
    icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3l8 4.5v9L12 21l-8-4.5v-9z"/><path d="M12 12l8-4.5M12 12v9M12 12L4 7.5"/></svg>'
    details: JavaScript runs through Home's own JavaScriptCore realm rather than a bundled Node. 24 of 47 node modules are callable today, alongside a broad Bun API surface, and the work is tracked module by module in the open.
    link: /docs/PARITY-BUN
    linkText: Follow the runtime port
---

<div class="hl">

<section class="hl-metrics">
  <div class="hl-metrics-grid">
    <div>
      <span class="hl-metric-value">5,907 / 5,907</span>
      <span class="hl-metric-label">TypeScript conformance corpus, coarse mode</span>
    </div>
    <div>
      <span class="hl-metric-value">24 / 47</span>
      <span class="hl-metric-label">node modules callable on Home's own runtime</span>
    </div>
    <div>
      <span class="hl-metric-value">76 / ~80</span>
      <span class="hl-metric-label">Language-server methods routed</span>
    </div>
    <div>
      <span class="hl-metric-value">~8,415</span>
      <span class="hl-metric-label">Tests in the compiler suite</span>
    </div>
  </div>
  <p class="hl-metrics-note">Every figure is a file-count or row-count measurement against an external baseline, refreshed 2026-07-13. <a href="/docs/PARITY-TYPESCRIPT">Read how each one is produced</a>.</p>
</section>

<section class="hl-band">
  <div class="hl-band-grid">
    <div>
      <h2 class="hl-title">Your TypeScript already compiles here</h2>
      <p class="hl-lead">Home did not stop at a new language. The same binary that builds <code>.home</code> files runs a full TypeScript front end, checked against the upstream conformance corpus rather than against our own tests.</p>
      <ul class="hl-band-points">
        <li><strong>Byte-for-byte diagnostics.</strong> Errors are compared against baselines generated by the reference compiler, not approximated.</li>
        <li><strong>One command, one config.</strong> <code>home tsc</code> reads the <code>tsconfig.json</code> you already have.</li>
        <li><strong>Editors keep working.</strong> <code>home lsp --stdio</code> speaks the protocol your editor already speaks.</li>
      </ul>
    </div>
    <div class="hl-code">
      <div class="hl-code-head">migrating an existing project</div>

```bash
# Point the Home compiler at the project you already have
cd my-typescript-app
home tsc --noEmit

# Same diagnostics, same codes, same exit status
# error TS2345: Argument of type 'string' is not
# assignable to parameter of type 'number'.

# Explain any code without leaving the terminal
home explain TS2345
```

  </div>
  </div>
</section>

<section class="hl-section">
  <div class="hl-inner">
    <h2 class="hl-title">What people build with it</h2>
    <p class="hl-lead">Home targets the places where a runtime is a liability: fixed frame budgets, freestanding binaries, and services that have to start instantly.</p>
    <div class="hl-cases">
      <a class="hl-case" href="/docs/use-cases/systems">
        <span class="hl-case-icon" aria-hidden="true"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="12" rx="2"/><path d="M8 20h8M12 16v4"/></svg></span>
        <span>
          <span class="hl-case-title">Systems programming</span>
          <span class="hl-case-text">Native binaries with predictable latency and direct access to the machine.</span>
        </span>
      </a>
      <a class="hl-case" href="/docs/use-cases/games">
        <span class="hl-case-icon" aria-hidden="true"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="7" width="20" height="10" rx="4"/><path d="M7 11v2M6 12h2M16 11h.01M18 13h.01"/></svg></span>
        <span>
          <span class="hl-case-title">Game development</span>
          <span class="hl-case-text">A 16ms budget survives when nothing decides to collect garbage mid-frame.</span>
        </span>
      </a>
      <a class="hl-case" href="/docs/use-cases/web-services">
        <span class="hl-case-icon" aria-hidden="true"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3a15 15 0 0 1 0 18 15 15 0 0 1 0-18"/></svg></span>
        <span>
          <span class="hl-case-title">Web services</span>
          <span class="hl-case-text">HTTP routing, database access and JSON in the standard library, in one binary.</span>
        </span>
      </a>
      <a class="hl-case" href="/docs/use-cases/cli-tools">
        <span class="hl-case-icon" aria-hidden="true"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="16" rx="2"/><path d="M7 9l3 3-3 3M13 15h4"/></svg></span>
        <span>
          <span class="hl-case-title">CLI tools</span>
          <span class="hl-case-text">One file to ship, no interpreter to install, and start-up you can measure in microseconds.</span>
        </span>
      </a>
      <a class="hl-case" href="/docs/use-cases/operating-systems">
        <span class="hl-case-icon" aria-hidden="true"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M4 4h16v16H4z"/><path d="M4 9h16M9 9v11"/></svg></span>
        <span>
          <span class="hl-case-title">Operating systems</span>
          <span class="hl-case-text">Freestanding builds with no allocator and no runtime assumed underneath.</span>
        </span>
      </a>
      <a class="hl-case" href="/docs/use-cases/typescript-migration">
        <span class="hl-case-icon" aria-hidden="true"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M4 8h12l-3-3M20 16H8l3 3"/></svg></span>
        <span>
          <span class="hl-case-title">TypeScript migration</span>
          <span class="hl-case-text">Type-check the code you have today, move the hot paths to Home when you are ready.</span>
        </span>
      </a>
    </div>
  </div>
</section>

<section class="hl-section">
  <div class="hl-inner">
    <h2 class="hl-title">From clone to binary</h2>
    <p class="hl-lead">Home builds itself with a Pantry-pinned Zig toolchain, so the setup is two commands and no global installs.</p>
    <div class="hl-steps">
      <div class="hl-step">
        <div>
          <div class="hl-step-head">
            <span class="hl-step-index">01</span>
            <h3 class="hl-step-title">Install the toolchain</h3>
          </div>
          <p class="hl-step-text">Pantry pins the exact Zig version the compiler is built against, inside the project.</p>
        </div>
        <div class="hl-code">

```bash
git clone https://github.com/home-lang/home.git
cd home && pantry install
./pantry/.bin/zig build
```

  </div>
      </div>
      <div class="hl-step">
        <div>
          <div class="hl-step-head">
            <span class="hl-step-index">02</span>
            <h3 class="hl-step-title">Write a program</h3>
          </div>
          <p class="hl-step-text">Functions, types and string interpolation behave the way you would guess.</p>
        </div>
        <div class="hl-code">

```home
// hello.home
fn main() {
  let name = "Home"
  print("Hello, {name}!")
}
```

  </div>
      </div>
      <div class="hl-step">
        <div>
          <div class="hl-step-head">
            <span class="hl-step-index">03</span>
            <h3 class="hl-step-title">Build and run it</h3>
          </div>
          <p class="hl-step-text">The output is a native executable with nothing to install alongside it.</p>
        </div>
        <div class="hl-code">

```bash
./zig-out/bin/home build hello.home
./hello
# Hello, Home!
```

  </div>
      </div>
    </div>
  </div>
</section>

<section class="hl-section">
  <div class="hl-inner">
    <h2 class="hl-title">Where Home actually is</h2>
    <p class="hl-lead">The compiler is under active development and the docs say so on every page. Here is the short version, so you can decide what to trust it with.</p>
    <div class="hl-status">
      <div class="hl-status-row">
        <span class="hl-status-name">Lexer, parser, type inference</span>
        <span class="hl-pill is-ready">Usable today</span>
        <span class="hl-status-note">The front end handles the whole documented language surface and is regression-gated on every change.</span>
      </div>
      <div class="hl-status-row">
        <span class="hl-status-name">TypeScript checking</span>
        <span class="hl-pill is-ready">Usable today</span>
        <span class="hl-status-note">Coarse and byte-for-byte exact conformance are saturated at 5,907 of 5,907 cases against the pinned tsgo baselines.</span>
      </div>
      <div class="hl-status-row">
        <span class="hl-status-name">Native code generation</span>
        <span class="hl-pill is-progress">Maturing</span>
        <span class="hl-status-note">Single-entrypoint native builds work through LLVM. Bundling the full module graph and cross-target builds are in progress.</span>
      </div>
      <div class="hl-status-row">
        <span class="hl-status-name">Bun-compatible runtime</span>
        <span class="hl-pill is-progress">Maturing</span>
        <span class="hl-status-note">JavaScript runs through Home's own JavaScriptCore realm, with 24 node modules callable so far.</span>
      </div>
    </div>
    <a class="hl-status-link" href="/docs/CAPABILITY_MATRIX">Read the full capability matrix</a>
  </div>
</section>

<section class="hl-close">
  <h2 class="hl-title">Try it on something small</h2>
  <p class="hl-lead">A CLI tool, a parser, one service. Half an hour is enough to know whether the language fits your head.</p>
  <div class="hl-close-actions">
    <a class="BPButton BPButton-brand" href="/docs/guide/getting-started">Get started</a>
    <a class="BPButton BPButton-alt" href="/docs/features/typescript">Read the TypeScript story</a>
  </div>
</section>

</div>
