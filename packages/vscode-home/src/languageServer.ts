import * as vscode from 'vscode';
import * as path from 'path';
import { spawn, ChildProcess } from 'child_process';

/**
 * Home Language Server
 * Provides real-time type checking, diagnostics, and IntelliSense
 */

interface TypeCheckResult {
    file: string;
    line: number;
    column: number;
    severity: 'error' | 'warning' | 'info';
    message: string;
    code?: string;
}

interface CompletionItem {
    label: string;
    kind: string;
    detail?: string;
    documentation?: string;
    insertText?: string;
}

interface HoverInfo {
    contents: string[];
    range?: {
        start: { line: number; character: number };
        end: { line: number; character: number };
    };
}

interface StructInfo {
    name: string;
    fields: Array<{
        name: string;
        type: string;
        nullable: boolean;
    }>;
}

interface JsonImportInfo {
    filePath: string;
    variableName: string;
    jsonValue: any;
    position: {
        line: number;
        character: number;
    };
}

interface JsonValueInfo {
    value: any;
    type: 'string' | 'number' | 'boolean' | 'null' | 'object' | 'array';
    literalType: string; // Narrow literal type like "my-package" for strings
}

export class HomeLanguageServer {
    private diagnosticCollection: vscode.DiagnosticCollection;
    private serverProcess: ChildProcess | null = null;
    private structCache: Map<string, StructInfo> = new Map();
    private jsonImportCache: Map<string, JsonImportInfo> = new Map();
    private workspaceRoot: string;

    constructor(private context: vscode.ExtensionContext) {
        this.diagnosticCollection = vscode.languages.createDiagnosticCollection('home');
        this.workspaceRoot = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath || '';

        // Register providers
        this.registerProviders();

        // Start type checking on file changes
        this.setupFileWatchers();

        // Initial type check
        this.typeCheckWorkspace();
    }

    private registerProviders() {
        const selector: vscode.DocumentSelector = { scheme: 'file', language: 'home' };

        // Hover provider - show type information
        this.context.subscriptions.push(
            vscode.languages.registerHoverProvider(selector, {
                provideHover: (document, position, token) =>
                    this.provideHover(document, position, token)
            })
        );

        // Completion provider - autocomplete
        this.context.subscriptions.push(
            vscode.languages.registerCompletionItemProvider(selector, {
                provideCompletionItems: (document, position, token, context) =>
                    this.provideCompletionItems(document, position, token, context)
            }, '.', ':')
        );

        // Definition provider - go to definition
        this.context.subscriptions.push(
            vscode.languages.registerDefinitionProvider(selector, {
                provideDefinition: (document, position, token) =>
                    this.provideDefinition(document, position, token)
            })
        );

        // Signature help - function parameters
        this.context.subscriptions.push(
            vscode.languages.registerSignatureHelpProvider(selector, {
                provideSignatureHelp: (document, position, token, context) =>
                    this.provideSignatureHelp(document, position, token, context)
            }, '(', ',')
        );

        // Code actions - quick fixes
        this.context.subscriptions.push(
            vscode.languages.registerCodeActionsProvider(selector, {
                provideCodeActions: (document, range, context, token) =>
                    this.provideCodeActions(document, range, context, token)
            })
        );

        // Inlay hints - type annotations
        this.context.subscriptions.push(
            vscode.languages.registerInlayHintsProvider(selector, {
                provideInlayHints: (document, range, token) =>
                    this.provideInlayHints(document, range, token)
            })
        );
    }

    private setupFileWatchers() {
        // Type check on file save
        this.context.subscriptions.push(
            vscode.workspace.onDidSaveTextDocument((document) => {
                if (document.languageId === 'home') {
                    this.typeCheckDocument(document);
                }
            })
        );

        // Type check on file change (with debounce)
        let timeout: NodeJS.Timeout | null = null;
        this.context.subscriptions.push(
            vscode.workspace.onDidChangeTextDocument((event) => {
                if (event.document.languageId === 'home') {
                    if (timeout) clearTimeout(timeout);
                    timeout = setTimeout(() => {
                        this.typeCheckDocument(event.document);
                    }, 500); // 500ms debounce
                }
            })
        );

        // Type check on file open
        this.context.subscriptions.push(
            vscode.workspace.onDidOpenTextDocument((document) => {
                if (document.languageId === 'home') {
                    this.typeCheckDocument(document);
                }
            })
        );
    }

