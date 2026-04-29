import { spawn } from 'child_process';
import * as path from 'path';
import * as vscode from 'vscode';
import {
    LanguageClient,
    LanguageClientOptions,
    ServerOptions,
} from 'vscode-languageclient/node';
import { HomeCodeActionsProvider } from './codeActions';
import { HomeCodeLensProvider as AdvancedCodeLensProvider } from './codeLens';
import { CPUProfiler } from './cpuProfiler';
import { GCProfiler } from './gcProfiler';
import { HomeInlayHintsProvider } from './inlayHints';
import { MemoryProfiler } from './memoryProfiler';
import { MultiThreadDebugger } from './multiThreadDebugger';
import { HomePackageManager } from './packageManager';
import { HomeProfiler } from './profiler';
import { HomeSemanticTokensProvider, legend } from './semanticTokens';
import { TimeTravelDebugger } from './timeTravelDebugger';
import { registerWorkspaceProviders } from './workspaceSymbols';

let client: LanguageClient | undefined;
let profiler!: HomeProfiler;
let packageManager!: HomePackageManager;
let cpuProfiler!: CPUProfiler;
let gcProfiler!: GCProfiler;
let memoryProfiler!: MemoryProfiler;
let multiThreadDebugger!: MultiThreadDebugger;
let timeTravelDebugger!: TimeTravelDebugger;
let extensionContext: vscode.ExtensionContext | undefined;

const DOCUMENT_SELECTOR: vscode.DocumentSelector = { language: 'home' };

function getHomePath(): string {
    const config = vscode.workspace.getConfiguration('home');
    return config.get<string>('path') || 'home';
}

