import * as vscode from 'vscode';

/**
 * Code lens provider for Home language
 * Shows actionable information above functions and tests
 */
export class HomeCodeLensProvider implements vscode.CodeLensProvider {
    private _onDidChangeCodeLenses: vscode.EventEmitter<void> = new vscode.EventEmitter<void>();
    public readonly onDidChangeCodeLenses: vscode.Event<void> = this._onDidChangeCodeLenses.event;

    provideCodeLenses(
        document: vscode.TextDocument,
        token: vscode.CancellationToken
    ): vscode.ProviderResult<vscode.CodeLens[]> {
        const codeLenses: vscode.CodeLens[] = [];

        for (let i = 0; i < document.lineCount; i++) {
            const line = document.lineAt(i);
            const text = line.text;

            // Code lens for test functions
            const testMatch = /^\s*@test\s+fn\s+([a-zA-Z_][a-zA-Z0-9_]*)/;
            if (testMatch.test(text)) {
                codeLenses.push(...this.createTestCodeLenses(document, line, i));
            }

            // Code lens for regular functions
            const fnMatch = /^\s*(?:pub\s+)?fn\s+([a-zA-Z_][a-zA-Z0-9_]*)/;
            if (fnMatch.test(text) && !testMatch.test(text)) {
                codeLenses.push(...this.createFunctionCodeLenses(document, line, i));
            }

            // Code lens for main function
            if (text.match(/^\s*fn\s+main\s*\(/)) {
                codeLenses.push(...this.createMainCodeLenses(document, line, i));
            }

            // Code lens for trait implementations
            if (text.match(/^\s*impl\s+\w+\s+for\s+\w+/)) {
                codeLenses.push(...this.createImplCodeLenses(document, line, i));
            }
        }

        return codeLenses;
    }

    resolveCodeLens(
        codeLens: vscode.CodeLens,
        token: vscode.CancellationToken
    ): vscode.ProviderResult<vscode.CodeLens> {
        return codeLens;
    }

    private createTestCodeLenses(
        document: vscode.TextDocument,
        line: vscode.TextLine,
        lineNumber: number
    ): vscode.CodeLens[] {
        const codeLenses: vscode.CodeLens[] = [];
        const range = new vscode.Range(lineNumber, 0, lineNumber, line.text.length);

        const match = line.text.match(/@test\s+fn\s+([a-zA-Z_][a-zA-Z0-9_]*)/);
        if (!match) return codeLenses;

        const testName = match[1];

        // Run test
        codeLenses.push(new vscode.CodeLens(range, {
            title: '▶ Run Test',
            command: 'home.runTest',
            arguments: [document.uri.fsPath, testName]
        }));

        // Debug test
        codeLenses.push(new vscode.CodeLens(range, {
            title: '🐛 Debug Test',
            command: 'home.debugTest',
            arguments: [document.uri.fsPath, testName]
        }));

        return codeLenses;
    }

    private createFunctionCodeLenses(
        document: vscode.TextDocument,
        line: vscode.TextLine,
        lineNumber: number
    ): vscode.CodeLens[] {
        const codeLenses: vscode.CodeLens[] = [];
        const range = new vscode.Range(lineNumber, 0, lineNumber, line.text.length);

        // Count references
        codeLenses.push(new vscode.CodeLens(range, {
            title: '$(references) 0 references',
            command: 'editor.action.showReferences',
            arguments: [document.uri, range.start, []]
        }));

        // Generate test
        codeLenses.push(new vscode.CodeLens(range, {
            title: '$(beaker) Generate Test',
            command: 'home.generateTest',
            arguments: [document.uri, lineNumber]
        }));

        return codeLenses;
    }

    private createMainCodeLenses(
        document: vscode.TextDocument,
        line: vscode.TextLine,
        lineNumber: number
    ): vscode.CodeLens[] {
        const codeLenses: vscode.CodeLens[] = [];
        const range = new vscode.Range(lineNumber, 0, lineNumber, line.text.length);

        // Run program
        codeLenses.push(new vscode.CodeLens(range, {
            title: '▶ Run Program',
            command: 'home.run',
            arguments: []
        }));

        // Debug program
        codeLenses.push(new vscode.CodeLens(range, {
            title: '🐛 Debug Program',
            command: 'home.debugProgram',
            arguments: [document.uri.fsPath]
        }));

        // Build program
        codeLenses.push(new vscode.CodeLens(range, {
            title: '🔨 Build',
            command: 'home.build',
            arguments: []
        }));

        return codeLenses;
    }

    private createImplCodeLenses(
        document: vscode.TextDocument,
        line: vscode.TextLine,
        lineNumber: number
    ): vscode.CodeLens[] {
        const codeLenses: vscode.CodeLens[] = [];
        const range = new vscode.Range(lineNumber, 0, lineNumber, line.text.length);

        // Show trait definition
        codeLenses.push(new vscode.CodeLens(range, {
            title: '$(symbol-interface) Go to Trait',
            command: 'editor.action.goToTypeDefinition',
            arguments: []
        }));

        // Find other implementations
        codeLenses.push(new vscode.CodeLens(range, {
            title: '$(symbol-method) Find Implementations',
            command: 'editor.action.findImplementation',
            arguments: []
        }));

        return codeLenses;
    }

    public refresh(): void {
        this._onDidChangeCodeLenses.fire();
    }
}

/**
 * Register code lens provider and related commands
 */
export function registerCodeLensProvider(context: vscode.ExtensionContext) {
    const provider = new HomeCodeLensProvider();

    context.subscriptions.push(
        vscode.languages.registerCodeLensProvider(
            { language: 'home' },
            provider
        )
    );

    // Register code lens commands
    context.subscriptions.push(
        vscode.commands.registerCommand('home.runTest', async (filePath: string, testName: string) => {
            const terminal = vscode.window.createTerminal('Home Test');
            terminal.show();
            terminal.sendText(`home test ${filePath} --test ${testName}`);
        })
    );

    context.subscriptions.push(
        vscode.commands.registerCommand('home.debugTest', async (filePath: string, testName: string) => {
            await vscode.debug.startDebugging(undefined, {
                type: 'home',
                request: 'launch',
                name: `Debug Test: ${testName}`,
                program: filePath,
                args: ['--test', testName],
                stopOnEntry: true
            });
        })
    );

    context.subscriptions.push(
        vscode.commands.registerCommand('home.generateTest', async (uri: vscode.Uri, lineNumber: number) => {
            const document = await vscode.workspace.openTextDocument(uri);
            const line = document.lineAt(lineNumber);

            const fnMatch = line.text.match(/fn\s+([a-zA-Z_][a-zA-Z0-9_]*)/);
            if (fnMatch) {
                const funcName = fnMatch[1];
                const edit = new vscode.WorkspaceEdit();

                const closingBrace = findClosingBrace(document, lineNumber);
                if (closingBrace !== -1) {
                    const indent = line.text.match(/^\s*/)?.[0] || '';
                    const testCode = `\n${indent}@test fn test_${funcName}() {\n${indent}    let result = ${funcName}()\n${indent}    assert(true, "Test ${funcName}")\n${indent}}\n`;

                    edit.insert(uri, new vscode.Position(closingBrace + 1, 0), testCode);
                    await vscode.workspace.applyEdit(edit);
                    vscode.window.showInformationMessage(`Generated test for ${funcName}`);
                }
            }
        })
    );

    context.subscriptions.push(
        vscode.commands.registerCommand('home.debugProgram', async (filePath: string) => {
            await vscode.debug.startDebugging(undefined, {
                type: 'home',
                request: 'launch',
                name: 'Debug Program',
                program: filePath,
                stopOnEntry: false
            });
        })
    );

    // Refresh code lenses when document changes
    context.subscriptions.push(
        vscode.workspace.onDidChangeTextDocument(() => {
            provider.refresh();
        })
    );
}

function findClosingBrace(document: vscode.TextDocument, startLine: number): number {
    let braceCount = 0;
    let foundOpening = false;

    for (let i = startLine; i < document.lineCount; i++) {
        const line = document.lineAt(i).text;

        for (const char of line) {
            if (char === '{') {
                braceCount++;
                foundOpening = true;
            } else if (char === '}') {
                braceCount--;
                if (foundOpening && braceCount === 0) {
                    return i;
                }
            }
        }
    }

    return -1;
}
