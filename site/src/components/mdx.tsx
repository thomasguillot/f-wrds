import defaultMdxComponents from 'fumadocs-ui/mdx';
import { DocsBody } from 'fumadocs-ui/layouts/glass/page';
import type { MDXComponents } from 'mdx/types';

export default {
  ...defaultMdxComponents,
  wrapper: DocsBody,
} satisfies MDXComponents;
