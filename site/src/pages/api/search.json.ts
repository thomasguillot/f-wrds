import type { APIRoute } from 'astro';
import { createFromSource } from 'fumadocs-core/search/server';
import { source } from '../../lib/source';
import { withTrailingSlash } from '../../lib/links';

const server = createFromSource(source, {
  language: 'english',
  async buildIndex(page) {
    const { structuredData } = await page.data.load();
    const url = withTrailingSlash(page.url);
    return { title: page.data.title, description: page.data.description, url, id: url, structuredData };
  },
});

export const prerender = true;

export const GET: APIRoute = () => server.staticGET();
