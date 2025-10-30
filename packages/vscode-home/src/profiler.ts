import * as vscode from 'vscode';
import * as path from 'path';
import * as fs from 'fs';
import { spawn, ChildProcess } from 'child_process';

export class HomeProfiler {
    private _isRunning = false;
    private _process: ChildProcess | undefined;
    private _outputChannel: vscode.OutputChannel;
    private _statusBarItem: vscode.StatusBarItem;
    private _profileData: ProfileData[] = [];

    constructor() {
        this._outputChannel = vscode.window.createOutputChannel('Home Profiler');
        this._statusBarItem = vscode.window.createStatusBarItem(
            vscode.StatusBarAlignment.Right,
            100
        );
        this._statusBarItem.text = "$(pulse) Home Profiler";
        this._statusBarItem.command = 'ion.profiler.viewReport';
    }

    public async start(program?: string): Promise<void> {
        if (this._isRunning) {
            vscode.window.showWarningMessage('Profiler is already running');
            return;
        }

        const editor = vscode.window.activeTextEditor;
        const filePath = program || editor?.document.uri.fsPath;

        if (!filePath) {
            vscode.window.showErrorMessage('No Home file to profile');
            return;
        }

        const config = vscode.workspace.getConfiguration('home');
        const ionPath = config.get<string>('path') || 'home';

        this._isRunning = true;
        this._profileData = [];
        this._statusBarItem.text = "$(pulse) Profiling...";
        this._statusBarItem.show();

        this._outputChannel.clear();
        this._outputChannel.appendLine(`Starting profiler for ${filePath}`);
        this._outputChannel.show();

        try {
            this._process = spawn(ionPath, ['profile', filePath], {
                cwd: path.dirname(filePath)
            });

            this._process.stdout?.on('data', (data) => {
                this.processOutput(data.toString());
            });

            this._process.stderr?.on('data', (data) => {
                this._outputChannel.appendLine(`[ERROR] ${data.toString()}`);
            });

            this._process.on('exit', (code) => {
                this._outputChannel.appendLine(`Profiler exited with code ${code}`);
                this.stop();
                if (code === 0) {
                    this.saveReport();
                    vscode.window.showInformationMessage(
                        'Profiling complete. View report?',
                        'View Report'
                    ).then(selection => {
                        if (selection === 'View Report') {
                            this.viewReport();
                        }
                    });
                }
            });

        } catch (error) {
            this._outputChannel.appendLine(`Failed to start profiler: ${error}`);
            this.stop();
            vscode.window.showErrorMessage(`Failed to start profiler: ${error}`);
        }
    }

    public stop(): void {
        if (this._process) {
            this._process.kill();
            this._process = undefined;
        }

        this._isRunning = false;
        this._statusBarItem.text = "$(pulse) Home Profiler";
        this._statusBarItem.hide();
    }

    public isRunning(): boolean {
        return this._isRunning;
    }

    private processOutput(data: string) {
        const lines = data.split('\n');

        for (const line of lines) {
            this._outputChannel.appendLine(line);

            // Parse profiler data
            if (line.startsWith('[PROFILE]')) {
                try {
                    const jsonData = line.substring(9).trim();
                    const profileEntry = JSON.parse(jsonData);
                    this._profileData.push(profileEntry);
                } catch (e) {
                    this._outputChannel.appendLine(`Failed to parse profile data: ${e}`);
                }
            }
        }
    }

    private saveReport(): void {
        if (this._profileData.length === 0) {
            this._outputChannel.appendLine('No profiler data collected');
            return;
        }

        const workspaceFolder = vscode.workspace.workspaceFolders?.[0];
        if (!workspaceFolder) {
            return;
        }

        const reportPath = path.join(workspaceFolder.uri.fsPath, 'ion-profile-report.json');
        const report = {
            timestamp: new Date().toISOString(),
            summary: this.generateSummary(),
            data: this._profileData
        };

        fs.writeFileSync(reportPath, JSON.stringify(report, null, 2));
        this._outputChannel.appendLine(`Report saved to ${reportPath}`);
    }

    public async viewReport(): Promise<void> {
        const workspaceFolder = vscode.workspace.workspaceFolders?.[0];
        if (!workspaceFolder) {
            vscode.window.showErrorMessage('No workspace folder open');
            return;
        }

        const reportPath = path.join(workspaceFolder.uri.fsPath, 'ion-profile-report.json');

        if (!fs.existsSync(reportPath)) {
            vscode.window.showErrorMessage('No profiler report found. Run the profiler first.');
            return;
        }

        const reportData = JSON.parse(fs.readFileSync(reportPath, 'utf-8'));

        // Create a webview to display the report
        const panel = vscode.window.createWebviewPanel(
            'ionProfiler',
            'Home Profiler Report',
            vscode.ViewColumn.One,
            { enableScripts: true }
        );

        panel.webview.html = this.getReportHtml(reportData);
    }

