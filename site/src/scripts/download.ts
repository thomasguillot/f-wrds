const RELEASES_API = 'https://api.github.com/repos/thomasguillot/f-wrds/releases/latest';
// Pins the repo, not just the origin: any GitHub user can attach a .dmg to a release.
const DOWNLOAD_PREFIX = 'https://github.com/thomasguillot/f-wrds/releases/download/';

interface Release {
  assets?: { name: string; browser_download_url: string }[];
}

const pointAtLatestDmg = async (): Promise<void> => {
  const buttons = document.querySelectorAll<HTMLAnchorElement>('[data-download]');
  if (buttons.length === 0) return;
  try {
    const response = await fetch(RELEASES_API, { headers: { Accept: 'application/vnd.github+json' } });
    if (!response.ok) return;
    const release = (await response.json()) as Release;
    const dmg = release.assets?.find((asset) => asset.name.endsWith('.dmg'));
    if (dmg && dmg.browser_download_url.startsWith(DOWNLOAD_PREFIX)) {
      buttons.forEach((button) => (button.href = dmg.browser_download_url));
    }
  } catch {
    // The static /releases/latest link stays as the fallback.
  }
};

void pointAtLatestDmg();
