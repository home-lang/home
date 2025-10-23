# Home Configuration Files

Ion supports multiple configuration file formats for maximum flexibility and compatibility with existing ecosystems.

## Supported Formats (Priority Order)

Ion will automatically detect and load configuration from the first file it finds:

1. **`ion.jsonc`** ⭐ **Recommended** - JSON with comments
2. **`ion.json`** - Standard JSON
3. **`package.jsonc`** - NPM-compatible with comments
4. **`package.json`** - NPM-compatible
5. **`ion.toml`** - TOML format (legacy support)

## Why JSONC?

We recommend **`ion.jsonc`** for Home projects because:

- ✅ **Comments** - Document your config inline
- ✅ **Familiar** - JSON syntax everyone knows
- ✅ **Editor Support** - Great tooling in VS Code and other editors
- ✅ **Flexible** - Trailing commas allowed
- ✅ **Modern** - Used by TypeScript, VS Code, and more

## Configuration Examples

### ion.jsonc (Recommended)

```jsonc
{
  // Project metadata
  "name": "my-awesome-app",
  "version": "1.0.0",
  "description": "My awesome Home application",

  // Dependencies with semver ranges
  "dependencies": {
    "http": "^2.1.0",        // Caret range - compatible versions
    "database": "~1.5.0",    // Tilde range - patch updates only
    "utils": "1.0.0",        // Exact version

    // Git dependencies
    "awesome-lib": {
      "git": "https://github.com/user/awesome-lib.git",
      "rev": "v1.2.3"  // Tag, branch, or commit
    },

    // GitHub shortcuts (user/repo expands to https://github.com/user/repo.git)
    "another-lib": {
      "git": "user/another-lib",
      "rev": "main"
    },

    // Direct URL dependencies
    "custom-package": {
      "url": "https://example.com/package.tar.gz"
    }
  },

  // Development dependencies (not included in production builds)
  "devDependencies": {
    "test-framework": "^1.0.0",
    "benchmarks": "^0.5.0"
  },

  // Scripts (Bun-style)
  "scripts": {
    "dev": "ion run src/main.home --watch",
    "build": "ion build --release",
    "test": "ion test",
    "bench": "ion bench"
  },

  // Workspaces for monorepos (Bun-style)
  "workspaces": [
    "packages/*",
    "apps/*"
  ]
}
```

### ion.json (Simple)

```json
{
  "name": "simple-project",
  "version": "1.0.0",
  "dependencies": {
    "std": "^1.0.0",
    "http": "^2.0.0"
  }
}
```

### package.jsonc (Hybrid Node.js + Ion)

Perfect for projects that use both Node.js and Ion:

```jsonc
{
  // NPM-compatible package.jsonc
  "name": "@myorg/hybrid-app",
  "version": "2.0.0",

  "dependencies": {
    // Home dependencies
    "home-http": "^1.0.0",
    "home-db": "^2.0.0",

    // NPM dependencies can coexist
    "express": "^4.18.0"
  },

  "scripts": {
    // Home scripts
    "start:ion": "ion run src/main.home",
    "build:ion": "ion build",

    // Node.js scripts
    "start:node": "node dist/index.js"
  }
}
```

### package.json (NPM Compatible)

```json
{
  "name": "@myorg/my-app",
  "version": "1.0.0",
  "dependencies": {
    "home-core": "^1.0.0"
  }
}
```

## Semver Ranges

Ion supports standard semantic versioning ranges:

| Range | Meaning | Example |
|-------|---------|---------|
| `1.2.3` | Exact version | Installs exactly 1.2.3 |
| `^1.2.3` | Compatible with 1.2.3 | Allows 1.2.4, 1.3.0 but not 2.0.0 |
| `~1.2.3` | Patch updates only | Allows 1.2.4 but not 1.3.0 |
| `>=1.2.3` | Greater than or equal | Allows any version >= 1.2.3 |

## Git Dependencies

### Full Git URL

```jsonc
{
  "dependencies": {
    "my-lib": {
      "git": "https://github.com/user/my-lib.git",
      "rev": "v1.0.0"  // Can be tag, branch, or commit SHA
    }
  }
}
```

### GitHub Shortcuts

Ion automatically expands `user/repo` to `https://github.com/user/repo.git`:

```jsonc
{
  "dependencies": {
    "my-lib": {
      "git": "user/my-lib",  // Expands to https://github.com/user/my-lib.git
      "rev": "main"
    }
  }
}
```

## URL Dependencies

Install packages from direct URLs:

```jsonc
{
  "dependencies": {
    "custom-lib": {
      "url": "https://example.com/packages/custom-lib-1.0.0.tar.gz"
    }
  }
}
```

## JSONC Comments

JSONC supports both single-line and multi-line comments:

```jsonc
{
  // Single-line comment
  "name": "my-project",

  /*
   * Multi-line comment
   * Can span multiple lines
   */
  "version": "1.0.0",

  "dependencies": {
    "http": "^2.0.0"  // Inline comment
  }
}
```

## Migration Guide

### From ion.toml to ion.jsonc

**Before (ion.toml):**
```toml
[package]
name = "my-project"
version = "1.0.0"

[dependencies]
http = "2.0.0"
database = { git = "https://github.com/user/db.git", rev = "v1.0.0" }
```

**After (ion.jsonc):**
```jsonc
{
  "name": "my-project",
  "version": "1.0.0",
  "dependencies": {
    "http": "^2.0.0",
    "database": {
      "git": "user/db",  // GitHub shortcut!
      "rev": "v1.0.0"
    }
  }
}
```

### From package.json to ion.jsonc

Simply rename `package.json` to `ion.jsonc` and add comments as needed! Home is fully compatible with the package.json format.

## Best Practices

1. **Use ion.jsonc** - It's the recommended format for pure Home projects
2. **Use package.jsonc** - For hybrid Node.js + Home projects
3. **Add comments** - Document why you're using specific versions
4. **Use semver ranges** - Stay up to date with compatible versions
5. **Pin critical deps** - Use exact versions for production dependencies if needed

## File Detection

Ion checks for config files in this order and uses the first one found:

```
ion.jsonc       ← Preferred (comments!)
ion.json        ← Simple, clean
package.jsonc   ← Hybrid projects (comments!)
package.json    ← NPM compatible
ion.toml        ← Legacy support
```

If no config file is found, Home will show an error with suggestions:

```
Error: No configuration file found. Expected one of:
  - ion.jsonc (recommended)
  - ion.json
  - package.jsonc
  - package.json
  - ion.toml
```

## Editor Support

### VS Code

Install the **"JSONC syntax highlighting"** extension for the best experience with `.jsonc` files. VS Code will automatically provide:

- ✅ Syntax highlighting
- ✅ IntelliSense for common fields
- ✅ Error detection
- ✅ Auto-formatting

### JetBrains IDEs

JSONC is supported out of the box in WebStorm, IntelliJ IDEA, and other JetBrains IDEs.

## Why Multiple Formats?

Ion supports multiple configuration formats to:

1. **Ease migration** - Existing package.json files work out of the box
2. **Team preferences** - Some teams prefer JSON, others TOML
3. **Hybrid projects** - Use package.json for Node.js + Home projects
4. **Comments** - JSONC adds comments to JSON
5. **Ecosystem compatibility** - Work seamlessly with existing tools

Choose the format that works best for your project!
