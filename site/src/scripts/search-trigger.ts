let loading: Promise<typeof import('./site-search')> | null = null;

const openSearch = (): void => {
  loading ??= import('./site-search');
  void loading.then((search) => search.open());
};

document.querySelectorAll<HTMLButtonElement>('[data-site-search]').forEach((button) => {
  button.addEventListener('click', openSearch);
});

document.addEventListener('keydown', (event) => {
  if (event.key.toLowerCase() !== 'k' || !(event.metaKey || event.ctrlKey) || event.altKey || event.shiftKey) return;
  event.preventDefault();
  openSearch();
});
