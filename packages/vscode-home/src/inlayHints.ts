import * as vscode from 'vscode';

/**
 * Inlay hints provider for Home language
 * Shows inline type information, parameter names, etc.
 */
export class HomeInlayHintsProvider implements vscode.InlayHintsProvider {
    provideInlayHints(
        document: vscode.TextDocument,
        range: vscode.Range,
        token: vscode.CancellationToken
    ): vscode.ProviderResult<vscode.InlayHint[]> {
        const hints: vscode.InlayHint[] = [];

        for (let lineNumber = range.start.line; lineNumber <= range.end.line; lineNumber++) {
            const line = document.lineAt(lineNumber);
            const text = line.text;

            // Type hints for let declarations without explicit type
            hints.push(...this.provideTypeHints(line, text));

            // Parameter name hints for function calls
            hints.push(...this.provideParameterHints(line, text));

            // Return type hints for functions without explicit return type
            hints.push(...this.provideReturnTypeHints(line, text));

            // Closure parameter type hints
            hints.push(...this.provideClosureTypeHints(line, text));
        }

        return hints;
    }

    private provideTypeHints(line: vscode.TextLine, text: string): vscode.InlayHint[] {
        const hints: vscode.InlayHint[] = [];

        // let x = value (without type annotation)
        const letMatch = /\b(let|const)\s+(mut\s+)?([a-zA-Z_][a-zA-Z0-9_]*)\s*=\s*([^;\n]+)/g;
        let match;

        while ((match = letMatch.exec(text)) !== null) {
            const varName = match[3];
            const value = match[4].trim();

            // Infer type from value
            const inferredType = this.inferType(value);
            if (inferredType) {
                const position = new vscode.Position(
                    line.lineNumber,
                    match.index + match[1].length + (match[2]?.length || 0) + 1 + varName.length
                );

                const hint = new vscode.InlayHint(
                    position,
                    `: ${inferredType}`,
                    vscode.InlayHintKind.Type
                );
                hint.paddingLeft = false;
                hint.paddingRight = false;
                hints.push(hint);
            }
        }

        return hints;
    }

    private provideParameterHints(line: vscode.TextLine, text: string): vscode.InlayHint[] {
        const hints: vscode.InlayHint[] = [];

        // function_call(arg1, arg2, arg3)
        const callMatch = /([a-zA-Z_][a-zA-Z0-9_]*)\s*\(([^)]+)\)/g;
        let match;

        while ((match = callMatch.exec(text)) !== null) {
            const funcName = match[1];
            const args = match[2];

            // Split arguments and add parameter name hints
            const argsList = args.split(',').map(a => a.trim());
            let currentOffset = match.index + funcName.length + 1;

            argsList.forEach((arg, index) => {
                // Skip if argument is already named (contains ':')
                if (!arg.includes(':') && !arg.match(/^["'`]/)) {
                    const position = new vscode.Position(line.lineNumber, currentOffset);
                    const hint = new vscode.InlayHint(
                        position,
                        `param${index}: `,
                        vscode.InlayHintKind.Parameter
                    );
                    hint.paddingLeft = false;
                    hint.paddingRight = false;
                    hints.push(hint);
                }
                currentOffset += arg.length + 2; // +2 for ", "
            });
        }

        return hints;
    }

    private provideReturnTypeHints(line: vscode.TextLine, text: string): vscode.InlayHint[] {
        const hints: vscode.InlayHint[] = [];

        // fn name(...) { without -> return_type
        const fnMatch = /\bfn\s+([a-zA-Z_][a-zA-Z0-9_]*)\s*(<[^>]+>)?\s*\(([^)]*)\)\s*\{/;
        const match = fnMatch.exec(text);

        if (match && !text.includes('->')) {
            const closeParen = text.indexOf(')', match.index);
            if (closeParen !== -1) {
                const position = new vscode.Position(line.lineNumber, closeParen + 1);

                const hint = new vscode.InlayHint(
                    position,
                    ' -> void',
                    vscode.InlayHintKind.Type
                );
                hint.paddingLeft = true;
                hint.paddingRight = false;
                hints.push(hint);
            }
        }

        return hints;
    }

    private provideClosureTypeHints(line: vscode.TextLine, text: string): vscode.InlayHint[] {
        const hints: vscode.InlayHint[] = [];

        // |param1, param2| expression
        const closureMatch = /\|([^|]+)\|/g;
        let match;

        while ((match = closureMatch.exec(text)) !== null) {
            const params = match[1];
            const paramsList = params.split(',').map(p => p.trim());

            paramsList.forEach((param) => {
                // Only add hint if parameter doesn't have type annotation
                if (!param.includes(':')) {
                    const paramIndex = match.index + 1 + match[1].indexOf(param) + param.length;
                    const position = new vscode.Position(line.lineNumber, paramIndex);

                    const hint = new vscode.InlayHint(
                        position,
                        ': T',
                        vscode.InlayHintKind.Type
                    );
                    hint.paddingLeft = false;
                    hint.paddingRight = false;
                    hints.push(hint);
                }
            });
        }

        return hints;
    }

    private inferType(value: string): string | null {
        // Integer literals
        if (/^\d+$/.test(value)) {
            return 'i32';
        }

        // Float literals
        if (/^\d+\.\d+$/.test(value)) {
            return 'f64';
        }

        // Boolean literals
        if (value === 'true' || value === 'false') {
            return 'bool';
        }

        // String literals
        if (/^["']/.test(value)) {
            return 'string';
        }

        // Array literals
        if (/^\[/.test(value)) {
            return 'Array<T>';
        }

        // Struct literals
        if (/^\w+\s*\{/.test(value)) {
            const structMatch = value.match(/^(\w+)\s*\{/);
            return structMatch ? structMatch[1] : null;
        }

        return null;
    }
}

/**
 * Register inlay hints provider
 */
export function registerInlayHintsProvider(context: vscode.ExtensionContext) {
    context.subscriptions.push(
        vscode.languages.registerInlayHintsProvider(
            { language: 'home' },
            new HomeInlayHintsProvider()
        )
    );
}
