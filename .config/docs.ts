import type { BunPressOptions } from '@stacksjs/bunpress'

const config: BunPressOptions = {
  verbose: true,

  docsDir: './docs',
  outDir: './dist/docs',

  theme: 'vitepress',

  markdown: {
    title: 'Home Programming Language',

    meta: {
      description: 'A modern programming language for systems, apps, and games. Combines the speed of Zig, the safety of Rust, and the joy of TypeScript.',
      author: 'Home Language Team',
      viewport: 'width=device-width, initial-scale=1.0',
    },

    toc: {
      enabled: true,
      position: ['sidebar'],
      title: 'On This Page',
      minDepth: 2,
      maxDepth: 4,
      smoothScroll: true,
      activeHighlight: true,
      collapsible: true,
    },

    syntaxHighlightTheme: 'github-dark',

    preserveDirectoryStructure: true,

    features: {
      inlineFormatting: true,
      containers: true,
      githubAlerts: true,
      codeBlocks: {
        lineHighlighting: true,
        lineNumbers: true,
        focus: true,
        diffs: true,
        errorWarningMarkers: true,
      },
      codeGroups: true,
      codeImports: true,
      inlineToc: true,
      customAnchors: true,
      emoji: true,
      badges: true,
      includes: true,
      externalLinks: {
        autoTarget: true,
        autoRel: true,
        showIcon: true,
      },
      imageLazyLoading: true,
      tables: {
        alignment: true,
        enhancedStyling: true,
        responsive: true,
      },
    },

    nav: [
      { text: 'Home', link: '/' },
      {
        text: 'Guide',
        activeMatch: '/guide',
        items: [
          { text: 'Getting Started', link: '/guide/getting-started' },
          { text: 'Variables & Types', link: '/guide/variables' },
          { text: 'Functions', link: '/guide/functions' },
          { text: 'Control Flow', link: '/guide/control-flow' },
          { text: 'Structs & Enums', link: '/guide/structs-enums' },
          { text: 'Error Handling', link: '/guide/error-handling' },
          { text: 'Memory Safety', link: '/guide/memory' },
          { text: 'Async Programming', link: '/guide/async' },
          { text: 'Compile-Time Evaluation', link: '/guide/comptime' },
          { text: 'Traits', link: '/guide/traits' },
        ],
      },
      {
        text: 'Reference',
        activeMatch: '/reference',
        items: [
          { text: 'Standard Library', link: '/reference/stdlib' },
        ],
      },
      {
        text: 'Ecosystem',
        items: [
          { text: 'HomeOS', link: 'https://github.com/home-lang/homeos' },
          { text: 'GitHub', link: 'https://github.com/home-lang/home' },
        ],
      },
    ],

    sidebar: {
      '/': [
        {
          text: 'Introduction',
          items: [
            { text: 'What is Home?', link: '/' },
            { text: 'Getting Started', link: '/guide/getting-started' },
          ],
        },
        {
          text: 'Language Basics',
          items: [
            { text: 'Variables & Types', link: '/guide/variables' },
            { text: 'Functions', link: '/guide/functions' },
            { text: 'Control Flow', link: '/guide/control-flow' },
          ],
        },
        {
          text: 'Features',
          items: [
            { text: 'Type System', link: '/features/type-system' },
            { text: 'Pattern Matching', link: '/features/pattern-matching' },
            { text: 'Generics', link: '/features/generics' },
            { text: 'Macros', link: '/features/macros' },
            { text: 'FFI', link: '/features/ffi' },
          ],
        },
        {
          text: 'Data Structures',
          items: [
            { text: 'Structs & Enums', link: '/guide/structs-enums' },
            { text: 'Traits', link: '/guide/traits' },
          ],
        },
        {
          text: 'Advanced',
          items: [
            { text: 'Error Handling', link: '/advanced/error-handling' },
            { text: 'Memory Safety', link: '/advanced/memory' },
            { text: 'Async Programming', link: '/advanced/async' },
            { text: 'Compile-Time Evaluation', link: '/advanced/comptime' },
            { text: 'Metaprogramming', link: '/advanced/metaprogramming' },
            { text: 'Performance Optimization', link: '/advanced/performance' },
          ],
        },
        {
          text: 'Reference',
          items: [
            { text: 'Standard Library', link: '/reference/stdlib' },
          ],
        },
        {
          text: 'Ecosystem',
          items: [
            { text: 'HomeOS', link: 'https://github.com/home-lang/homeos' },
          ],
        },
      ],
    },
  },

  sitemap: {
    enabled: true,
    baseUrl: 'https://home-lang.org/docs',
    filename: 'sitemap.xml',
    defaultPriority: 0.5,
    defaultChangefreq: 'monthly',
  },

  robots: {
    enabled: true,
    filename: 'robots.txt',
  },
}

export default config
