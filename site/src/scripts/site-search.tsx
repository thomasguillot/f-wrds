import { useSyncExternalStore } from 'react';
import { createRoot } from 'react-dom/client';
import { Dialog } from '@base-ui/react/dialog';
import { RootProvider } from 'fumadocs-ui/provider/astro';
import DocsSearch from '../components/docs/Search';
import { SiteLink, navigate } from '../lib/links';
import stylesheet from '../styles/search.css?url';

const dialogHandle = Dialog.createHandle();
let isOpen = false;
const listeners = new Set<() => void>();

const setOpen = (next: boolean): void => {
  isOpen = next;
  listeners.forEach((listener) => listener());
};

const subscribe = (listener: () => void): (() => void) => {
  listeners.add(listener);
  return () => listeners.delete(listener);
};

function SiteSearch() {
  const open = useSyncExternalStore(subscribe, () => isOpen);

  return (
    <RootProvider
      pathname={window.location.pathname}
      navigate={navigate}
      components={{ Link: SiteLink }}
      theme={{ enabled: false }}
      search={{ enabled: false }}
    >
      <DocsSearch open={open} onOpenChange={setOpen} dialogHandle={dialogHandle} />
    </RootProvider>
  );
}

const loadStylesheet = (): Promise<void> =>
  new Promise((resolve) => {
    const link = document.createElement('link');
    link.rel = 'stylesheet';
    link.href = stylesheet;
    link.onload = () => resolve();
    link.onerror = () => resolve();
    document.head.append(link);
  });

let ready: Promise<void> | null = null;

const mount = async (): Promise<void> => {
  if (!document.documentElement.classList.contains('docs')) await loadStylesheet();
  const host = document.createElement('div');
  document.body.append(host);
  createRoot(host).render(<SiteSearch />);
};

export const open = async (): Promise<void> => {
  ready ??= mount();
  await ready;
  setOpen(true);
};

export const toggle = (): Promise<void> | void => (isOpen ? setOpen(false) : open());
