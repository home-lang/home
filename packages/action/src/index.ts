import * as core from '@actions/core';
import * as exec from '@actions/exec';
import * as tc from '@actions/tool-cache';
import * as fs from 'fs';
import * as https from 'https';
import * as os from 'os';

const GITHUB_REPO = 'home-lang/home';
const INSTALL_BASE = `https://github.com/${GITHUB_REPO}/releases/download`;
const HTTP_TIMEOUT_MS = 30_000;

type Platform = 'macos' | 'linux' | 'windows';
type Arch = 'x64' | 'aarch64';

interface GitHubRelease {
  tag_name?: string;
  prerelease?: boolean;
}

async function run(): Promise<void> {
  try {
    let version = core.getInput('home-version') || 'latest';
    const versionFile = core.getInput('home-version-file');

    if (versionFile && fs.existsSync(versionFile)) {
      version = fs.readFileSync(versionFile, 'utf-8').trim();
    }

    const enableCache = core.getInput('cache') === 'true';

    core.info(`Setting up Home ${version}...`);

    let homePath: string | undefined;

    if (enableCache && version !== 'latest' && version !== 'canary') {
      homePath = tc.find('home', version);
      if (homePath) {
        core.info(`Found Home ${version} in cache`);
        core.addPath(homePath);
        await verifyInstallation();
        return;
      }
    }

    const actualVersion = await resolveVersion(version);
    core.info(`Resolved version: ${actualVersion}`);

    if (enableCache) {
      homePath = tc.find('home', actualVersion);
      if (homePath) {
        core.info(`Found Home ${actualVersion} in cache`);
        core.addPath(homePath);
        await verifyInstallation();
        return;
      }
    }

    const url = getDownloadUrl(actualVersion);
    core.info(`Downloading Home from ${url}`);

    const downloadPath = await tc.downloadTool(url);
    core.info('Extracting Home...');

    let extractedPath: string;
    if (url.endsWith('.tar.gz')) {
      extractedPath = await tc.extractTar(downloadPath);
    } else if (url.endsWith('.zip')) {
      extractedPath = await tc.extractZip(downloadPath);
    } else {
      throw new Error(`Unsupported archive format: ${url}`);
    }

    homePath = enableCache
      ? await tc.cacheDir(extractedPath, 'home', actualVersion)
      : extractedPath;

    core.addPath(homePath);

    await verifyInstallation();

    core.info(`Home ${actualVersion} installed successfully`);
    core.setOutput('home-version', actualVersion);
    core.setOutput('home-path', homePath);
  } catch (error) {
    core.setFailed(error instanceof Error ? error.message : String(error));
  }
}

async function resolveVersion(version: string): Promise<string> {
  if (version !== 'latest' && version !== 'canary') {
    return version;
  }

  const apiUrl = version === 'latest'
    ? `https://api.github.com/repos/${GITHUB_REPO}/releases/latest`
    : `https://api.github.com/repos/${GITHUB_REPO}/releases`;

  const data = await fetchJson<GitHubRelease | GitHubRelease[]>(apiUrl);

  if (version === 'latest') {
    const tagName = !Array.isArray(data) ? data?.tag_name : undefined;
    if (!tagName) {
      throw new Error(`No releases found for ${GITHUB_REPO}. Please publish a release first.`);
    }
    return tagName.replace(/^v/, '');
  }

  if (Array.isArray(data)) {
    const prerelease = data.find((r) => r.prerelease);
    if (prerelease?.tag_name) {
      return prerelease.tag_name.replace(/^v/, '');
    }
  }

  throw new Error(`No canary/prerelease found for ${GITHUB_REPO}`);
}

function fetchJson<T>(url: string): Promise<T | null> {
  return new Promise((resolve, reject) => {
    const headers: Record<string, string> = {
      'User-Agent': 'setup-home-action',
      Accept: 'application/vnd.github.v3+json',
    };

    const token = process.env.GITHUB_TOKEN;
    if (token) {
      headers.Authorization = `token ${token}`;
    }

    const req = https.get(url, { headers, timeout: HTTP_TIMEOUT_MS }, (res) => {
      if (res.statusCode === 404) {
        res.resume();
        resolve(null);
        return;
      }

      if (res.statusCode !== 200) {
        res.resume();
        reject(new Error(`GitHub API returned HTTP ${res.statusCode} for ${url}`));
        return;
      }

      const chunks: Buffer[] = [];
      res.on('data', (chunk: Buffer) => { chunks.push(chunk); });
      res.on('end', () => {
        try {
          resolve(JSON.parse(Buffer.concat(chunks).toString('utf-8')) as T);
        } catch {
          reject(new Error(`Failed to parse GitHub API response from ${url}`));
        }
      });
    });

    req.on('timeout', () => {
      req.destroy(new Error(`Request to ${url} timed out after ${HTTP_TIMEOUT_MS}ms`));
    });
    req.on('error', reject);
  });
}

function getDownloadUrl(version: string): string {
  const platform = getPlatform();
  const arch = getArch();
  const ext = platform === 'windows' ? 'zip' : 'tar.gz';
  return `${INSTALL_BASE}/v${version}/home-${version}-${platform}-${arch}.${ext}`;
}

function getPlatform(): Platform {
  const platform = os.platform();
  switch (platform) {
    case 'darwin': return 'macos';
    case 'linux': return 'linux';
    case 'win32': return 'windows';
    default: throw new Error(`Unsupported platform: ${platform}`);
  }
}

function getArch(): Arch {
  const arch = os.arch();
  switch (arch) {
    case 'x64': return 'x64';
    case 'arm64': return 'aarch64';
    default: throw new Error(`Unsupported architecture: ${arch}`);
  }
}

async function verifyInstallation(): Promise<void> {
  try {
    await exec.exec('home', ['--version']);
  } catch {
    throw new Error('Home installation verification failed');
  }
}

run();
