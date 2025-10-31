import * as vscode from 'vscode';

/**
 * Code actions provider for Home language
 * Provides quick fixes and refactoring actions
 */
export class HomeCodeActionsProvider implements vscode.CodeActionProvider {
    public static readonly providedCodeActionKinds = [
        vscode.CodeActionKind.QuickFix,
        vscode.CodeActionKind.Refactor,
        vscode.CodeActionKind.RefactorExtract,
        vscode.CodeActionKind.RefactorInline,
        vscode.CodeActionKind.RefactorRewrite,
        vscode.CodeActionKind.Source,
    ];

    provideCodeActions(
        document: vscode.TextDocument,
        range: vscode.Range | vscode.Selection,
        context: vscode.CodeActionContext,
        token: vscode.CancellationToken
    ): vscode.ProviderResult<(vscode.CodeAction | vscode.Command)[]> {
        const actions: vscode.CodeAction[] = [];

        // Add missing import
        actions.push(...this.createAddImportActions(document, range, context));

        // Add missing error handling
        actions.push(...this.createAddErrorHandlingActions(document, range, context));

        // Convert to async
        actions.push(...this.createConvertToAsyncActions(document, range));

        // Extract function
        actions.push(...this.createExtractFunctionActions(document, range));

        // Extract variable
        actions.push(...this.createExtractVariableActions(document, range));

        // Implement trait
        actions.push(...this.createImplementTraitActions(document, range));

        // Add tests
        actions.push(...this.createAddTestActions(document, range));

        // Organize imports
        actions.push(...this.createOrganizeImportsActions(document));

        return actions;
    }

    private createAddImportActions(
        document: vscode.TextDocument,
        range: vscode.Range,
        context: vscode.CodeActionContext
    ): vscode.CodeAction[] {
        const actions: vscode.CodeAction[] = [];

        // Check for undefined identifier diagnostics
        for (const diagnostic of context.diagnostics) {
            if (diagnostic.message.includes('undefined') || diagnostic.message.includes('not found')) {
                const action = new vscode.CodeAction('Add missing import', vscode.CodeActionKind.QuickFix);
                action.diagnostics = [diagnostic];
                action.isPreferred = true;

                action.edit = new vscode.WorkspaceEdit();
                // Add import at top of file
                const importLine = 'import ' + this.extractIdentifier(diagnostic.message) + '\n';
                action.edit.insert(document.uri, new vscode.Position(0, 0), importLine);

                actions.push(action);
            }
        }

        return actions;
    }

    private createAddErrorHandlingActions(
        document: vscode.TextDocument,
        range: vscode.Range,
        context: vscode.CodeActionContext
    ): vscode.CodeAction[] {
        const actions: vscode.CodeAction[] = [];
        const line = document.lineAt(range.start.line);

        // Check if line contains function call without error handling
        if (line.text.match(/=\s*[a-zA-Z_][a-zA-Z0-9_]*\([^)]*\)/)) {
            const action = new vscode.CodeAction('Wrap in try-catch', vscode.CodeActionKind.QuickFix);
            action.edit = new vscode.WorkspaceEdit();

            const indent = line.text.match(/^\s*/)?.[0] || '';
            const wrappedCode = `${indent}try {\n${line.text}\n${indent}} catch (e) {\n${indent}    // Handle error\n${indent}}`;

            action.edit.replace(
                document.uri,
                line.range,
                wrappedCode
            );

            actions.push(action);
        }

