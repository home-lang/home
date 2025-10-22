# Contributing to Ion

Thank you for your interest in contributing to Ion! This document provides guidelines and information for contributors.

---

## Project Status

**Phase 0** (Months 1-3): Foundation & Validation

Ion is in early development. We're building the compiler from scratch. This is an exciting time to join as core decisions are still being made!

---

## How to Contribute

### 1. Start Small

Good first contributions:
- **Documentation**: Improve README, add examples
- **Testing**: Write test cases for lexer/parser
- **Examples**: Create Ion code examples
- **Bug reports**: Test and report issues
- **Design feedback**: Review [DECISIONS.md](./DECISIONS.md)

### 2. Pick an Area

We need help with:

#### Compiler (High Priority)
- **Lexer**: Token scanning and parsing
- **Parser**: AST construction
- **Type System**: Inference and checking
- **Codegen**: IR generation and Cranelift integration
- **Optimizations**: Caching, incremental compilation

#### Tooling
- **CLI**: Command-line interface improvements
- **Testing Framework**: Test harness and utilities
- **Benchmarks**: Performance comparison vs Zig/Rust
- **Error Messages**: Make diagnostics helpful

#### Documentation
- **Guides**: How-to articles and tutorials
- **API Docs**: Document language features
- **Examples**: Real-world code samples
- **FAQ**: Common questions and answers

#### Community
- **GitHub Discussions**: Answer questions
- **Code Review**: Review pull requests
- **Mentoring**: Help new contributors
- **Evangelism**: Write blog posts, give talks

---

## Development Setup

### Prerequisites

```bash
# Zig 0.11 or later
curl -L https://ziglang.org/download/0.11.0/zig-linux-x86_64-0.11.0.tar.xz | tar xJ
export PATH=$PATH:$PWD/zig-linux-x86_64-0.11.0

# Git
sudo apt install git  # or equivalent
```

### Clone and Build

```bash
git clone https://github.com/stacksjs/ion.git
cd ion

# Build the compiler
zig build

# Run tests
zig build test

# Install locally (optional)
zig build install
```

### Project Structure

```
ion/
├── src/
│   ├── main.zig           # CLI entry point
│   ├── lexer/             # Tokenization
│   ├── parser/            # AST construction
│   ├── semantic/          # Type checking
│   ├── ir/                # Intermediate representation
│   ├── codegen/           # Code generation
│   └── cli/               # Command implementations
├── tests/                 # Test suite
├── examples/              # Example Ion programs
├── bench/                 # Benchmarks
└── docs/                  # Documentation
```

---

## Coding Standards

### Zig Style Guide

