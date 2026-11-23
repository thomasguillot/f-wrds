import type { ComponentProps } from 'react';

export const withTrailingSlash = (href: string): string => {
  if (!href.startsWith('/')) return href;
  const cut = href.search(/[?#]/);
  const path = cut === -1 ? href : href.slice(0, cut);
  if (path.endsWith('/') || /\.[a-z0-9]+$/i.test(path)) return href;
  return `${path}/${cut === -1 ? '' : href.slice(cut)}`;
};

export const navigate = (url: string): void => {
  window.location.assign(withTrailingSlash(url));
};

export function SiteLink({ href = '', prefetch: _prefetch, ...props }: ComponentProps<'a'> & { prefetch?: boolean }) {
  return <a href={withTrailingSlash(href)} {...props} />;
}
