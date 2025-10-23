import * as path from 'path';
import * as vscode from 'vscode';
import {
    LanguageClient,
    LanguageClientOptions,
    ServerOptions,
} from 'vscode-languageclient/node';
import { IonProfiler } from './profiler';
import { IonPackageManager } from './packageManager';

let client: LanguageClient;
let profiler: IonProfiler;
let packageManager: IonPackageManager;
let extensionContext: vscode.ExtensionContext;

export function activate(context: vscode.ExtensionContext) {
    console.log('Ion language extension is now active');
    extensionContext = context;

    // Initialize profiler and package manager
    profiler = new IonProfiler();
    packageManager = new IonPackageManager();

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

        // Profiler commands
        vscode.commands.registerCommand('ion.profiler.start', () => profiler.start()),
        vscode.commands.registerCommand('ion.profiler.stop', () => profiler.stop()),
        vscode.commands.registerCommand('ion.profiler.viewReport', () => profiler.viewReport()),

        // Package manager commands
        vscode.commands.registerCommand('ion.packageManager.search', () => packageManager.searchPackages()),
        vscode.commands.registerCommand('ion.packageManager.install', () => packageManager.installPackage()),
        vscode.commands.registerCommand('ion.packageManager.publish', () => packageManager.publishPackage()),
        vscode.commands.registerCommand('ion.packageManager.update', () => packageManager.updatePackages())
    );

    // Register formatters
    context.subscriptions.push(
        vscode.languages.registerDocumentFormattingEditProvider('ion', {
            provideDocumentFormattingEdits(document: vscode.TextDocument): Promise<vscode.TextEdit[]> {
                return formatDocumentProvider(document);
            }
        })
    );

    // Register code lens provider
    const config = vscode.workspace.getConfiguration('ion');
    if (config.get<boolean>('codelens.enabled')) {
        context.subscriptions.push(
            vscode.languages.registerCodeLensProvider('ion', new IonCodeLensProvider())
        );
    }

    // Format on save
    context.subscriptions.push(
        vscode.workspace.onWillSaveTextDocument(event => {
            const config = vscode.workspace.getConfiguration('ion');
            if (config.get<boolean>('format.onSave') && event.document.languageId === 'ion') {
                event.waitUntil(formatDocumentProvider(event.document));
            }
        })
    );

    // Start language server
    startLanguageServer(context);

    // Dispose resources
    context.subscriptions.push(profiler);
    context.subscriptions.push(packageManager);
}

export function deactivate(): Thenable<void> | undefined {
    if (profiler) {
        profiler.dispose();
    }
    if (packageManager) {
        packageManager.dispose();
    }
    if (!client) {
        return undefined;
    }
    return client.stop();
}

function startLanguageServer(context: vscode.ExtensionContext) {
    const config = vscode.workspace.getConfiguration('ion');
    const ionPath = config.get<string>('path') || 'ion';

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
        documentSelector: [{ scheme: 'file', language: 'ion' }],
        synchronize: {
            fileEvents: vscode.workspace.createFileSystemWatcher('**/*.ion'),
        },
    };

    // Create the language client
    client = new LanguageClient(
        'ionLanguageServer',
        'Ion Language Server',
        serverOptions,
        clientOptions
    );

    // Start the client (also starts the server)
    client.start();

    vscode.window.showInformationMessage('Ion Language Server started');
}

async function restartServer() {
    if (client) {
        await client.stop();
    }
    if (extensionContext) {
        startLanguageServer(extensionContext);
        vscode.window.showInformationMessage('Ion Language Server restarted');
    }
}

async function runProgram() {
    const editor = vscode.window.activeTextEditor;
    if (!editor || editor.document.languageId !== 'ion') {
        vscode.window.showErrorMessage('No Ion file is active');
        return;
    }

    await editor.document.save();

    const config = vscode.workspace.getConfiguration('ion');
    const ionPath = config.get<string>('path') || 'ion';
    const filePath = editor.document.uri.fsPath;

    const terminal = vscode.window.createTerminal('Ion Run');
    terminal.show();
    terminal.sendText(`${ionPath} run "${filePath}"`);
}

async function buildProgram() {
    const editor = vscode.window.activeTextEditor;
    if (!editor || editor.document.languageId !== 'ion') {
        vscode.window.showErrorMessage('No Ion file is active');
        return;
    }

    await editor.document.save();

    const config = vscode.workspace.getConfiguration('ion');
    const ionPath = config.get<string>('path') || 'ion';
    const filePath = editor.document.uri.fsPath;
    const outputPath = filePath.replace(/\.ion$/, '');

    const terminal = vscode.window.createTerminal('Ion Build');
    terminal.show();
    terminal.sendText(`${ionPath} build "${filePath}" -o "${outputPath}"`);
}

async function checkProgram() {
    const editor = vscode.window.activeTextEditor;
    if (!editor || editor.document.languageId !== 'ion') {
        vscode.window.showErrorMessage('No Ion file is active');
        return;
    }

    await editor.document.save();

    const config = vscode.workspace.getConfiguration('ion');
    const ionPath = config.get<string>('path') || 'ion';
    const filePath = editor.document.uri.fsPath;

    const terminal = vscode.window.createTerminal('Ion Check');
    terminal.show();
    terminal.sendText(`${ionPath} check "${filePath}"`);
}

async function runTests() {
    const workspaceFolder = vscode.workspace.workspaceFolders?.[0];
    if (!workspaceFolder) {
        vscode.window.showErrorMessage('No workspace folder open');
        return;
    }

    const config = vscode.workspace.getConfiguration('ion');
    const ionPath = config.get<string>('path') || 'ion';

    const terminal = vscode.window.createTerminal('Ion Tests');
    terminal.show();
    terminal.sendText(`cd "${workspaceFolder.uri.fsPath}" && ${ionPath} test`);
}

async function formatDocument() {
    const editor = vscode.window.activeTextEditor;
    if (!editor || editor.document.languageId !== 'ion') {
        vscode.window.showErrorMessage('No Ion file is active');
        return;
    }

    const edits = await formatDocumentProvider(editor.document);
    const workspaceEdit = new vscode.WorkspaceEdit();
    edits.forEach(edit => workspaceEdit.replace(editor.document.uri, edit.range, edit.newText));
    await vscode.workspace.applyEdit(workspaceEdit);
}

async function formatDocumentProvider(document: vscode.TextDocument): Promise<vscode.TextEdit[]> {
    const config = vscode.workspace.getConfiguration('ion');
    const ionPath = config.get<string>('path') || 'ion';

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

class IonCodeLensProvider implements vscode.CodeLensProvider {
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
