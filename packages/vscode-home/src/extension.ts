import * as path from 'path';
import * as vscode from 'vscode';
import {
    LanguageClient,
    LanguageClientOptions,
    ServerOptions,
} from 'vscode-languageclient/node';
import { HomeProfiler } from './profiler';
import { HomePackageManager } from './packageManager';
import { CPUProfiler } from './cpuProfiler';
import { GCProfiler } from './gcProfiler';
import { MemoryProfiler } from './memoryProfiler';
import { MultiThreadDebugger } from './multiThreadDebugger';
import { TimeTravelDebugger } from './timeTravelDebugger';

let client: LanguageClient;
let profiler: HomeProfiler;
let packageManager: HomePackageManager;
let cpuProfiler: CPUProfiler;
let gcProfiler: GCProfiler;
let memoryProfiler: MemoryProfiler;
let multiThreadDebugger: MultiThreadDebugger;
let timeTravelDebugger: TimeTravelDebugger;
let extensionContext: vscode.ExtensionContext;

export function activate(context: vscode.ExtensionContext) {
    console.log('Home language extension is now active');
    extensionContext = context;

    // Initialize profiler and package manager
    profiler = new HomeProfiler();
    packageManager = new HomePackageManager();

    // Initialize advanced profilers and debuggers
    cpuProfiler = new CPUProfiler();
    gcProfiler = new GCProfiler();
    memoryProfiler = new MemoryProfiler();
    multiThreadDebugger = new MultiThreadDebugger();
    timeTravelDebugger = new TimeTravelDebugger();

    // Register commands
    context.subscriptions.push(
        // Language Server commands
        vscode.commands.registerCommand('ion.restartServer', restartServer),

        // Build and run commands
        vscode.commands.registerCommand('ion.run', runProgram),
        vscode.commands.registerCommand('ion.build', buildProgram),
        vscode.commands.registerCommand('ion.check', checkProgram),
        vscode.commands.registerCommand('ion.test', runTests),
        vscode.commands.registerCommand('ion.format', formatDocument),

        // Basic profiler commands
        vscode.commands.registerCommand('ion.profiler.start', () => profiler.start()),
        vscode.commands.registerCommand('ion.profiler.stop', () => profiler.stop()),
        vscode.commands.registerCommand('ion.profiler.viewReport', () => profiler.viewReport()),

        // CPU profiler commands
        vscode.commands.registerCommand('ion.cpu.start', () => cpuProfiler.start()),
        vscode.commands.registerCommand('ion.cpu.stop', () => cpuProfiler.stop()),
        vscode.commands.registerCommand('ion.cpu.flamegraph', () => cpuProfiler.generateFlameGraphHTML()),
        vscode.commands.registerCommand('ion.cpu.exportChrome', () => cpuProfiler.saveChromeProfile()),

        // GC profiler commands
        vscode.commands.registerCommand('ion.gc.start', () => gcProfiler.start()),
        vscode.commands.registerCommand('ion.gc.stop', () => gcProfiler.stop()),
        vscode.commands.registerCommand('ion.gc.report', () => gcProfiler.generateReport()),
        vscode.commands.registerCommand('ion.gc.analyzePressure', () => {
            const pressure = gcProfiler.detectGCPressure();
            if (pressure.hasPressure) {
                vscode.window.showWarningMessage(
                    `GC Pressure Detected (${pressure.severity}): ${pressure.issues.join(', ')}`,
                    'View Recommendations'
                ).then(selection => {
                    if (selection === 'View Recommendations') {
                        gcProfiler.generateReport();
                    }
                });
            } else {
                vscode.window.showInformationMessage('No GC pressure detected');
            }
        }),

        // Memory profiler commands
        vscode.commands.registerCommand('ion.memory.start', () => memoryProfiler.start()),
        vscode.commands.registerCommand('ion.memory.stop', () => {
            const stats = memoryProfiler.stop();
            if (stats.leaks.length > 0) {
                vscode.window.showWarningMessage(
                    `Memory profiling stopped. ${stats.leaks.length} potential leaks detected.`,
                    'View Report'
                ).then(selection => {
                    if (selection === 'View Report') {
                        memoryProfiler.generateReport();
                    }
                });
            } else {
                vscode.window.showInformationMessage('Memory profiling stopped. No leaks detected.');
            }
        }),
        vscode.commands.registerCommand('ion.memory.snapshot', () => {
            const snapshot = memoryProfiler.takeSnapshot();
            vscode.window.showInformationMessage(
                `Snapshot taken: ${snapshot.allocations.length} allocations, ` +
                `${(snapshot.currentUsage / 1024 / 1024).toFixed(2)} MB`
            );
        }),
        vscode.commands.registerCommand('ion.memory.findLeaks', () => {
            const leaks = memoryProfiler.detectLeaks();
            if (leaks.length > 0) {
                vscode.window.showWarningMessage(
                    `Found ${leaks.length} potential memory leaks`,
                    'View Details'
                ).then(selection => {
                    if (selection === 'View Details') {
                        memoryProfiler.generateReport();
                    }
                });
            } else {
                vscode.window.showInformationMessage('No memory leaks detected');
            }
        }),
        vscode.commands.registerCommand('ion.memory.report', () => memoryProfiler.generateReport()),

        // Time-travel debugging commands
        vscode.commands.registerCommand('ion.debug.stepBack', () => {
            const snapshot = timeTravelDebugger.stepBack();
            if (snapshot) {
                vscode.window.showInformationMessage(
                    `Stepped back to sequence ${snapshot.sequenceNumber}`
                );
            } else {
                vscode.window.showInformationMessage('Already at beginning of execution history');
            }
        }),
        vscode.commands.registerCommand('ion.debug.stepForward', () => {
            const snapshot = timeTravelDebugger.stepForward();
            if (snapshot) {
                vscode.window.showInformationMessage(
                    `Stepped forward to sequence ${snapshot.sequenceNumber}`
                );
            } else {
                vscode.window.showInformationMessage('Already at end of execution history');
            }
        }),
        vscode.commands.registerCommand('ion.debug.showTimeline', () => {
            const timeline = timeTravelDebugger.getTimeline();
            const stats = timeTravelDebugger.getStatistics();
            vscode.window.showInformationMessage(
                `Timeline: ${stats.totalSnapshots} snapshots, ` +
                `position ${stats.currentPosition + 1}/${stats.totalSnapshots}`
            );
        }),

        // Multi-threaded debugging commands
        vscode.commands.registerCommand('ion.threads.showAll', () => {
            const threads = multiThreadDebugger.getAllThreads();
            vscode.window.showInformationMessage(
                `Active threads: ${threads.length}`
            );
        }),
        vscode.commands.registerCommand('ion.threads.showDeadlocks', () => {
            const deadlocks = multiThreadDebugger.getDeadlocks();
            if (deadlocks.length > 0) {
                vscode.window.showWarningMessage(
                    `Detected ${deadlocks.length} deadlock(s)`,
                    'View Details'
                ).then(selection => {
                    if (selection === 'View Details') {
                        const info = deadlocks[0];
                        vscode.window.showErrorMessage(
                            `Deadlock: ${info.description}`,
                            { modal: true }
                        );
                    }
                });
            } else {
                vscode.window.showInformationMessage('No deadlocks detected');
            }
        }),
        vscode.commands.registerCommand('ion.threads.showRaces', () => {
            const races = multiThreadDebugger.getRaceConditions();
            if (races.length > 0) {
                vscode.window.showWarningMessage(
                    `Detected ${races.length} potential race condition(s)`,
                    'View Details'
                );
            } else {
                vscode.window.showInformationMessage('No race conditions detected');
            }
        }),

        // Package manager commands
        vscode.commands.registerCommand('ion.packageManager.search', () => packageManager.searchPackages()),
        vscode.commands.registerCommand('ion.packageManager.install', () => packageManager.installPackage()),
        vscode.commands.registerCommand('ion.packageManager.publish', () => packageManager.publishPackage()),
        vscode.commands.registerCommand('ion.packageManager.update', () => packageManager.updatePackages())
    );

    // Register formatters
    context.subscriptions.push(
        vscode.languages.registerDocumentFormattingEditProvider('home', {
            provideDocumentFormattingEdits(document: vscode.TextDocument): Promise<vscode.TextEdit[]> {
                return formatDocumentProvider(document);
            }
        })
    );

    // Register code lens provider
    const config = vscode.workspace.getConfiguration('home');
    if (config.get<boolean>('codelens.enabled')) {
        context.subscriptions.push(
            vscode.languages.registerCodeLensProvider('home', new HomeCodeLensProvider())
        );
    }

    // Format on save
    context.subscriptions.push(
        vscode.workspace.onWillSaveTextDocument(event => {
            const config = vscode.workspace.getConfiguration('home');
            if (config.get<boolean>('format.onSave') && event.document.languageId === 'home') {
                event.waitUntil(formatDocumentProvider(event.document));
            }
        })
    );

    // Start language server
    startLanguageServer(context);

    // Dispose resources
    context.subscriptions.push(profiler);
    context.subscriptions.push(packageManager);
    context.subscriptions.push(cpuProfiler);
    context.subscriptions.push(gcProfiler);
    context.subscriptions.push(memoryProfiler);
}