Follow [Zig Style Guide](https://ziglang.org/documentation/master/#Style-Guide):

- **Indentation**: 4 spaces (no tabs)
- **Line length**: 100 characters max
- **Naming**:
  - Types: `PascalCase`
  - Functions: `camelCase`
  - Variables: `snake_case`
  - Constants: `SCREAMING_SNAKE_CASE`

### Ion Language Style

For Ion code examples:

- **Indentation**: 2 spaces
- **Naming**: 
  - Types/Structs: `PascalCase`
  - Functions: `snake_case`
  - Variables: `snake_case`
  - Constants: `SCREAMING_SNAKE_CASE`

### Code Quality

- **Tests**: Write tests for new features
- **Documentation**: Add doc comments for public APIs
- **Error handling**: Use Result/Option, avoid panics
- **Performance**: Profile hot paths
- **Safety**: Prefer safe code, document unsafe usage

---

## Pull Request Process

### Before You Start

1. **Check existing issues**: Avoid duplicate work
2. **Create an issue**: Discuss large changes first
3. **Fork the repo**: Make changes in your fork
4. **Create a branch**: Use descriptive names

```bash
git checkout -b feature/add-lexer-tests
git checkout -b fix/parser-crash-on-empty-file
git checkout -b docs/improve-getting-started
```

### Making Changes

1. **Write code**: Follow style guide
2. **Add tests**: Cover new functionality
3. **Update docs**: If changing behavior
4. **Test locally**:

```bash
zig build test
zig build
./zig-out/bin/ion parse examples/hello.ion
```

### Commit Messages

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
feat: add lexer support for string interpolation
fix: handle empty files in parser
docs: update CONTRIBUTING with commit guidelines
test: add edge cases for type inference
perf: optimize IR serialization
```

### Submitting PR

1. **Push to your fork**:
```bash
git push origin feature/add-lexer-tests
```

2. **Create pull request** on GitHub

3. **PR Template**:
```markdown
## Description
Brief description of changes

## Type of Change
- [ ] Bug fix
- [ ] New feature
- [ ] Breaking change
- [ ] Documentation

## Testing
How was this tested?

## Checklist
- [ ] Code follows style guide
- [ ] Tests added/updated
- [ ] Documentation updated
- [ ] All tests pass
```

4. **Wait for review**: Be responsive to feedback

---

## Testing

### Writing Tests

```zig
// tests/lexer_test.zig
const std = @import("std");
const Lexer = @import("../src/lexer/lexer.zig").Lexer;
const TokenType = @import("../src/lexer/token.zig").TokenType;

test "lexer: tokenize integers" {
    const source = "42 123 0";
    var lexer = Lexer.init(source);
    
    const token1 = lexer.nextToken();
    try std.testing.expectEqual(TokenType.Integer, token1.type);
    try std.testing.expectEqualStrings("42", token1.lexeme);
    
    const token2 = lexer.nextToken();
    try std.testing.expectEqual(TokenType.Integer, token2.type);
    try std.testing.expectEqualStrings("123", token2.lexeme);
}
```

### Running Tests

```bash
# All tests
zig build test

# Specific test file
zig test tests/lexer_test.zig

# With verbose output
zig build test -Dverbose=true
```

### Test Categories

- **Unit tests**: Individual functions/modules
- **Integration tests**: Multiple components together
- **Performance tests**: Benchmark critical paths
- **Regression tests**: Prevent fixed bugs from returning

---

## Benchmarking

### Running Benchmarks

```bash
# Compile time benchmarks
./bench/compile_time.sh

# Runtime benchmarks
./bench/runtime.sh

# Compare with Zig
./bench/vs_zig.sh
```

### Adding Benchmarks

Create Ion test programs in `bench/programs/`:

```ion
// bench/programs/fibonacci.ion
fn fib(n: int) -> int {
  if n <= 1 { return n }
  return fib(n - 1) + fib(n - 2)
}

fn main() {
  let result = fib(35)
  print(result)
}
```

Add equivalent Zig version for comparison:

```zig
// bench/programs/fibonacci.zig
fn fib(n: i32) i32 {
    if (n <= 1) return n;
    return fib(n - 1) + fib(n - 2);
}

pub fn main() void {
    const result = fib(35);
    std.debug.print("{}\n", .{result});
}
```

---

## Documentation

### Doc Comments

```zig
/// Tokenizes Ion source code into a stream of tokens.
/// 
/// Example:
/// ```
/// var lexer = Lexer.init("fn main() {}");
/// const token = lexer.nextToken();
/// ```
pub const Lexer = struct {
    /// The source code being lexed
    source: []const u8,
    
    /// Initialize a new lexer with the given source
    pub fn init(source: []const u8) Lexer {
        return .{ .source = source };
    }
};
```

### Updating Docs

- **README.md**: High-level overview
- **ROADMAP.md**: Strategic direction
- **GETTING-STARTED.md**: Implementation guide
- **docs/**: Detailed documentation (coming soon)

---

## Communication

### GitHub Issues

- **Bug reports**: Use issue template, provide reproduction
- **Feature requests**: Explain use case and benefit
- **Questions**: Check FAQ first, be specific

### Discussions

- **Design**: Language design discussions
- **Ideas**: Brainstorming new features
- **Help**: Getting started questions
- **Show**: Share what you built

### Discord (Coming Soon)

Real-time chat for:
- Quick questions
- Collaboration
- Community building

---

## Code of Conduct

### Our Pledge

We are committed to providing a welcoming and inclusive environment for everyone, regardless of background or identity.

### Expected Behavior

- **Be respectful**: Treat others with courtesy
- **Be collaborative**: Help each other succeed
- **Be patient**: Remember everyone is learning
- **Be constructive**: Focus on ideas, not people

### Unacceptable Behavior

- Harassment, discrimination, or hate speech
- Personal attacks or trolling
- Publishing others' private information
- Any behavior that makes others feel unsafe

### Enforcement

Violations may result in:
1. Warning
2. Temporary ban
3. Permanent ban

Report issues to: [conduct@stacksjs.org](mailto:conduct@stacksjs.org)

---

## Recognition

### Contributors

All contributors will be:
- Listed in AUTHORS file
- Credited in release notes
- Mentioned in announcements (if desired)

### Types of Contributions

We value all contributions:
- **Code**: Features, fixes, tests
- **Documentation**: Guides, examples, translations
- **Design**: Language design input
- **Community**: Helping others, evangelism
- **Feedback**: Testing, bug reports, ideas

---

## Getting Help

### Resources

- **Documentation**: [docs/](./docs) (coming soon)
- **Examples**: [examples/](./examples)
- **Roadmap**: [ROADMAP.md](./ROADMAP.md)
- **Decisions**: [DECISIONS.md](./DECISIONS.md)

### Ask Questions

- **GitHub Discussions**: Best for async questions
- **Issues**: For bugs or feature requests
- **Discord**: For real-time help (coming soon)

### Mentorship

New to compiler development? We can help!

- Tag issues with `good first issue`
- Pair programming sessions (ask in Discussions)
- Detailed code reviews with explanations

---

## Development Workflow

### Typical Contribution Flow

1. **Find/create issue**: What to work on
2. **Discuss approach**: Comment on issue
3. **Fork and branch**: Create your workspace
4. **Develop**: Write code + tests
5. **Test locally**: Ensure everything works
6. **Create PR**: Submit for review
7. **Address feedback**: Iterate with reviewers
8. **Merge**: Celebrate! 🎉

### Review Process

**Timeline**: We aim to respond within:
- Critical bugs: 24 hours
- Features/improvements: 1 week
- Documentation: 1 week

**Reviewers look for**:
- Code quality and style
- Test coverage
- Documentation
- Performance impact
- Breaking changes

---

## License

By contributing to Ion, you agree that your contributions will be licensed under the MIT + Pro-Democracy License.

See [LICENSE](./LICENSE) for details.

---

## Questions?

- **General**: Open a Discussion
- **Specific**: Comment on relevant issue
- **Private**: Email [team@stacksjs.org](mailto:team@stacksjs.org)

---

**Thank you for contributing to Ion!** 🧬

Together, we're building the future of systems programming.
