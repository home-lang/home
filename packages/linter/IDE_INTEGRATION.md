# IDE Integration Guide

This guide shows how to integrate the Home linter and formatter with various IDEs for auto-fix on save.

## VS Code

The Home language extension for VS Code includes built-in linter support.

### Settings

Add to your `.vscode/settings.json`:

```json
{
  // Enable linting
  "home.lint.enable": true,
  
  // Auto-fix on save
  "home.lint.autoFixOnSave": true,
  
  // Format on save
  "editor.formatOnSave": true,
  
  // Use Home formatter
  "[home]": {
    "editor.defaultFormatter": "home-lang.vscode-home",
    "editor.formatOnSave": true
  },
  
  // Linter severity levels
  "home.lint.severity": {
    "error": "error",
    "warning": "warning",
    "info": "information",
    "hint": "hint"
  }
}
```

### Workspace Settings

Create `.vscode/settings.json` in your project:

```json
{
  "home.lint.autoFixOnSave": true,
  "editor.codeActionsOnSave": {
    "source.fixAll.home": true
  }
}
```

The linter will automatically detect `home.jsonc`, `home.json`, `package.jsonc`, or `home.toml` in your project root.

## Neovim

### Using LSP

```lua
-- In your init.lua or lsp config
local lspconfig = require('lspconfig')

lspconfig.home_lsp.setup({
  settings = {
    home = {
      lint = {
        enable = true,
        autoFixOnSave = true,
      },
      format = {
        enable = true,
      },
    },
  },
  on_attach = function(client, bufnr)
    -- Auto-format on save
    vim.api.nvim_create_autocmd("BufWritePre", {
      buffer = bufnr,
      callback = function()
        vim.lsp.buf.format({ async = false })
      end,
    })
  end,
})
```

### Using null-ls

```lua
local null_ls = require("null-ls")

null_ls.setup({
  sources = {
    -- Home linter
    null_ls.builtins.diagnostics.home_lint,
    
    -- Home formatter
    null_ls.builtins.formatting.home_fmt,
  },
})
```

## Sublime Text

### Package Settings

Create `Home.sublime-settings`:

```json
{
  "lsp_format_on_save": true,
  "lsp_code_actions_on_save": {
    "source.fixAll.home": true
  }
}
```

## Emacs

### Using lsp-mode

```elisp
;; In your init.el
(use-package lsp-mode
  :hook (home-mode . lsp)
  :config
  (setq lsp-home-lint-enable t)
  (setq lsp-home-format-on-save t))

;; Auto-fix on save
(add-hook 'before-save-hook
          (lambda ()
            (when (eq major-mode 'home-mode)
              (lsp-format-buffer))))
```

## IntelliJ IDEA / WebStorm

### File Watcher

1. Go to Settings → Tools → File Watchers
2. Add new watcher:
   - Name: Home Lint
   - File type: Home
   - Scope: Project Files
   - Program: `home`
   - Arguments: `lint --fix $FilePath$`
   - Output paths: `$FilePath$`
   - Advanced Options:
     - ✓ Auto-save edited files to trigger the watcher
     - ✓ Trigger the watcher on external changes

### External Tools

1. Go to Settings → Tools → External Tools
2. Add new tool:
   - Name: Format Home File
   - Program: `home`
   - Arguments: `fmt $FilePath$`
   - Working directory: `$ProjectFileDir$`

## CLI Integration

### Pre-commit Hook

Create `.git/hooks/pre-commit`:

```bash
#!/bin/bash

# Get all staged .home files
FILES=$(git diff --cached --name-only --diff-filter=ACM | grep '\.home$')

if [ -n "$FILES" ]; then
  echo "Running Home linter..."
  
  for FILE in $FILES; do
    home lint --fix "$FILE"
    
    # Re-add the file if it was modified
    git add "$FILE"
  done
fi
```

Make it executable:

```bash
chmod +x .git/hooks/pre-commit
```

### Watch Mode

For development, you can use a file watcher:

```bash
# Using watchexec
watchexec -e home -- home lint --fix src/

# Using entr
find src -name "*.home" | entr home lint --fix /_
```

### CI/CD

#### GitHub Actions

```yaml
name: Lint

on: [push, pull_request]

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Setup Home
        uses: home-lang/setup-home@v1
      
      - name: Lint
        run: home lint src/
      
      - name: Check formatting
        run: |
          home fmt src/
          git diff --exit-code
```

#### GitLab CI

```yaml
lint:
  stage: test
  script:
    - home lint src/
    - home fmt src/
    - git diff --exit-code
```

## LSP Server Integration

The Home LSP server automatically provides linting and formatting capabilities.

### Capabilities

```json
{
  "textDocument": {
    "publishDiagnostics": true,
    "codeAction": {
      "codeActionLiteralSupport": {
        "codeActionKind": {
          "valueSet": ["source.fixAll.home", "quickfix"]
        }
      }
    }
  }
}
```

### Code Actions

The LSP provides these code actions:

- `source.fixAll.home` - Fix all auto-fixable issues
- `quickfix` - Quick fixes for specific diagnostics

### Custom Commands

- `home.lint.file` - Lint current file
- `home.lint.project` - Lint entire project
- `home.format.file` - Format current file
- `home.format.selection` - Format selection

## Configuration

### Project-level

Create `home.jsonc` in your project root (see main README for format).

### User-level

Create `~/.config/home/linter.jsonc` for global defaults:

```jsonc
{
  "linter": {
    "max_line_length": 120,
    "indent_size": 4,
    "use_spaces": true,
    "rules": {
      // Your preferred defaults
    }
  }
}
```

### Priority

1. `home.jsonc` in project root
2. `home.json` in project root
3. `package.jsonc` with `linter` field
4. `package.json` with `linter` field
5. `home.toml` with `[linter]` section
6. `~/.config/home/linter.jsonc`
7. Built-in defaults

## Troubleshooting

### Linter not running

1. Check that the Home LSP server is running
2. Verify your IDE settings
3. Check the LSP server logs

### Auto-fix not working

1. Ensure `auto_fix = true` for the rule
2. Check that the file is saved before auto-fix
3. Verify IDE settings for code actions on save

### Performance issues

1. Disable rules you don't need
2. Use `.lintignore` to exclude files
3. Increase LSP server timeout in IDE settings

## Example .lintignore

```text
# Dependencies
node_modules/
vendor/

# Build output
dist/
build/
*.o
*.a

# Generated files
**/*.gen.home

# Test fixtures
tests/fixtures/
```

## Support

For issues or questions:

- GitHub: https://github.com/home-lang/home
- Discord: https://discord.gg/home-lang
- Docs: https://home-lang.dev/docs/linter
