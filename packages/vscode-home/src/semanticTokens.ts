import * as vscode from 'vscode';

// Semantic token types supported by Home language
export const tokenTypes = [
    'namespace',
    'class',
    'enum',
    'interface',
    'struct',
    'typeParameter',
    'type',
    'parameter',
    'variable',
    'property',
    'enumMember',
    'function',
    'method',
    'macro',
    'keyword',
    'modifier',
    'comment',
    'string',
    'number',
    'regexp',
    'operator',
] as const;

export type TokenType = (typeof tokenTypes)[number];

// Semantic token modifiers
export const tokenModifiers = [
    'declaration',
    'definition',
    'readonly',
    'static',
    'deprecated',
    'abstract',
    'async',
    'modification',
    'documentation',
    'defaultLibrary',
] as const;

export type TokenModifier = (typeof tokenModifiers)[number];

// Register semantic tokens legend
export const legend = new vscode.SemanticTokensLegend(
    tokenTypes as readonly string[] as string[],
    tokenModifiers as readonly string[] as string[],
);

/**
 * Semantic tokens provider for Home language
 * Provides enhanced syntax highlighting beyond TextMate grammar
 */
export class HomeSemanticTokensProvider implements vscode.DocumentSemanticTokensProvider {
    async provideDocumentSemanticTokens(
        document: vscode.TextDocument,
        token: vscode.CancellationToken
    ): Promise<vscode.SemanticTokens> {
        const tokensBuilder = new vscode.SemanticTokensBuilder(legend);

        // Parse document and build semantic tokens
        for (let i = 0; i < document.lineCount; i++) {
            const line = document.lineAt(i);
            this.parseLineForTokens(line, tokensBuilder);
        }

        return tokensBuilder.build();
    }

    private parseLineForTokens(line: vscode.TextLine, builder: vscode.SemanticTokensBuilder) {
        const text = line.text;

        // Function declarations: fn name(...)
        const fnMatch = /\b(fn)\s+([a-zA-Z_][a-zA-Z0-9_]*)/g;
        let match;
        while ((match = fnMatch.exec(text)) !== null) {
            // 'fn' keyword
            builder.push(
                line.lineNumber,
                match.index,
                match[1].length,
                this.getTokenType('keyword'),
                0
            );

            // function name
            builder.push(
                line.lineNumber,
                match.index + match[1].length + 1,
                match[2].length,
                this.getTokenType('function'),
                this.getTokenModifier('declaration')
            );
        }

        // Struct/Enum/Union/Trait declarations
        const typeMatch = /\b(struct|enum|union|trait)\s+([A-Z][a-zA-Z0-9_]*)/g;
        while ((match = typeMatch.exec(text)) !== null) {
            builder.push(
                line.lineNumber,
                match.index + match[1].length + 1,
                match[2].length,
                this.getTokenType('struct'),
                this.getTokenModifier('declaration')
            );
        }

        // Type annotations: : Type
        const typeAnnotMatch = /:\s*([A-Z][a-zA-Z0-9_]*)/g;
        while ((match = typeAnnotMatch.exec(text)) !== null) {
            builder.push(
                line.lineNumber,
                match.index + match[0].indexOf(match[1]),
                match[1].length,
                this.getTokenType('type'),
                0
            );
        }

        // Parameters in function definitions
        const paramMatch = /\(([^)]*)\)/g;
        while ((match = paramMatch.exec(text)) !== null) {
            const params = match[1];
            const paramNames = /([a-zA-Z_][a-zA-Z0-9_]*)\s*:/g;
            let paramNameMatch;
            const baseOffset = match.index + 1;

            while ((paramNameMatch = paramNames.exec(params)) !== null) {
                builder.push(
                    line.lineNumber,
                    baseOffset + paramNameMatch.index,
                    paramNameMatch[1].length,
                    this.getTokenType('parameter'),
                    0
                );
            }
        }

        // Macro/attribute annotations: @test, @TypeOf, etc.
        const macroMatch = /@([a-zA-Z_][a-zA-Z0-9_]*)/g;
        while ((match = macroMatch.exec(text)) !== null) {
            builder.push(
                line.lineNumber,
                match.index,
                match[0].length,
                this.getTokenType('macro'),
                0
            );
        }

        // Async/await keywords
        const asyncMatch = /\b(async|await)\b/g;
        while ((match = asyncMatch.exec(text)) !== null) {
            builder.push(
                line.lineNumber,
                match.index,
                match[1].length,
                this.getTokenType('keyword'),
                this.getTokenModifier('async')
            );
        }

        // let/const with mut modifier — `const` and bare `let` are immutable;
        // `let mut` is mutable.
        const varMatch = /\b(let|const)(\s+mut)?\s+([a-zA-Z_][a-zA-Z0-9_]*)/g;
        while ((match = varMatch.exec(text)) !== null) {
            const keyword = match[1];
            const mutToken = match[2];
            const varName = match[3];
            const varOffset = match.index + keyword.length + (mutToken?.length ?? 0) + 1;
            const isImmutable = keyword === 'const' || !mutToken;

            builder.push(
                line.lineNumber,
                varOffset,
                varName.length,
                this.getTokenType('variable'),
                isImmutable ? this.getTokenModifier('readonly') : 0,
            );
        }

        // Enum members: EnumName::Member
        const enumMemberMatch = /\b([A-Z][a-zA-Z0-9_]*)::([A-Z][a-zA-Z0-9_]*)/g;
        while ((match = enumMemberMatch.exec(text)) !== null) {
            builder.push(
                line.lineNumber,
                match.index + match[1].length + 2,
                match[2].length,
                this.getTokenType('enumMember'),
                0
            );
        }
    }

    private getTokenType(type: TokenType): number {
        const index = (tokenTypes as readonly string[]).indexOf(type);
        return index >= 0 ? index : 0;
    }

    private getTokenModifier(...modifiers: TokenModifier[]): number {
        let result = 0;
        for (const modifier of modifiers) {
            const index = (tokenModifiers as readonly string[]).indexOf(modifier);
            if (index >= 0) {
                result |= (1 << index);
            }
        }
        return result;
    }
}
