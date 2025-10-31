import * as vscode from 'vscode';

/**
 * Workspace symbol provider for Home language
 * Enables searching for symbols across the entire workspace
 */
export class HomeWorkspaceSymbolProvider implements vscode.WorkspaceSymbolProvider {
    async provideWorkspaceSymbols(
        query: string,
        token: vscode.CancellationToken
    ): Promise<vscode.SymbolInformation[]> {
        const symbols: vscode.SymbolInformation[] = [];

        // Find all .home and .hm files in workspace
        const files = await vscode.workspace.findFiles('**/*.{home,hm}', '**/node_modules/**');

        for (const file of files) {
            if (token.isCancellationRequested) {
                break;
            }

            const document = await vscode.workspace.openTextDocument(file);
            const fileSymbols = await this.extractSymbols(document, query);
            symbols.push(...fileSymbols);
        }

        return symbols;
    }

    private async extractSymbols(
        document: vscode.TextDocument,
        query: string
    ): Promise<vscode.SymbolInformation[]> {
        const symbols: vscode.SymbolInformation[] = [];
        const lowerQuery = query.toLowerCase();

        for (let i = 0; i < document.lineCount; i++) {
            const line = document.lineAt(i);
            const text = line.text;

            // Function declarations
            const fnMatch = text.match(/^\s*(?:pub\s+)?fn\s+([a-zA-Z_][a-zA-Z0-9_]*)/);
            if (fnMatch && fnMatch[1].toLowerCase().includes(lowerQuery)) {
                const range = new vscode.Range(i, 0, i, text.length);
                symbols.push(new vscode.SymbolInformation(
                    fnMatch[1],
                    vscode.SymbolKind.Function,
                    '',
                    new vscode.Location(document.uri, range)
                ));
            }

            // Struct declarations
            const structMatch = text.match(/^\s*(?:pub\s+)?struct\s+([A-Z][a-zA-Z0-9_]*)/);
            if (structMatch && structMatch[1].toLowerCase().includes(lowerQuery)) {
                const range = new vscode.Range(i, 0, i, text.length);
                symbols.push(new vscode.SymbolInformation(
                    structMatch[1],
                    vscode.SymbolKind.Struct,
                    '',
                    new vscode.Location(document.uri, range)
                ));
            }

            // Enum declarations
            const enumMatch = text.match(/^\s*(?:pub\s+)?enum\s+([A-Z][a-zA-Z0-9_]*)/);
            if (enumMatch && enumMatch[1].toLowerCase().includes(lowerQuery)) {
                const range = new vscode.Range(i, 0, i, text.length);
                symbols.push(new vscode.SymbolInformation(
                    enumMatch[1],
                    vscode.SymbolKind.Enum,
                    '',
                    new vscode.Location(document.uri, range)
                ));
            }

            // Trait declarations
            const traitMatch = text.match(/^\s*(?:pub\s+)?trait\s+([A-Z][a-zA-Z0-9_]*)/);
            if (traitMatch && traitMatch[1].toLowerCase().includes(lowerQuery)) {
                const range = new vscode.Range(i, 0, i, text.length);
                symbols.push(new vscode.SymbolInformation(
                    traitMatch[1],
                    vscode.SymbolKind.Interface,
                    '',
                    new vscode.Location(document.uri, range)
                ));
            }

            // Type aliases
            const typeMatch = text.match(/^\s*(?:pub\s+)?type\s+([A-Z][a-zA-Z0-9_]*)/);
            if (typeMatch && typeMatch[1].toLowerCase().includes(lowerQuery)) {
                const range = new vscode.Range(i, 0, i, text.length);
                symbols.push(new vscode.SymbolInformation(
                    typeMatch[1],
                    vscode.SymbolKind.TypeParameter,
                    '',
                    new vscode.Location(document.uri, range)
                ));
            }

            // Constants
            const constMatch = text.match(/^\s*(?:pub\s+)?const\s+([A-Z_][A-Z0-9_]*)/);
            if (constMatch && constMatch[1].toLowerCase().includes(lowerQuery)) {
                const range = new vscode.Range(i, 0, i, text.length);
                symbols.push(new vscode.SymbolInformation(
                    constMatch[1],
                    vscode.SymbolKind.Constant,
                    '',
                    new vscode.Location(document.uri, range)
                ));
            }
        }

        return symbols;
    }
}

/**
 * Rename provider for Home language
 * Enables symbol renaming across files
 */
export class HomeRenameProvider implements vscode.RenameProvider {
    prepareRename(
        document: vscode.TextDocument,
        position: vscode.Position,
        token: vscode.CancellationToken
    ): vscode.ProviderResult<vscode.Range | { range: vscode.Range; placeholder: string }> {
        const wordRange = document.getWordRangeAtPosition(position);
        if (!wordRange) {
            return null;
        }

        const word = document.getText(wordRange);

        // Only allow renaming identifiers (not keywords)
        const keywords = ['fn', 'let', 'const', 'struct', 'enum', 'trait', 'impl', 'if', 'else', 'while', 'for', 'match'];
        if (keywords.includes(word)) {
            throw new Error('Cannot rename keyword');
        }

        return {
            range: wordRange,
            placeholder: word
        };
    }

    async provideRenameEdits(
        document: vscode.TextDocument,
        position: vscode.Position,
        newName: string,
        token: vscode.CancellationToken
    ): Promise<vscode.WorkspaceEdit> {
        const wordRange = document.getWordRangeAtPosition(position);
        if (!wordRange) {
            return new vscode.WorkspaceEdit();
        }

        const oldName = document.getText(wordRange);
        const edit = new vscode.WorkspaceEdit();

        // Find all files in workspace
        const files = await vscode.workspace.findFiles('**/*.{home,hm}', '**/node_modules/**');

        for (const file of files) {
            if (token.isCancellationRequested) {
                break;
            }

            const doc = await vscode.workspace.openTextDocument(file);
            const text = doc.getText();

            // Find all occurrences of the old name
            const regex = new RegExp(`\\b${this.escapeRegex(oldName)}\\b`, 'g');
            let match;

            while ((match = regex.exec(text)) !== null) {
                const startPos = doc.positionAt(match.index);
                const endPos = doc.positionAt(match.index + oldName.length);
                const range = new vscode.Range(startPos, endPos);

                edit.replace(file, range, newName);
            }
        }

        return edit;
    }

    private escapeRegex(str: string): string {
        return str.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    }
}

/**
 * Register workspace symbols and rename providers
 */
export function registerWorkspaceProviders(context: vscode.ExtensionContext) {
    // Workspace symbol provider
    context.subscriptions.push(
        vscode.languages.registerWorkspaceSymbolProvider(
            new HomeWorkspaceSymbolProvider()
        )
    );

    // Rename provider
    context.subscriptions.push(
        vscode.languages.registerRenameProvider(
            { language: 'home' },
            new HomeRenameProvider()
        )
    );
}
