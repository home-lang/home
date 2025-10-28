import * as vscode from 'vscode';
import * as https from 'https';
import * as fs from 'fs';
import * as path from 'path';
import { spawn } from 'child_process';

export class HomePackageManager {
    private readonly REGISTRY_URL = 'https://registry.home-lang.org';
    private _outputChannel: vscode.OutputChannel;

    constructor() {
        this._outputChannel = vscode.window.createOutputChannel('Home Package Manager');
    }

    public async searchPackages(): Promise<void> {
        const searchTerm = await vscode.window.showInputBox({
            prompt: 'Search for Home packages',
            placeHolder: 'Enter package name or keywords'
        });

        if (!searchTerm) {
            return;
        }

        this._outputChannel.clear();
        this._outputChannel.appendLine(`Searching for: ${searchTerm}`);
        this._outputChannel.show();

        try {
            const results = await this.fetchPackages(searchTerm);

            if (results.length === 0) {
                vscode.window.showInformationMessage('No packages found');
                return;
            }

            // Show results in quick pick
            const quickPickItems = results.map(pkg => ({
                label: pkg.name,
                description: pkg.version,
                detail: pkg.description,
                package: pkg
            }));

            const selected = await vscode.window.showQuickPick(quickPickItems, {
                placeHolder: 'Select a package to install'
            });

            if (selected) {
                await this.installPackage(selected.package.name, selected.package.version);
            }

        } catch (error) {
            this._outputChannel.appendLine(`Error searching packages: ${error}`);
            vscode.window.showErrorMessage(`Failed to search packages: ${error}`);
        }
    }

    public async installPackage(packageName?: string, version?: string): Promise<void> {
        let pkgName = packageName;
        let pkgVersion = version;

        if (!pkgName) {
            pkgName = await vscode.window.showInputBox({
                prompt: 'Enter package name',
                placeHolder: 'package-name'
            });

            if (!pkgName) {
                return;
            }
        }

        if (!pkgVersion) {
            pkgVersion = await vscode.window.showInputBox({
                prompt: 'Enter package version (or leave empty for latest)',
                placeHolder: 'latest'
            });
        }

        const workspaceFolder = vscode.workspace.workspaceFolders?.[0];
        if (!workspaceFolder) {
            vscode.window.showErrorMessage('No workspace folder open');
            return;
        }

        this._outputChannel.clear();
        this._outputChannel.appendLine(`Installing ${pkgName}${pkgVersion ? `@${pkgVersion}` : ''}...`);
        this._outputChannel.show();

        const config = vscode.workspace.getConfiguration('ion');
        const ionPath = config.get<string>('path') || 'ion';

        const installArgs = ['package', 'install', pkgName];
        if (pkgVersion && pkgVersion !== 'latest') {
            installArgs.push(`--version=${pkgVersion}`);
        }

        return new Promise((resolve, reject) => {
            const process = spawn(ionPath, installArgs, {
                cwd: workspaceFolder.uri.fsPath
            });

            process.stdout?.on('data', (data) => {
                this._outputChannel.appendLine(data.toString());
            });

            process.stderr?.on('data', (data) => {
                this._outputChannel.appendLine(`[ERROR] ${data.toString()}`);
            });

            process.on('exit', (code) => {
                if (code === 0) {
                    this._outputChannel.appendLine(`Successfully installed ${pkgName}`);
                    vscode.window.showInformationMessage(`Package ${pkgName} installed successfully`);
                    resolve();
                } else {
                    this._outputChannel.appendLine(`Installation failed with code ${code}`);
                    vscode.window.showErrorMessage(`Failed to install ${pkgName}`);
                    reject(new Error(`Installation failed with code ${code}`));
                }
            });
        });
    }

    public async publishPackage(): Promise<void> {
        const workspaceFolder = vscode.workspace.workspaceFolders?.[0];
        if (!workspaceFolder) {
            vscode.window.showErrorMessage('No workspace folder open');
            return;
        }

        // Check if package.home exists
        const packageFilePath = path.join(workspaceFolder.uri.fsPath, 'package.home');
        if (!fs.existsSync(packageFilePath)) {
            vscode.window.showErrorMessage('No package.home file found in workspace');
            return;
        }

        const confirm = await vscode.window.showWarningMessage(
            'Publish package to Home registry?',
            'Publish',
            'Cancel'
        );

        if (confirm !== 'Publish') {
            return;
        }

        this._outputChannel.clear();
        this._outputChannel.appendLine('Publishing package...');
        this._outputChannel.show();

        const config = vscode.workspace.getConfiguration('ion');
        const ionPath = config.get<string>('path') || 'ion';

        return new Promise((resolve, reject) => {
            const process = spawn(ionPath, ['package', 'publish'], {
                cwd: workspaceFolder.uri.fsPath
            });

            process.stdout?.on('data', (data) => {
                this._outputChannel.appendLine(data.toString());
            });

            process.stderr?.on('data', (data) => {
                this._outputChannel.appendLine(`[ERROR] ${data.toString()}`);
            });

            process.on('exit', (code) => {
                if (code === 0) {
                    this._outputChannel.appendLine('Package published successfully');
                    vscode.window.showInformationMessage('Package published successfully');
                    resolve();
                } else {
                    this._outputChannel.appendLine(`Publishing failed with code ${code}`);
                    vscode.window.showErrorMessage('Failed to publish package');
                    reject(new Error(`Publishing failed with code ${code}`));
                }
            });
        });
    }

    public async updatePackages(): Promise<void> {
        const workspaceFolder = vscode.workspace.workspaceFolders?.[0];
        if (!workspaceFolder) {
            vscode.window.showErrorMessage('No workspace folder open');
            return;
        }

        this._outputChannel.clear();
        this._outputChannel.appendLine('Updating packages...');
        this._outputChannel.show();

        const config = vscode.workspace.getConfiguration('ion');
        const ionPath = config.get<string>('path') || 'ion';

        return new Promise((resolve, reject) => {
            const process = spawn(ionPath, ['package', 'update'], {
                cwd: workspaceFolder.uri.fsPath
            });

            process.stdout?.on('data', (data) => {
                this._outputChannel.appendLine(data.toString());
            });

            process.stderr?.on('data', (data) => {
                this._outputChannel.appendLine(`[ERROR] ${data.toString()}`);
            });

            process.on('exit', (code) => {
                if (code === 0) {
                    this._outputChannel.appendLine('Packages updated successfully');
                    vscode.window.showInformationMessage('Packages updated successfully');
                    resolve();
                } else {
                    this._outputChannel.appendLine(`Update failed with code ${code}`);
                    vscode.window.showErrorMessage('Failed to update packages');
                    reject(new Error(`Update failed with code ${code}`));
                }
            });
        });
    }

    private async fetchPackages(query: string): Promise<PackageInfo[]> {
        return new Promise((resolve, reject) => {
            const url = `${this.REGISTRY_URL}/search?q=${encodeURIComponent(query)}`;

            https.get(url, (res) => {
                let data = '';

                res.on('data', (chunk) => {
                    data += chunk;
                });

                res.on('end', () => {
                    try {
                        const result = JSON.parse(data);
                        resolve(result.packages || []);
                    } catch (error) {
                        reject(error);
                    }
                });
            }).on('error', (error) => {
                reject(error);
            });
        });
    }

    public dispose(): void {
        this._outputChannel.dispose();
    }
}

interface PackageInfo {
    name: string;
    version: string;
    description: string;
    author?: string;
    license?: string;
    homepage?: string;
}
