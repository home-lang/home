import * as core from '@actions/core';
import * as tc from '@actions/tool-cache';
import * as exec from '@actions/exec';
import * as io from '@actions/io';
import * as path from 'path';
import * as fs from 'fs';
import * as os from 'os';

const INSTALL_BASE = 'https://github.com/ion-lang/ion/releases/download';

interface HomeVersion {
  version: string;
  url: string;
}

async function run(): Promise<void> {
  try {
    // Get input version or read from version file
    let ionVersion = core.getInput('home-version') || 'latest';
    const ionVersionFile = core.getInput('home-version-file');

    if (ionVersionFile && fs.existsSync(ionVersionFile)) {
      ionVersion = fs.readFileSync(ionVersionFile, 'utf-8').trim();
    }

    const enableCache = core.getInput('cache') === 'true';

    core.info(`Setting up Home ${ionVersion}...`);

    // Check cache first
    let ionPath: string | undefined;

    if (enableCache) {
      ionPath = tc.find('home', ionVersion);
      if (ionPath) {
        core.info(`Found Home ${ionVersion} in cache`);
        core.addPath(ionPath);
        await verifyInstallation();
        return;
      }
    }

    // Download and install Home
    const { url, actualVersion } = await getDownloadUrl(ionVersion);
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
      ionPath = await tc.cacheDir(extractedPath, 'home', actualVersion);
    } else {
      ionPath = extractedPath;
    }

    core.addPath(ionPath);

    // Verify installation
    await verifyInstallation();

    core.info(`✓ Home ${actualVersion} installed successfully`);
    core.setOutput('ion-version', actualVersion);
    core.setOutput('ion-path', ionPath);

  } catch (error) {
    if (error instanceof Error) {
      core.setFailed(error.message);
    } else {
      core.setFailed('An unknown error occurred');
    }
  }
}

async function getDownloadUrl(version: string): Promise<{ url: string; actualVersion: string }> {
  const platform = getPlatform();
  const arch = getArch();

  // Handle "latest" and "canary" versions
  let actualVersion = version;
  if (version === 'latest') {
    // In production, fetch from GitHub API
    actualVersion = '0.1.0'; // Fallback
  } else if (version === 'canary') {
    actualVersion = 'canary';
  }

  const filename = `ion-${actualVersion}-${platform}-${arch}.tar.gz`;
  const url = `${INSTALL_BASE}/v${actualVersion}/${filename}`;

  return { url, actualVersion };
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
  } catch (error) {
    throw new Error('Home installation verification failed');
  }
}

run();
