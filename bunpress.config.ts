import type { BunPressConfig } from 'bunpress'

export default {
  title: 'Home',
  description: 'A modern programming language for systems, apps, and games. The control of Zig, the safety of Rust, the joy of TypeScript.',
  lang: 'en-US',
  base: '/',

  head: [
    ['meta', { name: 'theme-color', content: '#5c6bc0' }],
    ['meta', { property: 'og:type', content: 'website' }],
    ['meta', { property: 'og:title', content: 'Home Programming Language' }],
    ['meta', { property: 'og:description', content: 'The JavaScript & TypeScript engine with real threads over a shared heap. No GIL. One binary.' }],
    ['meta', { property: 'og:url', content: 'https://docs.home-lang.org/' }],
    ['meta', { name: 'twitter:card', content: 'summary_large_image' }],
    ['meta', { name: 'twitter:title', content: 'Home Programming Language' }],
    ['meta', { name: 'twitter:description', content: 'Zig speed. Rust safety. TypeScript joy.' }],
  ],

  themeConfig: {
    siteTitle: 'Home',

    nav: [
      { text: 'Guide', link: '/guide/getting-started' },
      { text: 'Features', link: '/features/pattern-matching' },
      { text: 'Advanced', link: '/advanced/async' },
      { text: 'Reference', link: '/reference/stdlib' },
      {
        text: 'Parity',
        items: [
          { text: 'TypeScript', link: '/PARITY-TYPESCRIPT' },
          { text: 'Node.js', link: '/PARITY-NODE' },
          { text: 'Bun', link: '/PARITY-BUN' },
          { text: 'Capability Matrix', link: '/CAPABILITY_MATRIX' },
        ],
      },
      {
        text: 'Links',
        items: [
          { text: 'GitHub', link: 'https://github.com/home-lang/home' },
          { text: 'Engine (zig-js)', link: 'https://github.com/zig-utils/zig-js' },
          { text: 'Craft', link: 'https://github.com/home-lang/craft' },
          { text: 'Discord', link: 'https://discord.gg/home-lang' },
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