        return actions;
    }

    private createConvertToAsyncActions(document: vscode.TextDocument, range: vscode.Range): vscode.CodeAction[] {
        const actions: vscode.CodeAction[] = [];
        const line = document.lineAt(range.start.line);

        // Check if this is a function declaration
        const fnMatch = line.text.match(/^(\s*)fn\s+([a-zA-Z_][a-zA-Z0-9_]*)/);
        if (fnMatch && !line.text.includes('async')) {
            const action = new vscode.CodeAction('Convert to async function', vscode.CodeActionKind.Refactor);
            action.edit = new vscode.WorkspaceEdit();

            const newText = line.text.replace(/\bfn\b/, 'async fn');
            action.edit.replace(document.uri, line.range, newText);

            actions.push(action);
        }

        return actions;
    }

    private createExtractFunctionActions(document: vscode.TextDocument, range: vscode.Range): vscode.CodeAction[] {
        const actions: vscode.CodeAction[] = [];

        // Only offer if selection spans multiple lines
        if (range.start.line < range.end.line) {
            const action = new vscode.CodeAction('Extract to function', vscode.CodeActionKind.RefactorExtract);
            action.edit = new vscode.WorkspaceEdit();

            const selectedText = document.getText(range);
            const indent = document.lineAt(range.start.line).text.match(/^\s*/)?.[0] || '';

            // Replace selection with function call
            action.edit.replace(document.uri, range, `${indent}extracted_function()`);

            // Add function definition
            const functionDef = `\n${indent}fn extracted_function() {\n${selectedText}\n${indent}}\n`;
            action.edit.insert(document.uri, new vscode.Position(range.end.line + 1, 0), functionDef);

            actions.push(action);
        }

        return actions;
    }

    private createExtractVariableActions(document: vscode.TextDocument, range: vscode.Range): vscode.CodeAction[] {
        const actions: vscode.CodeAction[] = [];

        if (!range.isEmpty) {
            const action = new vscode.CodeAction('Extract to variable', vscode.CodeActionKind.RefactorExtract);
            action.edit = new vscode.WorkspaceEdit();

            const selectedText = document.getText(range);
            const indent = document.lineAt(range.start.line).text.match(/^\s*/)?.[0] || '';

            // Replace selection with variable name
            action.edit.replace(document.uri, range, 'extracted_value');

            // Add variable declaration before current line
            const varDecl = `${indent}let extracted_value = ${selectedText}\n`;
            action.edit.insert(document.uri, new vscode.Position(range.start.line, 0), varDecl);

            actions.push(action);
        }

        return actions;
    }

    private createImplementTraitActions(document: vscode.TextDocument, range: vscode.Range): vscode.CodeAction[] {
        const actions: vscode.CodeAction[] = [];
        const line = document.lineAt(range.start.line);

        // Check if this is a struct or enum definition
        const typeMatch = line.text.match(/^(\s*)(struct|enum)\s+([A-Z][a-zA-Z0-9_]*)/);
        if (typeMatch) {
            const action = new vscode.CodeAction(
                `Generate trait implementation for ${typeMatch[3]}`,
                vscode.CodeActionKind.Source
            );
            action.edit = new vscode.WorkspaceEdit();

            const indent = typeMatch[1];
            const typeName = typeMatch[3];
            const implTemplate = `\n${indent}impl TraitName for ${typeName} {\n${indent}    fn method(&self) -> void {\n${indent}        // TODO: Implementation\n${indent}    }\n${indent}}\n`;

            // Add implementation after the type definition
            const closingBrace = this.findClosingBrace(document, range.start.line);
            if (closingBrace !== -1) {
                action.edit.insert(document.uri, new vscode.Position(closingBrace + 1, 0), implTemplate);
            }

            actions.push(action);
        }

        return actions;
    }

    private createAddTestActions(document: vscode.TextDocument, range: vscode.Range): vscode.CodeAction[] {
        const actions: vscode.CodeAction[] = [];
        const line = document.lineAt(range.start.line);

        // Check if this is a function that doesn't have @test
        const fnMatch = line.text.match(/^(\s*)fn\s+([a-zA-Z_][a-zA-Z0-9_]*)/);
        if (fnMatch && !line.text.includes('@test')) {
            const action = new vscode.CodeAction('Generate test for this function', vscode.CodeActionKind.Source);
            action.edit = new vscode.WorkspaceEdit();

            const indent = fnMatch[1];
            const funcName = fnMatch[2];
            const testTemplate = `\n${indent}@test fn test_${funcName}() {\n${indent}    // Arrange\n${indent}    \n${indent}    // Act\n${indent}    let result = ${funcName}()\n${indent}    \n${indent}    // Assert\n${indent}    assert(true, "Test ${funcName}")\n${indent}}\n`;

            // Add test after the function
            const closingBrace = this.findClosingBrace(document, range.start.line);
            if (closingBrace !== -1) {
                action.edit.insert(document.uri, new vscode.Position(closingBrace + 1, 0), testTemplate);
            }

            actions.push(action);
        }

        return actions;
    }

    private createOrganizeImportsActions(document: vscode.TextDocument): vscode.CodeAction[] {
        const actions: vscode.CodeAction[] = [];

        const action = new vscode.CodeAction('Organize imports', vscode.CodeActionKind.SourceOrganizeImports);
        action.edit = new vscode.WorkspaceEdit();

        // Collect all imports
        const imports: string[] = [];
        const importRanges: vscode.Range[] = [];

        for (let i = 0; i < document.lineCount; i++) {
            const line = document.lineAt(i);
            if (line.text.match(/^import\s+/)) {
                imports.push(line.text);
                importRanges.push(line.range);
            }
        }

        if (imports.length > 0) {
            // Sort imports alphabetically
            const sortedImports = [...imports].sort();

            // Replace all import lines with sorted versions
            for (let i = 0; i < importRanges.length; i++) {
                action.edit.replace(document.uri, importRanges[i], sortedImports[i]);
            }

            actions.push(action);
        }

        return actions;
    }

    private findClosingBrace(document: vscode.TextDocument, startLine: number): number {
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

    private extractIdentifier(message: string): string {
        const match = message.match(/['"`]([a-zA-Z_][a-zA-Z0-9_]*)['"`]/);
        return match ? match[1] : 'module';
    }
}

/**
 * Register code actions provider
 */
export function registerCodeActionsProvider(context: vscode.ExtensionContext) {
    context.subscriptions.push(
        vscode.languages.registerCodeActionsProvider(
            { language: 'home' },
            new HomeCodeActionsProvider(),
            {
                providedCodeActionKinds: HomeCodeActionsProvider.providedCodeActionKinds
            }
        )
    );
}
