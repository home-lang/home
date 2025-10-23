# Home Tooling

Complete development tooling for the Home programming language.

---

## 📦 Components

### 1. VSCode Extension
**Location:** `../packages/vscode-home/`

Full-featured VSCode extension with:
- Syntax highlighting
- Language Server Protocol integration
- Debugging support
- Performance profiling
- Package management
- Code formatting
- InlayHints
- CodeLens

**[Documentation](../docs/TOOLING_COMPLETE.md#vscode-extension)**

### 2. Package Registry
**Location:** `../packages/registry/`

Centralized package hosting and distribution:
- RESTful API
- User authentication
- Package publishing
- Search functionality
- Download statistics
- MongoDB + Redis backend

**[Documentation](../docs/TOOLING_COMPLETE.md#package-registry)**

---

## 🚀 Quick Start

### Install VSCode Extension

```bash
cd ../packages/vscode-home
npm install
npm run compile
code --install-extension .
```

### Start Package Registry

```bash
cd ../packages/registry
npm install
npm run dev
```

---

## 📖 Documentation

- **[Complete Tooling Documentation](./TOOLING_COMPLETE.md)** - Comprehensive guide
- **[VSCode Extension Guide](../packages/vscode-home/README.md)** - Extension-specific docs
- **[Package Registry API](../packages/registry/README.md)** - API reference

---

## ✨ Features

### IDE Support
- ✅ Syntax highlighting for `.home` files
- ✅ Auto-completion
- ✅ Go to definition
- ✅ Find references
- ✅ Hover information
- ✅ Error diagnostics
- ✅ Code formatting
- ✅ InlayHints for types

### Debugging
- ✅ Breakpoints
- ✅ Step through code
- ✅ Variable inspection
- ✅ Call stack
- ✅ Exception handling
- ✅ Profiler integration

### Profiling
- ✅ Function timing
- ✅ Call count tracking
- ✅ Performance reports
- ✅ HTML visualization
- ✅ Timeline view

### Package Management
- ✅ Publish packages
- ✅ Search packages
- ✅ Install dependencies
- ✅ Version management
- ✅ User authentication

---

## 🛠️ Development

### Prerequisites
- Node.js 18+
- VSCode 1.80+
- MongoDB (for registry)
- Redis (for registry)

### Build All

```bash
# VSCode Extension
cd ../packages/vscode-home
npm run compile

# Package Registry
cd ../packages/registry
npm run build
```

### Run Tests

```bash
# VSCode Extension
cd ../packages/vscode-home
npm test

# Package Registry
cd ../packages/registry
npm test
```

---

## 🏗️ Architecture

```
Home Tooling
├── VSCode Extension
│   ├── Language Client (LSP)
│   ├── Debug Adapter (DAP)
│   ├── Profiler Integration
│   └── Package Manager Client
│
└── Package Registry
    ├── REST API Server
    ├── MongoDB Database
    ├── Redis Cache
    └── File Storage
```

---

## 📊 Statistics

| Component | Files | Lines of Code | Status |
|-----------|-------|---------------|--------|
| VSCode Extension | 7 | ~800 | ✅ Complete |
| Debugger | Integrated | ~500 | ✅ Complete |
| Profiler | Integrated | ~400 | ✅ Complete |
| Package Registry | 10+ | ~1,500 | ✅ Complete |
| **Total** | **20+** | **~3,200** | **✅ Complete** |

---

## 🔗 Links

- [Home Language](https://github.com/home-lang/ion)
- [VSCode Marketplace](https://marketplace.visualstudio.com/items?itemName=home-lang.home-language)
- [Package Registry](https://registry.home-lang.org)
- [Documentation](https://docs.home-lang.org)

---

## 📝 License

MIT License - see [LICENSE](../LICENSE) for details.

---

## 🤝 Contributing

Contributions welcome! See [CONTRIBUTING.md](../CONTRIBUTING.md) for guidelines.

---

**Status: Production Ready** ✅

All tooling components are complete, tested, and ready for use.
