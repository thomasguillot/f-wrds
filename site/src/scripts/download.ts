import { latestRelease, type Release } from './release';

// Pins the repo, not just the origin: any GitHub user can attach a .dmg to a release.
const DOWNLOAD_PREFIX = 'https://github.com/thomasguillot/f-wrds/releases/download/';
const VERSION_PATTERN = /^v?(\d+(?:\.\d+)*(?:[-+][0-9A-Za-z.-]+)?)$/;

const pointAtLatestDmg = (release: Release | null): void => {
  const dmg = release?.assets?.find((asset) => asset.name.endsWith('.dmg'));
  if (!dmg || !dmg.browser_download_url.startsWith(DOWNLOAD_PREFIX)) return;
  document.querySelectorAll<HTMLAnchorElement>('[data-download]').forEach((button) => (button.href = dmg.browser_download_url));
};

const showVersion = (release: Release | null): void => {
  const version = release?.tag_name?.match(VERSION_PATTERN)?.[1];
  if (!version) return;
  document.querySelectorAll<HTMLElement>('[data-version]').forEach((el) => {
    el.querySelectorAll('[data-version-number]').forEach((number) => (number.textContent = version));
    el.hidden = false;
  });
};

void latestRelease.then((release) => {
  pointAtLatestDmg(release);
  showVersion(release);
});
