import type { BunPressConfig } from '@stacksjs/bunpress'
import homeCss from './.config/docs.css' with { type: 'text' }

/** Inline glyphs for the mega menu. One stroke weight, one 24x24 box. */
const icon = (path: string): string =>
  `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">${path}</svg>`

const icons = {
  match: icon('<path d="M4 7h5l3 5 3-5h5M4 17h5l3-5"/>'),
  types: icon('<path d="M4 6h16M12 6v12M8 18h8"/>'),
  generics: icon('<path d="M9 5L4 12l5 7M15 5l5 7-5 7"/>'),
  traits: icon('<circle cx="8" cy="8" r="4"/><circle cx="16" cy="16" r="4"/><path d="M11 11l2 2"/>'),
  errors: icon('<path d="M12 8v5M12 16h.01"/><circle cx="12" cy="12" r="9"/>'),
  memory: icon('<rect x="4" y="7" width="16" height="10" rx="2"/><path d="M8 7V5M12 7V5M16 7V5M8 19v-2M12 19v-2M16 19v-2"/>'),
  comptime: icon('<circle cx="12" cy="12" r="8"/><path d="M12 8v4l3 2"/>'),
  async: icon('<path d="M4 12a8 8 0 0 1 8-8 8 8 0 0 1 7 4"/><path d="M20 12a8 8 0 0 1-8 8 8 8 0 0 1-7-4"/><path d="M19 4v4h-4M5 20v-4h4"/>'),
  ffi: icon('<path d="M10 13a5 5 0 0 0 7 0l3-3a5 5 0 0 0-7-7l-1 1"/><path d="M14 11a5 5 0 0 0-7 0l-3 3a5 5 0 0 0 7 7l1-1"/>'),
  tsc: icon('<path d="M4 5h16v14H4z"/><path d="M8 10h4M10 10v5M14 15h3v-5h-3"/>'),
  macros: icon('<path d="M12 3l2.5 5.5L20 11l-5.5 2.5L12 19l-2.5-5.5L4 11l5.5-2.5z"/>'),
  tooling: icon('<path d="M14 7a4 4 0 0 1-5 5l-5 5 3 3 5-5a4 4 0 0 1 5-5z"/><path d="M15 4l5 5"/>'),
  systems: icon('<rect x="3" y="4" width="18" height="12" rx="2"/><path d="M8 20h8M12 16v4"/>'),
  games: icon('<rect x="2" y="7" width="20" height="10" rx="4"/><path d="M7 11v2M6 12h2M16 11h.01M18 13h.01"/>'),
  os: icon('<path d="M4 4h16v16H4z"/><path d="M4 9h16M9 9v11"/>'),
  web: icon('<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3a15 15 0 0 1 0 18 15 15 0 0 1 0-18"/>'),
  cli: icon('<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M7 9l3 3-3 3M13 15h4"/>'),
  migrate: icon('<path d="M4 8h12l-3-3M20 16H8l3 3"/>'),
}

