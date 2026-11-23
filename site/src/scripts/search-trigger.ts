type SearchModule = typeof import('./site-search');

const isMac = /Mac|iPhone|iPad/.test(navigator.userAgent);
let loading: Promise<SearchModule> | null = null;

const withSearch = (action: (search: SearchModule) => void): void => {
  loading ??= import('./site-search');
  loading.then(action).catch(() => {
    loading = null;
    window.location.assign('/docs/');
  });
};

document.querySelectorAll<HTMLButtonElement>('[data-site-search]').forEach((button) => {
  button.addEventListener('click', () => withSearch((search) => search.open()));
});

document.addEventListener('keydown', (event) => {
  if (event.isComposing || event.key.toLowerCase() !== 'k' || event.altKey || event.shiftKey) return;
  if (isMac ? !event.metaKey || event.ctrlKey : !event.ctrlKey || event.metaKey) return;
  event.preventDefault();
  withSearch((search) => search.toggle());
});
