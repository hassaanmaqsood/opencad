import { defineConfig } from 'vitepress';

export default defineConfig({
  title: 'OpenCAD',
  description: 'Merging B-Rep, CSG & Implicit Fields in One Math Core — CDML v1.0 & Zig/WASM CAD Kernel',
  base: '/opencad/',
  cleanUrls: true,
  ignoreDeadLinks: true,
  markdown: {
    math: true,
  },
  head: [
    ['script', {}, `if (typeof window !== 'undefined' && (location.pathname === '/opencad/' || location.pathname === '/opencad/index.html' || location.pathname === '/') && /(?:^|[?&])(?:embed|cdml|src|gui|vars|probes|exports|figure)=/.test(location.search)) { location.replace('/opencad/studio/' + location.search); }`],
    ['link', { rel: 'icon', type: 'image/svg+xml', href: '/opencad/brand/opencad-logo-fill.svg' }],
    ['link', { rel: 'preconnect', href: 'https://fonts.googleapis.com' }],
    ['link', { rel: 'preconnect', href: 'https://fonts.gstatic.com', crossorigin: '' }],
    ['link', { href: 'https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:ital,wght@0,300;0,400;0,500;0,600;0,700;1,400&display=swap', rel: 'stylesheet' }],
  ],
  themeConfig: {
    logo: '/brand/opencad-logo-fill.svg',
    siteTitle: 'OpenCAD',
    nav: [
      { text: 'Guide', link: '/guide/' },
      { text: 'Reference', link: '/reference/cdml-spec' },
      { text: 'Papers', link: '/papers/math-foundations' },
      { text: 'Collabs', link: '/collabs/feascript-thermal-loop' },
      { text: 'Brand', link: '/brand/' },
      { text: 'Studio ↗', link: '/studio/', target: '_self' },
    ],
    sidebar: {
      '/guide/': [
        {
          text: 'Guide & Tutorials',
          items: [
            { text: 'User Guide & Quickstart', link: '/guide/' },
            { text: 'System Architecture', link: '/guide/architecture' },
            { text: 'CDML Examples Catalog', link: '/examples/' },
            { text: 'Complex Examples', link: '/guide/complex-examples' },
          ],
        },
      ],
      '/examples/': [
        {
          text: 'Guide & Tutorials',
          items: [
            { text: 'User Guide & Quickstart', link: '/guide/' },
            { text: 'System Architecture', link: '/guide/architecture' },
            { text: 'CDML Examples Catalog', link: '/examples/' },
            { text: 'Complex Examples', link: '/guide/complex-examples' },
          ],
        },
      ],
      '/reference/': [
        {
          text: 'Specifications & API',
          items: [
            { text: 'CDML v1.0 Specification', link: '/reference/cdml-spec' },
            { text: 'Polyglot API Reference', link: '/reference/polyglot-api' },
            { text: 'LLM & Agent Authoring Skill', link: '/reference/skill' },
          ],
        },
      ],
      '/papers/': [
        {
          text: 'Mathematical Deep-Dives',
          items: [
            { text: 'Mathematical Foundations', link: '/papers/math-foundations' },
            { text: 'Merging B-Rep, CSG & Implicit Fields', link: '/papers/unified-math-article' },
          ],
        },
      ],
      '/collabs/': [
        {
          text: 'Multi-Physics Collaborations',
          items: [
            { text: 'FEAScript × OpenCAD Thermal Loop', link: '/collabs/feascript-thermal-loop' },
          ],
        },
      ],
      '/brand/': [
        {
          text: 'Design System & Brand',
          items: [
            { text: 'OpenCAD Design System', link: '/brand/' },
          ],
        },
      ],
    },
    socialLinks: [
      { icon: 'github', link: 'https://github.com/hassaanmaqsood/opencad' },
    ],
    search: {
      provider: 'local',
    },
    footer: {
      message: 'Released under the Apache-2.0 License.',
      copyright: 'OpenCAD — One Mathematical Core (B-Rep · CSG · Implicit)',
    },
  },
});