export default {
  title: 'Home',
  description: 'A modern programming language for systems, apps, and games. The control of Zig, the safety of Rust, the joy of TypeScript.',
  lang: 'en-US',
  base: '/',

  head: [
    ['meta', { name: 'theme-color', content: '#c2410c' }],
    ['meta', { property: 'og:type', content: 'website' }],
    ['meta', { property: 'og:title', content: 'Home Programming Language' }],
    ['meta', { property: 'og:description', content: 'The control of Zig, the safety of Rust, the joy of TypeScript. One compiler for Home and TypeScript.' }],
    ['meta', { property: 'og:url', content: 'https://docs.home-lang.org/' }],
    ['meta', { name: 'twitter:card', content: 'summary_large_image' }],
    ['meta', { name: 'twitter:title', content: 'Home Programming Language' }],
    ['meta', { name: 'twitter:description', content: 'Zig speed. Rust safety. TypeScript joy.' }],
  ],

  markdown: {
    // Home has no grammar in the highlighter yet. Rust is the closest fit for
    // its fn/struct/enum/match surface, so ```home fences get real tokens
    // instead of flat escaped text while keeping their own name.
    languageAliases: {
      home: 'rust',
      hm: 'rust',
    },
  },

  themeConfig: {
    siteTitle: 'Home',
    css: homeCss,

    nav: [
      {
        text: 'Features',
        activeMatch: '^/(features|advanced)/',
        columns: 3,
        footer: {
          note: 'Every language, codegen and tooling row, with status.',
          text: 'Capability matrix',
          link: '/CAPABILITY_MATRIX',
        },
        items: [
          {
            text: 'Language',
            items: [
              { text: 'Pattern Matching', link: '/features/pattern-matching', icon: icons.match, description: 'Exhaustive match with guards and destructuring.' },
              { text: 'Type System', link: '/features/type-system', icon: icons.types, description: 'Inference, unions, null safety, Result types.' },
              { text: 'Generics', link: '/features/generics', icon: icons.generics, description: 'Monomorphized generics with trait bounds.' },
              { text: 'Traits', link: '/guide/traits', icon: icons.traits, description: 'Shared behaviour without inheritance.' },
              { text: 'Error Handling', link: '/advanced/error-handling', icon: icons.errors, description: 'Errors as values, propagated with try.' },
            ],
          },
          {
            text: 'Systems',
            items: [
              { text: 'Memory Model', link: '/advanced/memory', icon: icons.memory, description: 'Ownership and borrowing, no collector.' },
              { text: 'Comptime', link: '/advanced/comptime', icon: icons.comptime, description: 'Run real code during compilation.' },
              { text: 'Concurrency', link: '/advanced/async', icon: icons.async, description: 'Async, await, channels and tasks.' },
              { text: 'FFI', link: '/features/ffi', icon: icons.ffi, description: 'Call C without a binding generator.' },
            ],
          },
          {
            text: 'Toolchain',
            items: [
              { text: 'TypeScript Compiler', link: '/features/typescript', icon: icons.tsc, description: 'home tsc checks and emits TypeScript.' },
              { text: 'Macros', link: '/features/macros', icon: icons.macros, description: 'Hygienic macros over the real AST.' },
              { text: 'Editor & CLI Tooling', link: '/features/tooling', icon: icons.tooling, description: 'LSP, formatter, test runner, package manager.' },
            ],
          },
        ],
      },
      {
        text: 'Use Cases',
        activeMatch: '^/use-cases/',
        columns: 2,
        items: [
          {
            text: 'Build with Home',
            items: [
              { text: 'Systems Programming', link: '/use-cases/systems', icon: icons.systems, description: 'Native binaries with predictable latency.' },
              { text: 'Game Development', link: '/use-cases/games', icon: icons.games, description: 'Frame budgets without collector pauses.' },
              { text: 'Operating Systems', link: '/use-cases/operating-systems', icon: icons.os, description: 'Freestanding builds, no runtime required.' },
            ],
          },
          {
            text: 'Ship with the toolchain',
            items: [
              { text: 'Web Services', link: '/use-cases/web-services', icon: icons.web, description: 'HTTP servers and databases in one binary.' },
              { text: 'CLI Tools', link: '/use-cases/cli-tools', icon: icons.cli, description: 'Single-file distribution, fast start.' },
              { text: 'TypeScript Migration', link: '/use-cases/typescript-migration', icon: icons.migrate, description: 'Type-check today, move code when ready.' },
            ],
          },
        ],
      },
      { text: 'Guide', link: '/guide/getting-started', activeMatch: '^/guide/' },
      {
        text: 'Reference',
        items: [
          { text: 'Standard Library', link: '/reference/stdlib' },
          { text: 'Architecture', link: '/ARCHITECTURE' },
          { text: 'Compiler Pipeline', link: '/COMPILER_PIPELINE' },
          { text: 'Configuration', link: '/CONFIGURATION' },
          { text: 'DX Commands', link: '/DX_COMMANDS' },
          { text: 'Package Management', link: '/PACKAGE-MANAGEMENT' },
        ],
      },
      {
        text: 'Parity',
        items: [
          { text: 'Capability Matrix', link: '/CAPABILITY_MATRIX' },
          { text: 'TypeScript', link: '/PARITY-TYPESCRIPT' },
          { text: 'Node.js', link: '/PARITY-NODE' },
          { text: 'Bun', link: '/PARITY-BUN' },
          { text: 'Roadmap', link: '/ROADMAP-WEB-COMPETITIVE' },
        ],
      },
    ],

    sidebar: [
      {
        text: 'Guide',
        items: [
          { text: 'Getting Started', link: '/guide/getting-started' },
          { text: 'Variables', link: '/guide/variables' },
          { text: 'Control Flow', link: '/guide/control-flow' },
          { text: 'Functions', link: '/guide/functions' },
          { text: 'Structs & Enums', link: '/guide/structs-enums' },
          { text: 'Traits', link: '/guide/traits' },
        ],
      },
      {
        text: 'Features',
        items: [
          { text: 'Pattern Matching', link: '/features/pattern-matching' },
          { text: 'Type System', link: '/features/type-system' },
          { text: 'Generics', link: '/features/generics' },
          { text: 'Macros', link: '/features/macros' },
          { text: 'FFI', link: '/features/ffi' },
          { text: 'TypeScript Compiler', link: '/features/typescript' },
          { text: 'Editor & CLI Tooling', link: '/features/tooling' },
        ],
      },
      {
        text: 'Use Cases',
        items: [
          { text: 'Systems Programming', link: '/use-cases/systems' },
          { text: 'Game Development', link: '/use-cases/games' },
          { text: 'Operating Systems', link: '/use-cases/operating-systems' },
          { text: 'Web Services', link: '/use-cases/web-services' },
          { text: 'CLI Tools', link: '/use-cases/cli-tools' },
          { text: 'TypeScript Migration', link: '/use-cases/typescript-migration' },
        ],
      },
      {
        text: 'Advanced',
        items: [
          { text: 'Async', link: '/advanced/async' },
          { text: 'Comptime', link: '/advanced/comptime' },
          { text: 'Error Handling', link: '/advanced/error-handling' },
          { text: 'Memory', link: '/advanced/memory' },
          { text: 'Metaprogramming', link: '/advanced/metaprogramming' },
          { text: 'Performance', link: '/advanced/performance' },
        ],
      },
      {
        text: 'Reference',
        items: [
          { text: 'Standard Library', link: '/reference/stdlib' },
          { text: 'Architecture', link: '/ARCHITECTURE' },
          { text: 'Compiler Pipeline', link: '/COMPILER_PIPELINE' },
          { text: 'Configuration', link: '/CONFIGURATION' },
          { text: 'DX Commands', link: '/DX_COMMANDS' },
          { text: 'Package Management', link: '/PACKAGE-MANAGEMENT' },
        ],
      },
      {
        text: 'Parity & Status',
        items: [
          { text: 'Capability Matrix', link: '/CAPABILITY_MATRIX' },
          { text: 'TypeScript', link: '/PARITY-TYPESCRIPT' },
          { text: 'Node.js', link: '/PARITY-NODE' },
          { text: 'Bun', link: '/PARITY-BUN' },
          { text: 'Bun Compat Shim', link: '/PARITY-BUN-COMPAT' },
          { text: 'Roadmap', link: '/ROADMAP-WEB-COMPETITIVE' },
        ],
      },
    ],

    socialLinks: [
      { icon: 'github', link: 'https://github.com/home-lang/home' },
      { icon: 'discord', link: 'https://discord.gg/home-lang' },
    ],

    footer: {
      message: 'Released under the MIT License.',
      copyright: 'Copyright © 2026 Home Programming Language',
    },

    editLink: {
      pattern: 'https://github.com/home-lang/home/edit/main/docs/:path',
      text: 'Edit this page on GitHub',
    },

    search: {
      provider: 'local',
    },
  },
} satisfies BunPressConfig