// eslint-disable-next-line pickier/no-unused-vars
function shellQuote(value: string): string {
    if (process.platform === 'win32') {
        return `"${value.replace(/"/g, '""')}"`;
    }
    return `'${value.replace(/'/g, `'\\''`)}'`;
}

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
        vscode.commands.registerCommand('home.restartServer', restartServer),

        // Build and run commands
        vscode.commands.registerCommand('home.run', runProgram),
        vscode.commands.registerCommand('home.build', buildProgram),
        vscode.commands.registerCommand('home.check', checkProgram),
        vscode.commands.registerCommand('home.test', runTests),
        vscode.commands.registerCommand('home.format', formatDocument),

        // Basic profiler commands
        vscode.commands.registerCommand('home.profiler.start', () => profiler.start()),
        vscode.commands.registerCommand('home.profiler.stop', () => profiler.stop()),
        vscode.commands.registerCommand('home.profiler.viewReport', () => profiler.viewReport()),

        // CPU profiler commands
        vscode.commands.registerCommand('home.cpu.start', () => cpuProfiler.start()),
        vscode.commands.registerCommand('home.cpu.stop', () => cpuProfiler.stop()),
        vscode.commands.registerCommand('home.cpu.flamegraph', () => cpuProfiler.generateFlameGraphHTML()),
        vscode.commands.registerCommand('home.cpu.exportChrome', () => cpuProfiler.saveChromeProfile()),

        // GC profiler commands
        vscode.commands.registerCommand('home.gc.start', () => gcProfiler.start()),
        vscode.commands.registerCommand('home.gc.stop', () => gcProfiler.stop()),
        vscode.commands.registerCommand('home.gc.report', () => gcProfiler.generateReport()),
        vscode.commands.registerCommand('home.gc.analyzePressure', () => {
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
        vscode.commands.registerCommand('home.memory.start', () => memoryProfiler.start()),
        vscode.commands.registerCommand('home.memory.stop', () => {
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
        vscode.commands.registerCommand('home.memory.snapshot', () => {
            const snapshot = memoryProfiler.takeSnapshot();
            vscode.window.showInformationMessage(
                `Snapshot taken: ${snapshot.allocations.length} allocations, ` +
                `${(snapshot.currentUsage / 1024 / 1024).toFixed(2)} MB`
            );
        }),
        vscode.commands.registerCommand('home.memory.findLeaks', () => {
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
        vscode.commands.registerCommand('home.memory.report', () => memoryProfiler.generateReport()),

        // Time-travel debugging commands
        vscode.commands.registerCommand('home.debug.stepBack', () => {
            const snapshot = timeTravelDebugger.stepBack();
            if (snapshot) {
                vscode.window.showInformationMessage(
                    `Stepped back to sequence ${snapshot.sequenceNumber}`
                );
            } else {
                vscode.window.showInformationMessage('Already at beginning of execution history');
            }
        }),
        vscode.commands.registerCommand('home.debug.stepForward', () => {
            const snapshot = timeTravelDebugger.stepForward();
            if (snapshot) {
                vscode.window.showInformationMessage(
                    `Stepped forward to sequence ${snapshot.sequenceNumber}`
                );
            } else {
                vscode.window.showInformationMessage('Already at end of execution history');
            }
        }),
        vscode.commands.registerCommand('home.debug.showTimeline', () => {
            const stats = timeTravelDebugger.getStatistics();
            vscode.window.showInformationMessage(
                `Timeline: ${stats.totalSnapshots} snapshots, ` +
                `position ${stats.currentPosition + 1}/${stats.totalSnapshots}`
            );
        }),

        // Multi-threaded debugging commands
        vscode.commands.registerCommand('home.threads.showAll', () => {
            const threads = multiThreadDebugger.getAllThreads();
            vscode.window.showInformationMessage(
                `Active threads: ${threads.length}`
            );
        }),
        vscode.commands.registerCommand('home.threads.showDeadlocks', () => {
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
        vscode.commands.registerCommand('home.threads.showRaces', () => {
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
        vscode.commands.registerCommand('home.packageManager.search', () => packageManager.searchPackages()),
        vscode.commands.registerCommand('home.packageManager.install', () => packageManager.installPackage()),
        vscode.commands.registerCommand('home.packageManager.publish', () => packageManager.publishPackage()),
        vscode.commands.registerCommand('home.packageManager.update', () => packageManager.updatePackages())
    );

    // Register formatters
    context.subscriptions.push(
        vscode.languages.registerDocumentFormattingEditProvider(DOCUMENT_SELECTOR, {
            provideDocumentFormattingEdits: (document) => formatDocumentProvider(document),
        })
    );

    // Register semantic tokens provider
    context.subscriptions.push(
        vscode.languages.registerDocumentSemanticTokensProvider(
            DOCUMENT_SELECTOR,
            new HomeSemanticTokensProvider(),
            legend
        )
    );

    // Register code actions provider
    context.subscriptions.push(
        vscode.languages.registerCodeActionsProvider(
            DOCUMENT_SELECTOR,
            new HomeCodeActionsProvider(),
            { providedCodeActionKinds: HomeCodeActionsProvider.providedCodeActionKinds }
        )
    );

    // Register inlay hints / code lens providers (config-gated)
    const homeConfig = vscode.workspace.getConfiguration('home');
    if (homeConfig.get<boolean>('inlayHints.enabled', true)) {
        context.subscriptions.push(
            vscode.languages.registerInlayHintsProvider(DOCUMENT_SELECTOR, new HomeInlayHintsProvider())
        );
    }

    if (homeConfig.get<boolean>('codelens.enabled')) {
        context.subscriptions.push(
            vscode.languages.registerCodeLensProvider(DOCUMENT_SELECTOR, new AdvancedCodeLensProvider())
        );
    }

    // Register workspace symbols and rename providers
    registerWorkspaceProviders(context);

    // Format on save
    context.subscriptions.push(
        vscode.workspace.onWillSaveTextDocument(event => {
            const onSaveConfig = vscode.workspace.getConfiguration('home');
            if (onSaveConfig.get<boolean>('format.onSave') && event.document.languageId === 'home') {
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

function startLanguageServer(_context: vscode.ExtensionContext) {
    // Server options - launch the LSP server
    const serverOptions: ServerOptions = {
        command: getHomePath(),
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

async function getActiveHomeFile(): Promise<{ editor: vscode.TextEditor; filePath: string } | null> {
    const editor = vscode.window.activeTextEditor;
    if (!editor || editor.document.languageId !== 'home') {
        vscode.window.showErrorMessage('No Home file is active');
        return null;
    }
    await editor.document.save();
    return { editor, filePath: editor.document.uri.fsPath };
}

async function runProgram(): Promise<void> {
    const ctx = await getActiveHomeFile();
    if (!ctx) return;

    const terminal = vscode.window.createTerminal('Home Run');
    terminal.show();
    terminal.sendText(`${shellQuote(getHomePath())} run ${shellQuote(ctx.filePath)}`);
}

async function buildProgram(): Promise<void> {
    const ctx = await getActiveHomeFile();
    if (!ctx) return;

    const outputPath = ctx.filePath.replace(/\.home$/, '');
    const terminal = vscode.window.createTerminal('Home Build');
    terminal.show();
    terminal.sendText(
        `${shellQuote(getHomePath())} build ${shellQuote(ctx.filePath)} -o ${shellQuote(outputPath)}`
    );
}

async function checkProgram(): Promise<void> {
    const ctx = await getActiveHomeFile();
    if (!ctx) return;

    const terminal = vscode.window.createTerminal('Home Check');
    terminal.show();
    terminal.sendText(`${shellQuote(getHomePath())} check ${shellQuote(ctx.filePath)}`);
}

async function runTests(): Promise<void> {
    const workspaceFolder = vscode.workspace.workspaceFolders?.[0];
    if (!workspaceFolder) {
        vscode.window.showErrorMessage('No workspace folder open');
        return;
    }

    const terminal = vscode.window.createTerminal({
        name: 'Home Tests',
        cwd: workspaceFolder.uri.fsPath,
    });
    terminal.show();
    terminal.sendText(`${shellQuote(getHomePath())} test`);
}

async function formatDocument(): Promise<void> {
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

function formatDocumentProvider(document: vscode.TextDocument): Promise<vscode.TextEdit[]> {
    return new Promise((resolve) => {
        const child = spawn(getHomePath(), ['format', '-'], {
            cwd: path.dirname(document.uri.fsPath),
        });

        let stdout = '';
        let stderr = '';

        child.stdin.write(document.getText());
        child.stdin.end();

        child.stdout.on('data', (data: Buffer) => { stdout += data.toString(); });
        child.stderr.on('data', (data: Buffer) => { stderr += data.toString(); });

        child.on('exit', (code) => {
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

        child.on('error', (error) => {
            vscode.window.showErrorMessage(`Formatting failed: ${error.message}`);
            resolve([]);
        });
    });
}

