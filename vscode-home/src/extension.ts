import * as vscode from 'vscode';
import * as path from 'path';
import { LanguageClient } from 'vscode-languageclient/node';
import { startLanguageServer } from './lspClient';

let client: LanguageClient | undefined;

export function activate(context: vscode.ExtensionContext) {
    console.log('Home Language extension is now active');

    // Start LSP client if enabled
    const config = vscode.workspace.getConfiguration('home');
    if (config.get<boolean>('lsp.enabled', true)) {
        client = startLanguageServer(context);
    }

    // Register commands
    registerCommands(context);

    // Register task provider
    registerTaskProvider(context);

    // Setup auto-format on save
    setupAutoFormat(context);

    // Setup auto-build on save
    setupAutoBuild(context);
}

export function deactivate(): Thenable<void> | undefined {
    if (!client) {
        return undefined;
    }
    return client.stop();
}

function registerCommands(context: vscode.ExtensionContext) {
    // Restart Language Server
    context.subscriptions.push(
        vscode.commands.registerCommand('home.restartLanguageServer', async () => {
            if (client) {
                await client.stop();
                client = startLanguageServer(context);
                vscode.window.showInformationMessage('Home Language Server restarted');
            }
        })
    );

    // Build current file
    context.subscriptions.push(
        vscode.commands.registerCommand('home.build', async () => {
            const editor = vscode.window.activeTextEditor;
            if (!editor) {
                vscode.window.showErrorMessage('No active editor');
                return;
            }

            const document = editor.document;
            if (document.languageId !== 'home') {
                vscode.window.showErrorMessage('Not a Home file');
                return;
            }

            await document.save();
            const filePath = document.uri.fsPath;
            const homePath = getHomePath();

            const terminal = vscode.window.createTerminal('Home Build');
            terminal.show();
            terminal.sendText(`${homePath} build ${filePath}`);
        })
    );

    // Run current file
    context.subscriptions.push(
        vscode.commands.registerCommand('home.run', async () => {
            const editor = vscode.window.activeTextEditor;
            if (!editor) {
                vscode.window.showErrorMessage('No active editor');
                return;
            }

            const document = editor.document;
            if (document.languageId !== 'home') {
                vscode.window.showErrorMessage('Not a Home file');
                return;
            }

            await document.save();
            const filePath = document.uri.fsPath;
            const homePath = getHomePath();

            const terminal = vscode.window.createTerminal('Home Run');
            terminal.show();
            terminal.sendText(`${homePath} run ${filePath}`);
        })
    );

    // Run tests
    context.subscriptions.push(
        vscode.commands.registerCommand('home.test', async () => {
            const workspaceFolder = vscode.workspace.workspaceFolders?.[0];
            if (!workspaceFolder) {
                vscode.window.showErrorMessage('No workspace folder open');
                return;
            }

            const homePath = getHomePath();
            const terminal = vscode.window.createTerminal('Home Test');
            terminal.show();
            terminal.sendText(`cd ${workspaceFolder.uri.fsPath} && ${homePath} test tests/`);
        })
    );

    // Format document
    context.subscriptions.push(
        vscode.commands.registerCommand('home.format', async () => {
            const editor = vscode.window.activeTextEditor;
            if (!editor) {
                vscode.window.showErrorMessage('No active editor');
                return;
            }

            const document = editor.document;
            if (document.languageId !== 'home') {
                vscode.window.showErrorMessage('Not a Home file');
                return;
            }

            await vscode.commands.executeCommand('editor.action.formatDocument');
        })
    );
}

function registerTaskProvider(context: vscode.ExtensionContext) {
    const taskProvider = vscode.tasks.registerTaskProvider('home', {
        provideTasks: () => {
            const homePath = getHomePath();
            const tasks: vscode.Task[] = [];

            // Build task
            const buildTask = new vscode.Task(
                { type: 'home', task: 'build' },
                vscode.TaskScope.Workspace,
                'build',
                'home',
                new vscode.ShellExecution(`${homePath} build`)
            );
            buildTask.group = vscode.TaskGroup.Build;
            tasks.push(buildTask);

            // Test task
            const testTask = new vscode.Task(
                { type: 'home', task: 'test' },
                vscode.TaskScope.Workspace,
                'test',
                'home',
                new vscode.ShellExecution(`${homePath} test tests/`)
            );
            testTask.group = vscode.TaskGroup.Test;
            tasks.push(testTask);

            // Run task
            const runTask = new vscode.Task(
                { type: 'home', task: 'run' },
                vscode.TaskScope.Workspace,
                'run',
                'home',
                new vscode.ShellExecution(`${homePath} run src/main.home`)
            );
            tasks.push(runTask);

            return tasks;
        },
        resolveTask: () => {
            return undefined;
        }
    });

    context.subscriptions.push(taskProvider);
}

function setupAutoFormat(context: vscode.ExtensionContext) {
    context.subscriptions.push(
        vscode.workspace.onWillSaveTextDocument(async (event) => {
            const config = vscode.workspace.getConfiguration('home');
            if (!config.get<boolean>('format.onSave', false)) {
                return;
            }

            if (event.document.languageId === 'home') {
                const edit = await vscode.commands.executeCommand<vscode.TextEdit[]>(
                    'editor.action.formatDocument'
                );
                if (edit) {
                    event.waitUntil(Promise.resolve(edit));
                }
            }
        })
    );
}

function setupAutoBuild(context: vscode.ExtensionContext) {
    context.subscriptions.push(
        vscode.workspace.onDidSaveTextDocument(async (document) => {
            const config = vscode.workspace.getConfiguration('home');
            if (!config.get<boolean>('build.onSave', false)) {
                return;
            }

            if (document.languageId === 'home') {
                await vscode.commands.executeCommand('home.build');
            }
        })
    );
}

function getHomePath(): string {
    const config = vscode.workspace.getConfiguration('home');
    const configPath = config.get<string>('lsp.path', '');

    if (configPath) {
        return configPath;
    }

    // Try to find home in common locations
    const possiblePaths = [
        path.join(process.env.HOME || '', 'Code', 'home', 'zig-out', 'bin', 'home'),
        '/usr/local/bin/home',
        '/usr/bin/home',
        'home' // Assume it's in PATH
    ];

    // For now, just return 'home' and assume it's in PATH
    return 'home';
}
