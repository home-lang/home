import * as fs from 'fs';
import * as path from 'path';
import * as vscode from 'vscode';
import {
    LanguageClient,
    LanguageClientOptions,
    ServerOptions,
    TransportKind
} from 'vscode-languageclient/node';

let client: LanguageClient | undefined;

export function activate(context: vscode.ExtensionContext) {
    console.log('Home Language extension is now active');

    // Get configuration
    const config = vscode.workspace.getConfiguration('homeLanguageServer');
    const serverPath = config.get<string>('path') || findLanguageServer();

    if (!serverPath) {
        vscode.window.showErrorMessage(
            'Home Language Server not found. Please configure the path in settings.'
        );
        return;
    }

    // Server options - use stdio to communicate with the server
    const serverOptions: ServerOptions = {
        run: { command: serverPath, transport: TransportKind.stdio },
        debug: { command: serverPath, transport: TransportKind.stdio }
    };

    // Client options - configure language support
    const clientOptions: LanguageClientOptions = {
        documentSelector: [{ scheme: 'file', language: 'home' }],
        synchronize: {
            fileEvents: vscode.workspace.createFileSystemWatcher('**/*.home')
        }
    };

    // Create the language client
    client = new LanguageClient(
        'homeLanguageServer',
        'Home Language Server',
        serverOptions,
        clientOptions
    );

    // Start the client (also starts the server)
    client.start();

    // Register commands
    context.subscriptions.push(
        vscode.commands.registerCommand('home.restartServer', async () => {
            if (!client) return;
            vscode.window.showInformationMessage('Restarting Home Language Server...');
            await client.stop();
            await client.start();
        })
    );
}

export function deactivate(): Thenable<void> | undefined {
    if (!client) {
        return undefined;
    }
    return client.stop();
}

function findLanguageServer(): string | undefined {
    const candidates = [
        path.join(__dirname, '..', '..', 'zig-out', 'bin', 'home-lsp'),
        path.join(__dirname, '..', '..', 'build', 'home-lsp'),
    ];

    for (const candidate of candidates) {
        try {
            if (fs.statSync(candidate).isFile()) return candidate;
        } catch {
            // continue
        }
    }

    // Fall back to PATH lookup
    return 'home-lsp';
}
