# Setup Ion Action

GitHub Action to setup the [Ion programming language](https://github.com/ion-lang/ion) in your CI/CD workflows.

## Usage

### Basic

```yaml
- uses: ion-lang/ion/packages/action@v0.1
  with:
    ion-version: 'latest'
```

### Specific Version

```yaml
- uses: ion-lang/ion/packages/action@v0.1
  with:
    ion-version: '0.1.0'
```

### Using Version File

```yaml
- uses: ion-lang/ion/packages/action@v0.1
  with:
    ion-version-file: '.ion-version'
```

### Disable Caching

```yaml
- uses: ion-lang/ion/packages/action@v0.1
  with:
    ion-version: 'latest'
    cache: 'false'
```

## Features

- ✅ **Automatic Caching** - Uses GitHub Actions cache to speed up builds
- ✅ **Multi-Platform** - Supports Linux, macOS, and Windows
- ✅ **Version Flexibility** - Install specific versions or use `latest`/`canary`
- ✅ **Version File Support** - Read version from `.ion-version` file
- ✅ **Fast Setup** - Cached installations complete in seconds

## Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `ion-version` | Version of Ion to install (`latest`, `0.1.0`, `canary`) | No | `latest` |
| `ion-version-file` | Path to file containing Ion version (e.g., `.ion-version`) | No | - |
| `cache` | Enable caching of Ion installation (recommended) | No | `true` |
| `scope` | Scope for package registry authentication | No | - |

> **💡 Caching:** The action automatically caches Ion installations using GitHub's `@actions/tool-cache`. Subsequent runs with the same version will skip the download and use the cached version, typically completing in under 5 seconds.

## Outputs

| Output | Description |
|--------|-------------|
| `ion-version` | The installed Ion version |
| `ion-path` | Path to the Ion installation |

## Example Workflows

### Build and Test

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup Ion
        uses: ion-lang/ion/packages/action@v0.1
        with:
          ion-version: 'latest'

      - name: Build project
        run: ion build

      - name: Run tests
        run: ion test
```

### Matrix Testing

```yaml
name: Matrix Test

on: [push, pull_request]

jobs:
  test:
    runs-on: ${{ matrix.os }}
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest, windows-latest]
        ion-version: ['0.1.0', 'latest']

    steps:
      - uses: actions/checkout@v4

      - name: Setup Ion ${{ matrix.ion-version }}
        uses: ion-lang/ion/packages/action@v0.1
        with:
          ion-version: ${{ matrix.ion-version }}

      - name: Run tests
        run: ion test
```

### Package Publishing

```yaml
name: Publish

on:
  release:
    types: [created]

jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup Ion
        uses: ion-lang/ion/packages/action@v0.1

      - name: Build package
        run: ion build --release

      - name: Publish to registry
        run: ion pkg publish
        env:
          ION_TOKEN: ${{ secrets.ION_TOKEN }}
```

## Development

This action is built with [Bun](https://bun.sh) and TypeScript.

### Setup

```bash
cd packages/action
bun install
```

### Build

```bash
bun run build
```

### Package for Distribution

```bash
bun run package
```

## License

MIT