export function deactivate(): Thenable<void> | undefined {
    if (profiler) {
        profiler.dispose();
    }
    if (packageManager) {
        packageManager.dispose();
    }
    if (cpuProfiler) {
        cpuProfiler.dispose();
    }
    if (gcProfiler) {
        gcProfiler.dispose();
    }
    if (memoryProfiler) {
        memoryProfiler.dispose();
    }
    if (multiThreadDebugger) {
        multiThreadDebugger.clear();
    }
    if (timeTravelDebugger) {
        timeTravelDebugger.clearHistory();
    }
    if (!client) {
        return undefined;
    }
    return client.stop();
}

function startLanguageServer(context: vscode.ExtensionContext) {
    const config = vscode.workspace.getConfiguration('home');
    const ionPath = config.get<string>('path') || 'home';

    // Server options - launch the LSP server
    const serverOptions: ServerOptions = {
        command: ionPath,
        args: ['lsp'],
        options: {
            env: process.env,
        },
    };

    // Client options
    const clientOptions: LanguageClientOptions = {
        documentSelector: [{ scheme: 'file', language: 'home' }],
        synchronize: {
            fileEvents: vscode.workspace.createFileSystemWatcher('**/*.home'),
        },
    };

    // Create the language client
    client = new LanguageClient(
        'ionLanguageServer',
        'Home Language Server',
        serverOptions,
        clientOptions
    );

    // Start the client (also starts the server)
    client.start();

    vscode.window.showInformationMessage('Home Language Server started');
}

