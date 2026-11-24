const RELEASES_API = 'https://api.github.com/repos/thomasguillot/f-wrds/releases/latest';

export interface Release {
  tag_name?: string;
  assets?: { name: string; browser_download_url: string }[];
}

const fetchLatestRelease = async (): Promise<Release | null> => {
  try {
    const response = await fetch(RELEASES_API, { headers: { Accept: 'application/vnd.github+json' } });
    if (!response.ok) return null;
    return (await response.json()) as Release;
  } catch {
    return null;
  }
};

export const latestRelease: Promise<Release | null> = fetchLatestRelease();
