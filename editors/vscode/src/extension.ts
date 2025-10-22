import * as path from 'path';
import * as vscode from 'vscode';
import {
    LanguageClient,
    LanguageClientOptions,
    ServerOptions,
} from 'vscode-languageclient/node';

let client: LanguageClient;

export function activate(context: vscode.ExtensionContext) {
    console.log('Ion language extension is now active');

    // Register commands
    context.subscriptions.push(
        vscode.commands.registerCommand('ion.restartServer', restartServer),
        vscode.commands.registerCommand('ion.run', runProgram),
        vscode.commands.registerCommand('ion.build', buildProgram),
        vscode.commands.registerCommand('ion.check', checkProgram)
    );

    // Start language server
    startLanguageServer(context);
}

export function deactivate(): Thenable<void> | undefined {
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
    const context = await getExtensionContext();
    if (context) {
        startLanguageServer(context);
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

async function getExtensionContext(): Promise<vscode.ExtensionContext | undefined> {
    // Helper to get context (simplified)
    return undefined;
}