async function restartServer() {
    if (client) {
        await client.stop();
    }
    if (extensionContext) {
        startLanguageServer(extensionContext);
        vscode.window.showInformationMessage('Home Language Server restarted');
    }
}

async function runProgram() {
    const editor = vscode.window.activeTextEditor;
    if (!editor || editor.document.languageId !== 'home') {
        vscode.window.showErrorMessage('No Home file is active');
        return;
    }

    await editor.document.save();

    const config = vscode.workspace.getConfiguration('home');
    const ionPath = config.get<string>('path') || 'home';
    const filePath = editor.document.uri.fsPath;

    const terminal = vscode.window.createTerminal('Home Run');
    terminal.show();
    terminal.sendText(`${ionPath} run "${filePath}"`);
}

async function buildProgram() {
    const editor = vscode.window.activeTextEditor;
    if (!editor || editor.document.languageId !== 'home') {
        vscode.window.showErrorMessage('No Home file is active');
        return;
    }

    await editor.document.save();

    const config = vscode.workspace.getConfiguration('home');
    const ionPath = config.get<string>('path') || 'home';
    const filePath = editor.document.uri.fsPath;
    const outputPath = filePath.replace(/\.home$/, '');

    const terminal = vscode.window.createTerminal('Home Build');
    terminal.show();
    terminal.sendText(`${ionPath} build "${filePath}" -o "${outputPath}"`);
}

