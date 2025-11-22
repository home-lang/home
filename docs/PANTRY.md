# Pantry Integration

## Overview

Home uses **Pantry** for system-level package management. Pantry is kept **separate** from the Home language itself to maintain clean separation of concerns.

## Files

- `pantry.json` - Declares Home's system dependencies (e.g., Zig compiler)
- `pantry-lock.json` - Lockfile for reproducible builds

## Usage

### System Packages

Use `pantry` directly (not through Home):

```bash
pantry install nodejs.org
pantry list
pantry search python
pantry update
```

### Shell Integration

Pantry integrates with your shell for automatic environment activation on `cd`:

```bash
# Handled by pantry's zshrc integration
cd ~/Code/my-project  # Automatically activates environment
```

## Why Separate?

**Home is a programming language**, not a system management tool.

**Pantry is a system package manager**, handling:
- System dependencies (Node.js, Python, etc.)
- Development environments
- Shell integration for `cd` hooks

Keeping them separate means:
- ✅ Home stays focused as a language compiler/interpreter
- ✅ Pantry handles system concerns independently
- ✅ No bloat in the language tooling
- ✅ Clean architecture for home-os future

## For Home Development

The `pantry.json` file declares what Home itself needs to build (currently just Zig 0.16.0).

## For Home-OS

When building the OS, this separation becomes even more important - the OS will have its own package management layer, and Home remains just the programming language.
