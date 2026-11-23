import type { ReactNode } from 'react';
import { type SerializedPageTree, useFumadocsLoader } from 'fumadocs-core/source/client';
import type { TOCItemType } from 'fumadocs-core/toc';
import { RootProvider } from 'fumadocs-ui/provider/astro';
import { DocsLayout } from 'fumadocs-ui/layouts/glass';
import { DocsDescription, DocsPage, DocsTitle } from 'fumadocs-ui/layouts/glass/page';
import DocsSearch from './Search';

interface DocsProps {
  pathname: string;
  params: Record<string, string | undefined>;
  tree: SerializedPageTree;
  title: string;
  description?: string;
  toc: TOCItemType[];
  children?: ReactNode;
}

export function Docs({ pathname, params, tree, title, description, toc, children }: DocsProps) {
  const data = useFumadocsLoader({ tree });

  return (
    <RootProvider
      pathname={pathname}
      params={params}
      theme={{ enabled: false, hotKey: false }}
      search={{ SearchDialog: DocsSearch }}
    >
      <DocsLayout tree={data.tree} nav={{ title: 'Docs', url: '/docs' }} themeSwitch={{ enabled: false }}>
        <DocsPage toc={toc}>
          <DocsTitle>{title}</DocsTitle>
          <DocsDescription>{description}</DocsDescription>
          {children}
        </DocsPage>
      </DocsLayout>
    </RootProvider>
  );
}
