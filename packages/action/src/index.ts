import * as core from '@actions/core';
import * as tc from '@actions/tool-cache';
import * as exec from '@actions/exec';
import * as os from 'os';
import * as fs from 'fs';
import * as https from 'https';

const GITHUB_REPO = 'home-lang/home';
const INSTALL_BASE = `https://github.com/${GITHUB_REPO}/releases/download`;

async function run(): Promise<void> {
  try {
    // Get input version or read from version file
    let version = core.getInput('home-version') || 'latest';
    const versionFile = core.getInput('home-version-file');

    if (versionFile && fs.existsSync(versionFile)) {
      version = fs.readFileSync(versionFile, 'utf-8').trim();
    }

    const enableCache = core.getInput('cache') === 'true';

    core.info(`Setting up Home ${version}...`);

    // Check cache first
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

    // Resolve the actual version
    const actualVersion = await resolveVersion(version);
    core.info(`Resolved version: ${actualVersion}`);

    // Check cache again with resolved version
    if (enableCache) {
      homePath = tc.find('home', actualVersion);
      if (homePath) {
        core.info(`Found Home ${actualVersion} in cache`);
        core.addPath(homePath);
        await verifyInstallation();
        return;
      }
    }

    // Download and install Home
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

    // Cache the tool
    if (enableCache) {
      homePath = await tc.cacheDir(extractedPath, 'home', actualVersion);
    } else {
      homePath = extractedPath;
    }

    core.addPath(homePath);

    // Verify installation
    await verifyInstallation();

    core.info(`Home ${actualVersion} installed successfully`);
    core.setOutput('home-version', actualVersion);
    core.setOutput('home-path', homePath);

  } catch (error) {
    if (error instanceof Error) {
      core.setFailed(error.message);
    } else {
      core.setFailed('An unknown error occurred');
    }
  }
}

async function resolveVersion(version: string): Promise<string> {
  if (version !== 'latest' && version !== 'canary') {
    return version;
  }

  const apiUrl = version === 'latest'
    ? `https://api.github.com/repos/${GITHUB_REPO}/releases/latest`
    : `https://api.github.com/repos/${GITHUB_REPO}/releases`;

  const data = await fetchJson(apiUrl);

  if (version === 'latest') {
    const tagName = data?.tag_name;
    if (!tagName) {
      throw new Error(`No releases found for ${GITHUB_REPO}. Please publish a release first.`);
    }
    return tagName.replace(/^v/, '');
  }

  // For canary, find the first pre-release
  if (Array.isArray(data)) {
    const prerelease = data.find((r: { prerelease: boolean }) => r.prerelease);
    if (prerelease?.tag_name) {
      return prerelease.tag_name.replace(/^v/, '');
    }
  }

  throw new Error(`No canary/prerelease found for ${GITHUB_REPO}`);
}

function fetchJson(url: string): Promise<any> {
  return new Promise((resolve, reject) => {
    const headers: Record<string, string> = {
      'User-Agent': 'setup-home-action',
      'Accept': 'application/vnd.github.v3+json',
    };

    // Use GITHUB_TOKEN if available for higher rate limits
    const token = process.env.GITHUB_TOKEN;
    if (token) {
      headers['Authorization'] = `token ${token}`;
    }

    https.get(url, { headers }, (res) => {
      if (res.statusCode === 404) {
        resolve(null);
        return;
      }

      if (res.statusCode !== 200) {
        reject(new Error(`GitHub API returned HTTP ${res.statusCode} for ${url}`));
        return;
      }

      let body = '';
      res.on('data', (chunk: string) => { body += chunk; });
      res.on('end', () => {
        try {
          resolve(JSON.parse(body));
        } catch {
          reject(new Error(`Failed to parse GitHub API response from ${url}`));
        }
      });
    }).on('error', reject);
  });
}

function getDownloadUrl(version: string): string {
  const platform = getPlatform();
  const arch = getArch();
  const filename = `home-${version}-${platform}-${arch}.tar.gz`;
  return `${INSTALL_BASE}/v${version}/${filename}`;
}

function getPlatform(): string {
  const platform = os.platform();
  switch (platform) {
    case 'darwin':
      return 'macos';
    case 'linux':
      return 'linux';
    case 'win32':
      return 'windows';
    default:
      throw new Error(`Unsupported platform: ${platform}`);
  }
}

function getArch(): string {
  const arch = os.arch();
  switch (arch) {
    case 'x64':
      return 'x64';
    case 'arm64':
      return 'aarch64';
    default:
      throw new Error(`Unsupported architecture: ${arch}`);
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