    private generateSummary(): ProfileSummary {
        const functionCalls: Map<string, FunctionStats> = new Map();
        let totalTime = 0;

        for (const entry of this._profileData) {
            if (entry.type === 'function_call') {
                const stats = functionCalls.get(entry.name) || {
                    name: entry.name,
                    callCount: 0,
                    totalTime: 0,
                    minTime: Infinity,
                    maxTime: 0,
                    avgTime: 0
                };

                stats.callCount++;
                stats.totalTime += entry.duration;
                stats.minTime = Math.min(stats.minTime, entry.duration);
                stats.maxTime = Math.max(stats.maxTime, entry.duration);
                totalTime += entry.duration;

                functionCalls.set(entry.name, stats);
            }
        }

        // Calculate averages
        for (const stats of functionCalls.values()) {
            stats.avgTime = stats.totalTime / stats.callCount;
        }

        // Sort by total time
        const sortedFunctions = Array.from(functionCalls.values())
            .sort((a, b) => b.totalTime - a.totalTime);

        return {
            totalTime,
            functionCount: functionCalls.size,
            topFunctions: sortedFunctions.slice(0, 10)
        };
    }

    private getReportHtml(reportData: any): string {
        const summary = reportData.summary;

        return `
            <!DOCTYPE html>
            <html lang="en">
            <head>
                <meta charset="UTF-8">
                <meta name="viewport" content="width=device-width, initial-scale=1.0">
                <title>Home Profiler Report</title>
                <style>
                    body {
                        font-family: var(--vscode-font-family);
                        color: var(--vscode-foreground);
                        background-color: var(--vscode-editor-background);
                        padding: 20px;
                    }
                    h1, h2 {
                        color: var(--vscode-editor-foreground);
                    }
                    table {
                        border-collapse: collapse;
                        width: 100%;
                        margin-top: 20px;
                    }
                    th, td {
                        text-align: left;
                        padding: 12px;
                        border-bottom: 1px solid var(--vscode-panel-border);
                    }
                    th {
                        background-color: var(--vscode-editor-selectionBackground);
                        font-weight: bold;
                    }
                    tr:hover {
                        background-color: var(--vscode-list-hoverBackground);
                    }
                    .summary {
                        background-color: var(--vscode-textBlockQuote-background);
                        padding: 15px;
                        border-radius: 5px;
                        margin-bottom: 20px;
                    }
                    .summary-item {
                        margin: 10px 0;
                    }
                    .summary-label {
                        font-weight: bold;
                        color: var(--vscode-textPreformat-foreground);
                    }
                    .bar {
                        background-color: var(--vscode-progressBar-background);
                        height: 20px;
                        border-radius: 3px;
                        margin-top: 5px;
                    }
                </style>
            </head>
            <body>
                <h1>Home Profiler Report</h1>
                <p><em>Generated: ${reportData.timestamp}</em></p>

                <div class="summary">
                    <h2>Summary</h2>
                    <div class="summary-item">
                        <span class="summary-label">Total Time:</span> ${summary.totalTime.toFixed(2)}ms
                    </div>
                    <div class="summary-item">
                        <span class="summary-label">Functions Profiled:</span> ${summary.functionCount}
                    </div>
                </div>

                <h2>Top Functions by Time</h2>
                <table>
                    <thead>
                        <tr>
                            <th>Function</th>
                            <th>Calls</th>
                            <th>Total Time (ms)</th>
                            <th>Avg Time (ms)</th>
                            <th>Min Time (ms)</th>
                            <th>Max Time (ms)</th>
                            <th>% of Total</th>
                        </tr>
                    </thead>
                    <tbody>
                        ${summary.topFunctions.map((fn: FunctionStats) => `
                            <tr>
                                <td><code>${fn.name}</code></td>
                                <td>${fn.callCount}</td>
                                <td>${fn.totalTime.toFixed(2)}</td>
                                <td>${fn.avgTime.toFixed(2)}</td>
                                <td>${fn.minTime.toFixed(2)}</td>
                                <td>${fn.maxTime.toFixed(2)}</td>
                                <td>${((fn.totalTime / summary.totalTime) * 100).toFixed(1)}%</td>
                            </tr>
                        `).join('')}
                    </tbody>
                </table>

                <h2>Call Timeline</h2>
                <div id="timeline">
                    ${reportData.data.slice(0, 100).map((entry: any, index: number) => `
                        <div style="margin: 5px 0;">
                            <code>${entry.name}</code> - ${entry.duration?.toFixed(2) || 'N/A'}ms
                        </div>
                    `).join('')}
                </div>
            </body>
            </html>
        `;
    }

    public dispose(): void {
        this.stop();
        this._outputChannel.dispose();
        this._statusBarItem.dispose();
    }
}

interface ProfileData {
    type: string;
    name: string;
    duration: number;
    timestamp: number;
}

interface FunctionStats {
    name: string;
    callCount: number;
    totalTime: number;
    minTime: number;
    maxTime: number;
    avgTime: number;
}

interface ProfileSummary {
    totalTime: number;
    functionCount: number;
    topFunctions: FunctionStats[];
}
