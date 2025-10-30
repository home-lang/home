# VS Code Home Extension - Installation Guide

## Quick Installation

### Method 1: Install from VSIX (Recommended)

The extension has been packaged as `vscode-home-0.1.0.vsix` in the `vscode-home` directory.

```bash
# Install the extension
code --install-extension vscode-home/vscode-home-0.1.0.vsix

# Or install from within VS Code:
# 1. Open VS Code
# 2. Press Cmd+Shift+P (Mac) or Ctrl+Shift+P (Windows/Linux)
# 3. Type "Extensions: Install from VSIX..."
# 4. Navigate to vscode-home/vscode-home-0.1.0.vsix
# 5. Click "Install"
```

### Method 2: Development Installation

For development and testing:

```bash
cd vscode-home

# Install dependencies with Bun
~/.bun/bin/bun install

# Compile the extension
~/.bun/bin/bun run compile

# Open in VS Code
code .

# Press F5 to launch Extension Development Host
```

## Verifying Installation

1. Open VS Code
2. Create a new file with `.home` or `.hm` extension
3. Start typing - you should see:
   - Syntax highlighting
   - Code snippets (type `fn` and press Tab)
   - IntelliSense (if LSP server is running)

## Testing the Extension

A test file `test-sample.home` is included that demonstrates all syntax features:

```bash
# Open the test file
code vscode-home/test-sample.home
```

You should see:
- Keywords highlighted in different colors
- Operators properly colored
- Functions, types, and variables distinguished
- Comments styled correctly
- String literals with escape sequences

## Configuration

After installation, configure the extension:

1. Open VS Code Settings (Cmd+, or Ctrl+,)
2. Search for "home"
3. Configure:
   - `home.lsp.enabled` - Enable/disable LSP (default: true)
   - `home.lsp.path` - Path to Home compiler (leave empty for auto-detect)
   - `home.format.onSave` - Format on save (default: false)
   - `home.build.onSave` - Build on save (default: false)

## LSP Server Setup

For full IDE features, ensure the Home compiler is available:

```bash
# Verify Home is installed
home --version

# If LSP doesn't start automatically, set the path manually:
# In VS Code settings, set:
# "home.lsp.path": "/Users/YOUR_USERNAME/Code/home/zig-out/bin/home"
```

## Troubleshooting

### Extension not activating
- Check file extension is `.home` or `.hm`
- Reload window: Cmd+Shift+P → "Reload Window"

### No syntax highlighting
- Ensure file is recognized as "Home" language (bottom right corner)
- Try restarting VS Code

### LSP not working
- Check Home compiler is installed: `home --version`
- Set `home.lsp.path` in settings manually
- Check Output panel: View → Output → "Home Language Server"
- Restart LSP: Cmd+Shift+P → "Home: Restart Language Server"

### Build command not working
- Verify Home compiler is in PATH or set `home.lsp.path`
- Check terminal for error messages

## Development

To modify the extension:

```bash
cd vscode-home

# Make changes to source files
# src/extension.ts - Main extension logic
# src/lspClient.ts - LSP client
# syntaxes/home.tmLanguage.json - Syntax highlighting
# snippets/home.json - Code snippets
# language-configuration.json - Language settings

# Recompile
~/.bun/bin/bun run compile

# Repackage
~/.bun/bin/bunx @vscode/vsce package --no-dependencies

# Reinstall
code --install-extension vscode-home-0.1.0.vsix --force
```

## Uninstalling

```bash
# From command line
code --uninstall-extension home-lang.vscode-home

# Or from VS Code:
# 1. Go to Extensions view (Cmd+Shift+X)
# 2. Find "Home Language Support"
# 3. Click gear icon → Uninstall
```

## Next Steps

1. Open a Home project or create a new one:
   ```bash
   home init my-project
   cd my-project
   code .
   ```

2. Start coding with full IDE support:
   - IntelliSense (Ctrl+Space)
   - Go to Definition (F12)
   - Find References (Shift+F12)
   - Hover information
   - Real-time diagnostics

3. Use built-in commands:
   - `Home: Build Current File` (Cmd+Shift+B)
   - `Home: Run Current File`
   - `Home: Run Tests`
   - `Home: Format Document`

4. Try code snippets:
   - Type `fn` + Tab for function
   - Type `struct` + Tab for struct
   - Type `match` + Tab for match expression
   - See full list in snippets/home.json

Enjoy coding in Home! 🏠
