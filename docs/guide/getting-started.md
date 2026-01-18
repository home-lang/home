# Getting Started

This guide will walk you through installing the Home compiler and writing your first program.

## Prerequisites

Home is written in Zig, so you will need the Zig compiler to build it.

### Installing Zig

::: code-group

```bash [macOS]
# Using Homebrew
brew install zig

# Or using Pantry
pantry install zig
```

```bash [Linux]
# Download from ziglang.org
wget https://ziglang.org/download/0.16.0/zig-linux-x86_64-0.16.0.tar.xz
tar -xf zig-linux-x86_64-0.16.0.tar.xz
export PATH=$PATH:$(pwd)/zig-linux-x86_64-0.16.0
```

```powershell [Windows]
# Using Scoop
scoop install zig

# Or download from ziglang.org
```

:::

Verify your installation:

```bash
zig version
# Should output: 0.16.0 or higher
```

## Building the Compiler

Clone the Home repository and build the compiler:

```bash
git clone https://github.com/home-lang/home.git
cd home
zig build
```

This will create the Home compiler at `./zig-out/bin/home`.

### Verify Installation

```bash
./zig-out/bin/home --version
```

## Hello World

Create a new file called `hello.home`:

```home
// hello.home
fn main() {
  print("Hello, Home!")
}
```

Build and run your program:

```bash
./zig-out/bin/home build hello.home
./hello
```

You should see:

```
Hello, Home!
```

## Your First Real Program

Let's write something more interesting - a Fibonacci calculator:

```home
// fibonacci.home

fn fib(n: int): int {
  if (n <= 1) {
    return n
  }
  return fib(n - 1) + fib(n - 2)
}

fn main() {
  let result = fib(10)
  print("Fibonacci(10) = {result}")
}
```

Build and run:

```bash
./zig-out/bin/home build fibonacci.home
./fibonacci
```

Output:

```
Fibonacci(10) = 55
```

## Project Structure

A typical Home project looks like this:

```
my-project/
├── src/
│   ├── main.home       # Entry point
│   ├── lib.home        # Library code
│   └── utils/
│       └── helpers.home
├── tests/
│   └── test_lib.home
├── examples/
│   └── demo.home
└── pantry.json         # Package manifest (optional)
```

### The Home Compiler Structure

The Home compiler itself follows this structure:

```
home/
├── src/main.zig           # CLI entry point
├── packages/
│   ├── lexer/             # Tokenization
│   ├── parser/            # AST generation
│   ├── ast/               # Syntax tree types
│   ├── types/             # Type system
│   ├── codegen/           # Native code generation (x64)
│   ├── interpreter/       # Direct execution
│   ├── diagnostics/       # Error reporting
│   └── ...
├── examples/              # Example programs
├── tests/                 # Integration tests
└── stdlib/                # Standard library
```

## Running Programs

There are two ways to run Home programs:

### Compiled Execution (Recommended)

Build to a native executable:

```bash
./zig-out/bin/home build myprogram.home
./myprogram
```

### Interpreted Execution

Run directly without compilation (useful for development):

```bash
./zig-out/bin/home run myprogram.home
```

## File Extensions

Home supports two file extensions:

- `.home` - Standard source file extension (recommended)
- `.hm` - Short alternative

## Build Commands

```bash
# Build a program
./zig-out/bin/home build program.home

# Run without building
./zig-out/bin/home run program.home

# Run tests
./zig-out/bin/home test tests/

# Format code
./zig-out/bin/home fmt src/
```

## Next Steps

Now that you have Home installed, explore these topics:

- [Variables and Types](/guide/variables) - Learn about Home's type system
- [Functions](/guide/functions) - Define and call functions
- [Control Flow](/guide/control-flow) - Conditionals and loops
- [Error Handling](/guide/error-handling) - Work with Result types

## Troubleshooting

### Common Issues

**Zig not found**

Make sure Zig is in your PATH:

```bash
which zig
# Should output the path to zig
```

**Build fails with memory error**

Try increasing stack size or check for infinite recursion in your code.

**Permission denied**

Make sure the built executable has execute permissions:

```bash
chmod +x ./myprogram
```

### Getting Help

- Check the [examples](https://github.com/home-lang/home/tree/main/examples) directory
- Read the [architecture documentation](https://github.com/home-lang/home/blob/main/ARCHITECTURE.md)
- Open an issue on [GitHub](https://github.com/home-lang/home/issues)