    /**
     * Type check a single document and show diagnostics
     */
    private async typeCheckDocument(document: vscode.TextDocument) {
        const diagnostics: vscode.Diagnostic[] = [];
        const text = document.getText();

        // Parse the document to find struct definitions
        this.parseStructs(document);

        // Parse JSON imports
        this.parseJsonImports(document);

        // Check for ORM type errors
        const ormErrors = this.checkORMTypes(document, text);
        diagnostics.push(...ormErrors);

        // Check for validation errors
        const validationErrors = this.checkValidation(document, text);
        diagnostics.push(...validationErrors);

        // Check for query builder errors
        const queryErrors = this.checkQueryBuilder(document, text);
        diagnostics.push(...queryErrors);

        // Check for general type errors
        const typeErrors = await this.runTypeChecker(document);
        diagnostics.push(...typeErrors);

        // Update diagnostics
        this.diagnosticCollection.set(document.uri, diagnostics);
    }

    /**
     * Parse struct definitions from the document
     */
    private parseStructs(document: vscode.TextDocument) {
        const text = document.getText();

        // Match struct definitions: const StructName = struct { ... }
        const structRegex = /const\s+(\w+)\s+=\s+struct\s*\{([^}]+)\}/g;
        let match;

        while ((match = structRegex.exec(text)) !== null) {
            const structName = match[1];
            const structBody = match[2];

            // Parse fields
            const fields: Array<{ name: string; type: string; nullable: boolean }> = [];
            const fieldRegex = /(\w+)\s*:\s*(\?)?([^,=\n]+)/g;
            let fieldMatch;

            while ((fieldMatch = fieldRegex.exec(structBody)) !== null) {
                const fieldName = fieldMatch[1];
                const nullable = fieldMatch[2] === '?';
                const fieldType = fieldMatch[3].trim();

                fields.push({ name: fieldName, type: fieldType, nullable });
            }

            this.structCache.set(structName, { name: structName, fields });
        }
    }

    /**
     * Parse JSON imports and cache their values
     */
    private parseJsonImports(document: vscode.TextDocument) {
        const text = document.getText();
        const fs = require('fs');

        // Match: const name = importJson("path/to/file.json")
        const importRegex = /const\s+(\w+)\s+=\s+importJson\("([^"]+)"\)/g;
        let match;

        while ((match = importRegex.exec(text)) !== null) {
            const variableName = match[1];
            const jsonPath = match[2];
            const position = document.positionAt(match.index);

            // Resolve JSON file path relative to workspace
            const fullPath = path.isAbsolute(jsonPath)
                ? jsonPath
                : path.join(this.workspaceRoot, jsonPath);

            try {
                // Read and parse JSON file
                const jsonContent = fs.readFileSync(fullPath, 'utf8');
                const jsonValue = JSON.parse(jsonContent);

                this.jsonImportCache.set(variableName, {
                    filePath: jsonPath,
                    variableName,
                    jsonValue,
                    position: {
                        line: position.line,
                        character: position.character
                    }
                });
            } catch (error) {
                // File not found or invalid JSON - will be caught by diagnostics
                console.error(`Failed to parse JSON import: ${jsonPath}`, error);
            }
        }

        // Also match: const pkg = PackageJson.import("package.json")
        const pkgImportRegex = /const\s+(\w+)\s+=\s+PackageJson\.import\("([^"]+)"\)/g;
        while ((match = pkgImportRegex.exec(text)) !== null) {
            const variableName = match[1];
            const jsonPath = match[2];
            const position = document.positionAt(match.index);

            const fullPath = path.isAbsolute(jsonPath)
                ? jsonPath
                : path.join(this.workspaceRoot, jsonPath);

            try {
                const jsonContent = fs.readFileSync(fullPath, 'utf8');
                const jsonValue = JSON.parse(jsonContent);

                this.jsonImportCache.set(variableName, {
                    filePath: jsonPath,
                    variableName,
                    jsonValue,
                    position: {
                        line: position.line,
                        character: position.character
                    }
                });
            } catch (error) {
                console.error(`Failed to parse package.json import: ${jsonPath}`, error);
            }
        }
    }

    /**
     * Get JSON value info with narrow type
     */
    private getJsonValueInfo(value: any): JsonValueInfo {
        if (value === null) {
            return { value, type: 'null', literalType: 'null' };
        }

        if (typeof value === 'string') {
            return { value, type: 'string', literalType: `"${value}"` };
        }

        if (typeof value === 'number') {
            return { value, type: 'number', literalType: value.toString() };
        }

        if (typeof value === 'boolean') {
            return { value, type: 'boolean', literalType: value.toString() };
        }

        if (Array.isArray(value)) {
            return { value, type: 'array', literalType: 'array' };
        }

        if (typeof value === 'object') {
            return { value, type: 'object', literalType: 'object' };
        }

        return { value, type: 'null', literalType: 'unknown' };
    }

    /**
     * Get JSON property access path (e.g., pkg.name, pkg.scripts.build)
     */
    private getJsonPropertyPath(text: string, position: vscode.Position): { varName: string; path: string[] } | null {
        const line = text.split('\n')[position.line];
        const beforeCursor = line.substring(0, position.character);

        // Match: variable.property.nested.path
        const pathRegex = /(\w+)(?:\.(\w+))+$/;
        const match = beforeCursor.match(pathRegex);

        if (!match) return null;

        const fullPath = match[0].split('.');
        const varName = fullPath[0];
        const path = fullPath.slice(1);

        return { varName, path };
    }

    /**
     * Resolve nested JSON value by path
     */
    private resolveJsonPath(obj: any, path: string[]): any {
        let current = obj;
        for (const key of path) {
            if (current && typeof current === 'object' && key in current) {
                current = current[key];
            } else {
                return undefined;
            }
        }
        return current;
    }

    /**
     * Check for ORM type errors (user.set with wrong types)
     */
    private checkORMTypes(document: vscode.TextDocument, text: string): vscode.Diagnostic[] {
        const diagnostics: vscode.Diagnostic[] = [];

        // Match: user.set("field", value)
        const setRegex = /(\w+)\.set\("(\w+)",\s*([^)]+)\)/g;
        let match;

        while ((match = setRegex.exec(text)) !== null) {
            const varName = match[1];
            const fieldName = match[2];
            const value = match[3].trim();

            // Get the struct type for this variable
            const structType = this.getVariableType(text, varName);
            if (!structType) continue;

            const structInfo = this.structCache.get(structType);
            if (!structInfo) continue;

            // Check if field exists
            const field = structInfo.fields.find(f => f.name === fieldName);
            if (!field) {
                const line = document.positionAt(match.index).line;
                const startChar = document.positionAt(match.index + match[0].indexOf(fieldName) - 1).character;
                const endChar = startChar + fieldName.length + 2; // Include quotes

                const diagnostic = new vscode.Diagnostic(
                    new vscode.Range(line, startChar, line, endChar),
                    `Field '${fieldName}' does not exist in struct '${structType}'`,
                    vscode.DiagnosticSeverity.Error
                );
                diagnostic.code = 'orm-field-not-found';
                diagnostic.source = 'home-orm';
                diagnostics.push(diagnostic);
                continue;
            }

            // Check type compatibility
            const expectedType = field.type;
            const actualType = this.inferValueType(value);

            if (!this.isTypeCompatible(expectedType, actualType)) {
                const line = document.positionAt(match.index).line;
                const valueStart = match.index + match[0].indexOf(value);
                const startChar = document.positionAt(valueStart).character;
                const endChar = startChar + value.length;

                const diagnostic = new vscode.Diagnostic(
                    new vscode.Range(line, startChar, line, endChar),
                    `Type mismatch: expected '${expectedType}', got '${actualType}'`,
                    vscode.DiagnosticSeverity.Error
                );
                diagnostic.code = 'orm-type-mismatch';
                diagnostic.source = 'home-orm';
                diagnostics.push(diagnostic);
            }
        }

        return diagnostics;
    }

    /**
     * Check for query builder errors (query.where with wrong fields)
     */
    private checkQueryBuilder(document: vscode.TextDocument, text: string): vscode.Diagnostic[] {
        const diagnostics: vscode.Diagnostic[] = [];

        // Match: query.where("field", "=", value)
        const whereRegex = /Query\((\w+)\)[\s\S]*?\.where\("(\w+)",/g;
        let match;

        while ((match = whereRegex.exec(text)) !== null) {
            const structType = match[1];
            const fieldName = match[2];

            const structInfo = this.structCache.get(structType);
            if (!structInfo) continue;

            // Check if field exists
            const field = structInfo.fields.find(f => f.name === fieldName);
            if (!field) {
                const line = document.positionAt(match.index).line;
                const fieldStart = match.index + match[0].indexOf(fieldName) - 1;
                const startChar = document.positionAt(fieldStart).character;
                const endChar = startChar + fieldName.length + 2;

                const diagnostic = new vscode.Diagnostic(
                    new vscode.Range(line, startChar, line, endChar),
                    `Field '${fieldName}' does not exist in struct '${structType}'. Did you mean: ${this.suggestField(fieldName, structInfo.fields)}?`,
                    vscode.DiagnosticSeverity.Error
                );
                diagnostic.code = 'query-field-not-found';
                diagnostic.source = 'home-query';
                diagnostics.push(diagnostic);
            }
        }

        // Match: query.orderBy("field", .asc)
        const orderByRegex = /Query\((\w+)\)[\s\S]*?\.orderBy\("(\w+)",/g;
        while ((match = orderByRegex.exec(text)) !== null) {
            const structType = match[1];
            const fieldName = match[2];

            const structInfo = this.structCache.get(structType);
            if (!structInfo) continue;

            const field = structInfo.fields.find(f => f.name === fieldName);
            if (!field) {
                const line = document.positionAt(match.index).line;
                const fieldStart = match.index + match[0].indexOf(fieldName) - 1;
                const startChar = document.positionAt(fieldStart).character;
                const endChar = startChar + fieldName.length + 2;

                const diagnostic = new vscode.Diagnostic(
                    new vscode.Range(line, startChar, line, endChar),
                    `Field '${fieldName}' does not exist in struct '${structType}'`,
                    vscode.DiagnosticSeverity.Error
                );
                diagnostic.code = 'orderby-field-not-found';
                diagnostic.source = 'home-query';
                diagnostics.push(diagnostic);
            }
        }

        return diagnostics;
    }

    /**
     * Check for validation errors
     */
    private checkValidation(document: vscode.TextDocument, text: string): vscode.Diagnostic[] {
        const diagnostics: vscode.Diagnostic[] = [];

        // Match: validator.field("fieldname")
        const fieldRegex = /validator\.field\("(\w+)"\)/g;
        let match;

        while ((match = fieldRegex.exec(text)) !== null) {
            const fieldName = match[1];

            // Check if field exists in any known struct
            // This is a simplified check - in production, track which struct is being validated
            let found = false;
            for (const structInfo of this.structCache.values()) {
                if (structInfo.fields.some(f => f.name === fieldName)) {
                    found = true;
                    break;
                }
            }

            if (!found && this.structCache.size > 0) {
                const line = document.positionAt(match.index).line;
                const startChar = document.positionAt(match.index + match[0].indexOf(fieldName) - 1).character;
                const endChar = startChar + fieldName.length + 2;

                const diagnostic = new vscode.Diagnostic(
                    new vscode.Range(line, startChar, line, endChar),
                    `Warning: Field '${fieldName}' not found in any struct definition`,
                    vscode.DiagnosticSeverity.Warning
                );
                diagnostic.code = 'validation-unknown-field';
                diagnostic.source = 'home-validation';
                diagnostics.push(diagnostic);
            }
        }

        return diagnostics;
    }

    /**
     * Get the type of a variable from its declaration
     */
    private getVariableType(text: string, varName: string): string | null {
        // Match: const varName = Model(StructType).init(...)
        const modelRegex = new RegExp(`const\\s+${varName}\\s+=\\s+.*Model\\((\\w+)\\)`, 'g');
        const match = modelRegex.exec(text);
        return match ? match[1] : null;
    }

    /**
     * Infer the type of a value
     */
    private inferValueType(value: string): string {
        value = value.trim();

        // String literals
        if (value.startsWith('"') || value.startsWith("'")) {
            return '[]const u8';
        }

        // Integer cast
        if (value.includes('@as(i32')) return 'i32';
        if (value.includes('@as(i64')) return 'i64';
        if (value.includes('@as(f32')) return 'f32';
        if (value.includes('@as(f64')) return 'f64';

        // Boolean
        if (value === 'true' || value === 'false') return 'bool';

        // Number literals
        if (/^\d+$/.test(value)) return 'comptime_int';
        if (/^\d+\.\d+$/.test(value)) return 'comptime_float';

        // null
        if (value === 'null') return 'null';

        return 'unknown';
    }

    /**
     * Check if types are compatible
     */
    private isTypeCompatible(expected: string, actual: string): boolean {
        if (expected === actual) return true;

        // Handle optional types
        if (expected.startsWith('?')) {
            const innerType = expected.substring(1);
            if (actual === 'null') return true;
            return this.isTypeCompatible(innerType, actual);
        }

        // comptime_int can coerce to int types
        if (actual === 'comptime_int' && (expected === 'i32' || expected === 'i64')) {
            return false; // Require explicit cast!
        }

        // comptime_float can coerce to float types
        if (actual === 'comptime_float' && (expected === 'f32' || expected === 'f64')) {
            return false; // Require explicit cast!
        }

        return false;
    }

    /**
     * Suggest a similar field name
     */
    private suggestField(typo: string, fields: Array<{ name: string; type: string }>): string {
        // Simple Levenshtein distance
        const distances = fields.map(f => ({
            name: f.name,
            distance: this.levenshteinDistance(typo, f.name)
        }));
        distances.sort((a, b) => a.distance - b.distance);
        return distances[0]?.name || 'unknown';
    }

    private levenshteinDistance(a: string, b: string): number {
        const matrix: number[][] = [];

        for (let i = 0; i <= b.length; i++) {
            matrix[i] = [i];
        }

        for (let j = 0; j <= a.length; j++) {
            matrix[0][j] = j;
        }

        for (let i = 1; i <= b.length; i++) {
            for (let j = 1; j <= a.length; j++) {
                if (b.charAt(i - 1) === a.charAt(j - 1)) {
                    matrix[i][j] = matrix[i - 1][j - 1];
                } else {
                    matrix[i][j] = Math.min(
                        matrix[i - 1][j - 1] + 1,
                        matrix[i][j - 1] + 1,
                        matrix[i - 1][j] + 1
                    );
                }
            }
        }

        return matrix[b.length][a.length];
    }

    /**
     * Run the Home compiler for type checking
     */
    private async runTypeChecker(document: vscode.TextDocument): Promise<vscode.Diagnostic[]> {
        // This would call the actual Home compiler with type checking
        // For now, return empty array
        return [];
    }

    /**
     * Provide hover information
     */
    private async provideHover(
        document: vscode.TextDocument,
        position: vscode.Position,
        token: vscode.CancellationToken
    ): Promise<vscode.Hover | null> {
        const wordRange = document.getWordRangeAtPosition(position);
        if (!wordRange) return null;

        const word = document.getText(wordRange);
        const line = document.lineAt(position.line).text;

        // Check if hovering over a struct field
        if (line.includes('.set(') || line.includes('.get(')) {
            // Find the variable name
            const varMatch = line.match(/(\w+)\.(set|get)\(/);
            if (varMatch) {
                const varName = varMatch[1];
                const structType = this.getVariableType(document.getText(), varName);

                if (structType) {
                    const structInfo = this.structCache.get(structType);
                    if (structInfo) {
                        const field = structInfo.fields.find(f => f.name === word);
                        if (field) {
                            const markdown = new vscode.MarkdownString();
                            markdown.appendCodeblock(`${field.name}: ${field.type}`, 'zig');
                            markdown.appendMarkdown(`\n\n**Struct**: ${structType}`);
                            if (field.nullable) {
                                markdown.appendMarkdown('\n\n*Nullable field*');
                            }
                            return new vscode.Hover(markdown, wordRange);
                        }
                    }
                }
            }
        }

        // Check if hovering over a struct name
        if (this.structCache.has(word)) {
            const structInfo = this.structCache.get(word)!;
            const markdown = new vscode.MarkdownString();
            markdown.appendCodeblock(`struct ${word}`, 'zig');
            markdown.appendMarkdown('\n\n**Fields:**\n');
            for (const field of structInfo.fields) {
                markdown.appendMarkdown(`\n- \`${field.name}: ${field.type}\``);
            }
            return new vscode.Hover(markdown, wordRange);
        }

        // Check if hovering over JSON import variable or property
        const jsonPath = this.getJsonPropertyPath(document.getText(), position);
        if (jsonPath) {
            const jsonImport = this.jsonImportCache.get(jsonPath.varName);
            if (jsonImport) {
                const value = this.resolveJsonPath(jsonImport.jsonValue, jsonPath.path);

                if (value !== undefined) {
                    const valueInfo = this.getJsonValueInfo(value);
                    const markdown = new vscode.MarkdownString();

                    // Show narrow literal type
                    markdown.appendCodeblock(valueInfo.literalType, 'typescript');

                    // Show actual value (formatted)
                    if (valueInfo.type === 'string') {
                        markdown.appendMarkdown(`\n\n**Value**: \`"${value}"\``);
                    } else if (valueInfo.type === 'object') {
                        markdown.appendMarkdown(`\n\n**Value**:\n\`\`\`json\n${JSON.stringify(value, null, 2)}\n\`\`\``);
                    } else if (valueInfo.type === 'array') {
                        markdown.appendMarkdown(`\n\n**Value**:\n\`\`\`json\n${JSON.stringify(value, null, 2)}\n\`\`\``);
                    } else {
                        markdown.appendMarkdown(`\n\n**Value**: \`${value}\``);
                    }

                    // Show source file
                    markdown.appendMarkdown(`\n\n*From*: \`${jsonImport.filePath}\``);

                    return new vscode.Hover(markdown, wordRange);
                }
            }
        }

        // Check if hovering over JSON import variable itself
        if (this.jsonImportCache.has(word)) {
            const jsonImport = this.jsonImportCache.get(word)!;
            const markdown = new vscode.MarkdownString();

            markdown.appendCodeblock(`const ${word} = importJson("${jsonImport.filePath}")`, 'zig');
            markdown.appendMarkdown('\n\n**JSON Import**\n');
            markdown.appendMarkdown(`\n*Source*: \`${jsonImport.filePath}\`\n`);

            // Show preview of JSON structure
            if (typeof jsonImport.jsonValue === 'object' && !Array.isArray(jsonImport.jsonValue)) {
                markdown.appendMarkdown('\n**Properties:**\n');
                const keys = Object.keys(jsonImport.jsonValue).slice(0, 10); // Show first 10 keys
                for (const key of keys) {
                    const valueInfo = this.getJsonValueInfo(jsonImport.jsonValue[key]);
                    markdown.appendMarkdown(`\n- \`${key}\`: ${valueInfo.literalType}`);
                }
                if (Object.keys(jsonImport.jsonValue).length > 10) {
                    markdown.appendMarkdown(`\n- ... and ${Object.keys(jsonImport.jsonValue).length - 10} more`);
                }
            } else if (Array.isArray(jsonImport.jsonValue)) {
                markdown.appendMarkdown(`\n**Array** with ${jsonImport.jsonValue.length} items`);
            }

            return new vscode.Hover(markdown, wordRange);
        }

        return null;
    }

    /**
     * Provide completion items (autocomplete)
     */
    private async provideCompletionItems(
        document: vscode.TextDocument,
        position: vscode.Position,
        token: vscode.CancellationToken,
        context: vscode.CompletionContext
    ): Promise<vscode.CompletionItem[]> {
        const line = document.lineAt(position.line).text;
        const beforeCursor = line.substring(0, position.character);

        const items: vscode.CompletionItem[] = [];

        // Autocomplete for user.set("field_name")
        if (beforeCursor.match(/\w+\.set\("$/)) {
            const varMatch = beforeCursor.match(/(\w+)\.set\("$/);
            if (varMatch) {
                const varName = varMatch[1];
                const structType = this.getVariableType(document.getText(), varName);

                if (structType) {
                    const structInfo = this.structCache.get(structType);
                    if (structInfo) {
                        for (const field of structInfo.fields) {
                            const item = new vscode.CompletionItem(field.name, vscode.CompletionItemKind.Field);
                            item.detail = field.type;
                            item.documentation = `Field of ${structType}`;
                            item.insertText = field.name;
                            items.push(item);
                        }
                    }
                }
            }
        }

        // Autocomplete for JSON import properties (e.g., pkg.)
        const jsonPropertyMatch = beforeCursor.match(/(\w+)\.$/);
        if (jsonPropertyMatch) {
            const varName = jsonPropertyMatch[1];
            const jsonImport = this.jsonImportCache.get(varName);

            if (jsonImport && typeof jsonImport.jsonValue === 'object' && !Array.isArray(jsonImport.jsonValue)) {
                for (const [key, value] of Object.entries(jsonImport.jsonValue)) {
                    const valueInfo = this.getJsonValueInfo(value);
                    const item = new vscode.CompletionItem(key, vscode.CompletionItemKind.Property);
                    item.detail = valueInfo.literalType;
                    item.documentation = new vscode.MarkdownString(`Value: \`${JSON.stringify(value)}\`\n\nFrom: \`${jsonImport.filePath}\``);
                    item.insertText = key;
                    items.push(item);
                }
            }
        }

        // Autocomplete for query.where("field_name")
        if (beforeCursor.match(/Query\(\w+\).*\.where\("$/)) {
            const queryMatch = document.getText().match(/Query\((\w+)\)/);
            if (queryMatch) {
                const structType = queryMatch[1];
                const structInfo = this.structCache.get(structType);

                if (structInfo) {
                    for (const field of structInfo.fields) {
                        const item = new vscode.CompletionItem(field.name, vscode.CompletionItemKind.Field);
                        item.detail = field.type;
                        item.documentation = `Filter by ${field.name}`;
                        item.insertText = field.name;
                        items.push(item);
                    }
                }
            }
        }

        return items;
    }

    /**
     * Provide definition (go to definition)
     */
    private async provideDefinition(
        document: vscode.TextDocument,
        position: vscode.Position,
        token: vscode.CancellationToken
    ): Promise<vscode.Location | null> {
        const wordRange = document.getWordRangeAtPosition(position);
        if (!wordRange) return null;

        const word = document.getText(wordRange);

        // Find struct definition
        if (this.structCache.has(word)) {
            const text = document.getText();
            const structRegex = new RegExp(`const\\s+${word}\\s+=\\s+struct`, 'g');
            const match = structRegex.exec(text);

            if (match) {
                const pos = document.positionAt(match.index);
                return new vscode.Location(document.uri, pos);
            }
        }

        return null;
    }

    /**
     * Provide signature help
     */
    private async provideSignatureHelp(
        document: vscode.TextDocument,
        position: vscode.Position,
        token: vscode.CancellationToken,
        context: vscode.SignatureHelpContext
    ): Promise<vscode.SignatureHelp | null> {
        // Could provide parameter hints for functions
        return null;
    }

    /**
     * Provide code actions (quick fixes)
     */
    private async provideCodeActions(
        document: vscode.TextDocument,
        range: vscode.Range,
        context: vscode.CompletionContext,
        token: vscode.CancellationToken
    ): Promise<vscode.CodeAction[]> {
        const actions: vscode.CodeAction[] = [];

        for (const diagnostic of context.diagnostics) {
            if (diagnostic.code === 'orm-type-mismatch') {
                // Suggest adding explicit cast
                const action = new vscode.CodeAction(
                    'Add explicit type cast',
                    vscode.CodeActionKind.QuickFix
                );
                action.diagnostics = [diagnostic];
                actions.push(action);
            }

            if (diagnostic.code === 'orm-field-not-found') {
                // Suggest correct field name
                if (diagnostic.message.includes('Did you mean')) {
                    const action = new vscode.CodeAction(
                        'Use suggested field name',
                        vscode.CodeActionKind.QuickFix
                    );
                    action.diagnostics = [diagnostic];
                    actions.push(action);
                }
            }
        }

        return actions;
    }

    /**
     * Provide inlay hints (inline type annotations)
     */
    private async provideInlayHints(
        document: vscode.TextDocument,
        range: vscode.Range,
        token: vscode.CancellationToken
    ): Promise<vscode.InlayHint[]> {
        const hints: vscode.InlayHint[] = [];
        const text = document.getText(range);

        // Show inferred types for variables
        const varRegex = /var\s+(\w+)\s+=\s+([^;]+);/g;
        let match;

        while ((match = varRegex.exec(text)) !== null) {
            const varName = match[1];
            const value = match[2];
            const type = this.inferValueType(value);

            if (type !== 'unknown') {
                const position = document.positionAt(range.start.character + match.index + match[1].length + 4);
                const hint = new vscode.InlayHint(
                    position,
                    `: ${type}`,
                    vscode.InlayHintKind.Type
                );
                hints.push(hint);
            }
        }

        return hints;
    }

    /**
     * Type check entire workspace
     */
    private async typeCheckWorkspace() {
        const files = await vscode.workspace.findFiles('**/*.zig', '**/node_modules/**');

        for (const file of files) {
            const document = await vscode.workspace.openTextDocument(file);
            if (document.languageId === 'home') {
                await this.typeCheckDocument(document);
            }
        }
    }

    public dispose() {
        this.diagnosticCollection.dispose();
        if (this.serverProcess) {
            this.serverProcess.kill();
        }
    }
}