async function checkProgram() {
    const editor = vscode.window.activeTextEditor;
    if (!editor || editor.document.languageId !== 'home') {
        vscode.window.showErrorMessage('No Home file is active');
        return;
    }

    await editor.document.save();

    const config = vscode.workspace.getConfiguration('home');
    const ionPath = config.get<string>('path') || 'home';
    const filePath = editor.document.uri.fsPath;

    const terminal = vscode.window.createTerminal('Home Check');
    terminal.show();
    terminal.sendText(`${ionPath} check "${filePath}"`);
}

async function runTests() {
    const workspaceFolder = vscode.workspace.workspaceFolders?.[0];
    if (!workspaceFolder) {
        vscode.window.showErrorMessage('No workspace folder open');
        return;
    }

    const config = vscode.workspace.getConfiguration('home');
    const ionPath = config.get<string>('path') || 'home';

    const terminal = vscode.window.createTerminal('Home Tests');
    terminal.show();
    terminal.sendText(`cd "${workspaceFolder.uri.fsPath}" && ${ionPath} test`);
}

async function formatDocument() {
    const editor = vscode.window.activeTextEditor;
    if (!editor || editor.document.languageId !== 'home') {
        vscode.window.showErrorMessage('No Home file is active');
        return;
    }

    const edits = await formatDocumentProvider(editor.document);
    const workspaceEdit = new vscode.WorkspaceEdit();
    edits.forEach(edit => workspaceEdit.replace(editor.document.uri, edit.range, edit.newText));
    await vscode.workspace.applyEdit(workspaceEdit);
}

async function formatDocumentProvider(document: vscode.TextDocument): Promise<vscode.TextEdit[]> {
    const config = vscode.workspace.getConfiguration('home');
    const ionPath = config.get<string>('path') || 'home';

    return new Promise((resolve, reject) => {
        const { spawn } = require('child_process');
        const process = spawn(ionPath, ['format', '-'], {
            cwd: path.dirname(document.uri.fsPath)
        });

        let stdout = '';
        let stderr = '';

        process.stdin.write(document.getText());
        process.stdin.end();

        process.stdout.on('data', (data: Buffer) => {
            stdout += data.toString();
        });

        process.stderr.on('data', (data: Buffer) => {
            stderr += data.toString();
        });

        process.on('exit', (code: number) => {
            if (code === 0 && stdout) {
                const fullRange = new vscode.Range(
                    document.lineAt(0).range.start,
                    document.lineAt(document.lineCount - 1).range.end
                );
                resolve([vscode.TextEdit.replace(fullRange, stdout)]);
            } else {
                if (stderr) {
                    vscode.window.showErrorMessage(`Formatting failed: ${stderr}`);
                }
                resolve([]);
            }
        });

        process.on('error', (error: Error) => {
            vscode.window.showErrorMessage(`Formatting failed: ${error.message}`);
            resolve([]);
        });
    });
}

class HomeCodeLensProvider implements vscode.CodeLensProvider {
    public provideCodeLenses(
        document: vscode.TextDocument,
        token: vscode.CancellationToken
    ): vscode.CodeLens[] | Thenable<vscode.CodeLens[]> {
        const codeLenses: vscode.CodeLens[] = [];
        const text = document.getText();

        // Add "Run" code lens for main function
        const mainMatch = text.match(/fn\s+main\s*\(/);
        if (mainMatch && mainMatch.index !== undefined) {
            const position = document.positionAt(mainMatch.index);
            const range = new vscode.Range(position, position);

            codeLenses.push(
                new vscode.CodeLens(range, {
                    title: '▶ Run',
                    command: 'ion.run',
                    arguments: []
                })
            );

            codeLenses.push(
                new vscode.CodeLens(range, {
                    title: '🐛 Debug',
                    command: 'workbench.action.debug.start',
                    arguments: []
                })
            );
        }

        // Add "Run Test" code lens for test functions
        const testRegex = /fn\s+test_\w+\s*\(/g;
        let match;
        while ((match = testRegex.exec(text)) !== null) {
            const position = document.positionAt(match.index);
            const range = new vscode.Range(position, position);

            codeLenses.push(
                new vscode.CodeLens(range, {
                    title: '▶ Run Test',
                    command: 'ion.test',
                    arguments: []
                })
            );
        }

        return codeLenses;
    }
}
