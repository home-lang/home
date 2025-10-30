import * as vscode from 'vscode';
import * as path from 'path';
import {
    LanguageClient,
    LanguageClientOptions,
    ServerOptions,
    TransportKind,
} from 'vscode-languageclient/node';

export function startLanguageServer(context: vscode.ExtensionContext): LanguageClient {
    const config = vscode.workspace.getConfiguration('home');
    const serverPath = getServerPath(config);

    // Server options
    const serverOptions: ServerOptions = {
        run: {
            command: serverPath,
            args: ['lsp'],
            transport: TransportKind.stdio,
        },
        debug: {
            command: serverPath,
            args: ['lsp'],
            transport: TransportKind.stdio,
        },
    };

    // Client options
    const clientOptions: LanguageClientOptions = {
        documentSelector: [
            { scheme: 'file', language: 'home' }
        ],
        synchronize: {
            fileEvents: vscode.workspace.createFileSystemWatcher('**/*.{home,hm}')
        },
        outputChannelName: 'Home Language Server',
        traceOutputChannel: vscode.window.createOutputChannel('Home LSP Trace'),
    };

    // Create the language client
    const client = new LanguageClient(
        'homeLanguageServer',
        'Home Language Server',
        serverOptions,
        clientOptions
    );

    // Start the client
    const disposable = client.start();
    context.subscriptions.push(disposable);

    // Handle client ready
    client.onReady().then(() => {
        console.log('Home Language Server is ready');

        // Show status bar item
        const statusBarItem = vscode.window.createStatusBarItem(
            vscode.StatusBarAlignment.Right,
            100
        );
        statusBarItem.text = '$(check) Home LSP';
        statusBarItem.tooltip = 'Home Language Server is running';
        statusBarItem.show();
        context.subscriptions.push(statusBarItem);

        // Handle server errors
        client.onDidChangeState((event) => {
            if (event.newState === 3) { // Stopped
                statusBarItem.text = '$(error) Home LSP';
                statusBarItem.tooltip = 'Home Language Server has stopped';
            } else if (event.newState === 2) { // Running
                statusBarItem.text = '$(check) Home LSP';
                statusBarItem.tooltip = 'Home Language Server is running';
            }
        });
    }).catch((error) => {
        console.error('Failed to start Home Language Server:', error);
        vscode.window.showErrorMessage(
            `Failed to start Home Language Server: ${error.message}`
        );
    });

    return client;
}

function getServerPath(config: vscode.WorkspaceConfiguration): string {
    const configPath = config.get<string>('lsp.path', '');

    if (configPath) {
        return configPath;
    }

    // Try to find the Home executable
    const possiblePaths = [
        // Development path
        path.join(process.env.HOME || '', 'Code', 'home', 'zig-out', 'bin', 'home'),
        // System paths
        '/usr/local/bin/home',
        '/usr/bin/home',
        // Fallback to PATH
        'home'
    ];

    // For now, use the development path if it exists
    const devPath = possiblePaths[0];
    const fs = require('fs');

    try {
        if (fs.existsSync(devPath)) {
            return devPath;
        }
    } catch (e) {
        // Ignore
    }

    // Default to assuming it's in PATH
    return 'home';
}
