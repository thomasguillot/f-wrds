import { defineConfig, fontProviders } from 'astro/config';
import sitemap from '@astrojs/sitemap';

export default defineConfig({
  site: 'https://fwrds.space.fast',
  output: 'static',
  integrations: [sitemap()],
  fonts: [
    {
      name: 'Clash Display',
      cssVariable: '--font-display',
      provider: fontProviders.fontshare(),
      weights: [600, 700],
      styles: ['normal'],
      subsets: ['latin'],
      fallbacks: ['General Sans', 'system-ui', 'sans-serif'],
    },
    {
      name: 'General Sans',
      cssVariable: '--font-body',
      provider: fontProviders.fontshare(),
      weights: [400, 500, 600, 700],
      styles: ['normal'],
      subsets: ['latin'],
      fallbacks: ['system-ui', 'sans-serif'],
    },
    {
      name: 'JetBrains Mono',
      cssVariable: '--font-mono',
      provider: fontProviders.fontsource(),
      weights: [400, 700],
      styles: ['normal'],
      subsets: ['latin'],
      fallbacks: ['ui-monospace', 'monospace'],
    },
    {
      name: 'Rock Salt',
      cssVariable: '--font-hand',
      provider: fontProviders.google(),
      weights: [400],
      styles: ['normal'],
      subsets: ['latin'],
      fallbacks: ['cursive'],
    },
  ],
});
