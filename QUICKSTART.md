# Ion Quick Start - Week 1 Checklist

**Your first week building Ion**. Copy this checklist and mark items as you complete them.

---

## Day 1: Setup & Planning

### Morning (2-3 hours)
- [ ] Read [README.md](./README.md) - Project overview
- [ ] Read [IMPLEMENTATION-SUMMARY.md](./IMPLEMENTATION-SUMMARY.md) - Quick overview
- [ ] Read [PITFALLS.md](./PITFALLS.md) - Reality check
- [ ] Install Zig compiler (0.15.1 or later)
- [ ] Set up code editor (VSCode + Zig extension recommended)

### Afternoon (2-3 hours)
- [ ] Create project structure:
  ```bash
  mkdir -p src/{lexer,parser,ast,cli}
  mkdir -p tests examples bench docs
  ```
- [ ] Create `build.zig` file
- [ ] Create first test file: `tests/lexer_test.zig`
- [ ] Get "Hello, Zig" building and running
- [ ] Set up Git (if not done): `git init`

### Evening (1-2 hours)
- [ ] Create `examples/hello.ion` - Your first Ion program
- [ ] Draft Token types list (30+ tokens)
- [ ] Read about lexer implementation patterns

**Goal**: Environment ready, understand the project scope

---

## Day 2: Token Definitions

### Morning (3-4 hours)
- [ ] Create `src/lexer/token.zig`
- [ ] Define `TokenType` enum (keywords, operators, literals)
- [ ] Define `Token` struct (type, lexeme, line, column)
- [ ] Write test cases for token equality
- [ ] Document each token type

### Afternoon (2-3 hours)
- [ ] Create token test file
- [ ] Test creating tokens
- [ ] Test token comparison
- [ ] Run tests: `zig build test`

**Goal**: Token system complete and tested

---

## Day 3-4: Lexer Implementation

### Day 3 Morning (3-4 hours)
- [ ] Create `src/lexer/lexer.zig`
- [ ] Define `Lexer` struct (source, position, line, column)
- [ ] Implement `init()` and basic state management
- [ ] Implement `advance()`, `peek()`, `match()`
- [ ] Implement whitespace skipping

### Day 3 Afternoon (3-4 hours)
- [ ] Implement integer lexing
- [ ] Implement float lexing (with decimal point)
- [ ] Implement identifier lexing
- [ ] Implement keyword detection (use comptime map)
- [ ] Test number and identifier lexing

### Day 4 Morning (3-4 hours)
- [ ] Implement string lexing (with quotes)
- [ ] Implement operator lexing (single and double char)
- [ ] Implement comment skipping (// style)
- [ ] Implement delimiter lexing (parens, braces, brackets)

### Day 4 Afternoon (2-3 hours)
- [ ] Add error handling for invalid tokens
- [ ] Improve error messages with line/column info
- [ ] Write comprehensive test suite (50+ test cases)
- [ ] Test edge cases: empty files, only whitespace, etc.

**Goal**: Complete working lexer with tests

---

## Day 5: CLI & Integration

### Morning (2-3 hours)
- [ ] Create `src/main.zig`
- [ ] Implement argument parsing
- [ ] Create `ion parse` command
- [ ] Print tokens to stdout with formatting
- [ ] Test with `examples/hello.ion`

### Afternoon (2-3 hours)
- [ ] Add color output for different token types
- [ ] Add `--help` flag and usage information
- [ ] Handle file reading errors gracefully
- [ ] Create more example files

### Evening (1-2 hours)
- [ ] Write README for lexer component
- [ ] Document token types
- [ ] Create visualization of lexer state machine
- [ ] Update main README with progress

**Goal**: Usable `ion parse` command

---

## Day 6: Testing & Benchmarking

### Morning (2-3 hours)
- [ ] Create `bench/lexer_bench.zig`
- [ ] Benchmark lexer on 100 LOC file
- [ ] Benchmark lexer on 1000 LOC file
- [ ] Profile lexer (find hot spots)

### Afternoon (2-3 hours)
- [ ] Optimize hot paths (if needed)
- [ ] Add more edge case tests
- [ ] Test with invalid input
- [ ] Ensure all tests pass

### Evening (1-2 hours)
- [ ] Update milestone tracker
- [ ] Write week 1 progress report
- [ ] Plan week 2 (parser)
- [ ] Celebrate! 🎉

**Goal**: Week 1 complete, lexer working and fast

---

## Week 1 Success Criteria

By end of week 1, you should have:

✅ **Working lexer** that tokenizes Ion source code
✅ **50+ test cases** all passing
✅ **`ion parse` command** that displays tokens
✅ **Performance baseline** (lexer speed measured)
✅ **Examples** (hello.ion, fibonacci.ion, etc.)
✅ **Documentation** (token types documented)

---

## Commands You Should Be Able to Run

```bash
# Build compiler
zig build

# Run all tests
zig build test

# Run specific test
zig test tests/lexer_test.zig

# Use ion parse command
./zig-out/bin/ion parse examples/hello.ion

# Benchmark lexer
zig build bench
```

---

## Expected Output

### `ion parse examples/hello.ion`
```
Fn              'fn' (1:1)
Identifier      'main' (1:4)
LeftParen       '(' (1:8)
RightParen      ')' (1:9)
LeftBrace       '{' (1:11)
Identifier      'print' (2:3)
LeftParen       '(' (2:8)
String          '"Hello, Ion!"' (2:9)
RightParen      ')' (2:22)
RightBrace      '}' (3:1)
Eof             '' (3:2)
```

### Test Output
```
Test [1/47] test "lexer: integers"... OK
Test [2/47] test "lexer: floats"... OK
Test [3/47] test "lexer: identifiers"... OK
...
All 47 tests passed.
```

---

## Troubleshooting

### "Zig not found"
```bash
# Download and extract Zig
curl -L https://ziglang.org/download/0.11.0/zig-linux-x86_64-0.11.0.tar.xz | tar xJ
export PATH=$PATH:$PWD/zig-linux-x86_64-0.11.0
```

### "Build fails with errors"
- Check Zig version: `zig version` (need 0.11+)
- Verify file structure matches layout
- Check for syntax errors in .zig files
- Try `zig build clean && zig build`

### "Tests fail"
- Read error message carefully
- Check test expectations vs actual output
- Add debug prints: `std.debug.print("{}\n", .{value});`
- Simplify test to isolate issue

### "Lexer too slow"
- Week 1: Don't optimize yet!
- Baseline: ~10ms for 100 LOC is fine
- Optimize in week 6 after benchmarking vs Zig

---

## Week 2 Preview

Next week you'll build:
- **Parser**: Convert tokens to AST
- **AST**: Abstract Syntax Tree definitions
- **Precedence**: Expression parsing with operators
- **Tests**: 100+ parser test cases

---

## Daily Time Estimates

**Conservative** (part-time, 3-4 hours/day):
- Day 1: Setup (3-4h)
- Day 2: Tokens (5-6h)
- Day 3: Lexer basics (6-7h)
- Day 4: Lexer complete (6-7h)
- Day 5: CLI (5-6h)
- Day 6: Testing (5-6h)

**Total**: 30-36 hours

**Aggressive** (full-time, 6-8 hours/day):
- Condense to 4-5 days
- More testing and polish
- Start on parser early

---

## Resources

### Learn as You Go

- **Zig Language**: [https://ziglang.org/documentation/master/](https://ziglang.org/documentation/master/)
- **Lexer Basics**: Chapter 4 of "Crafting Interpreters"
- **Token Design**: Look at Zig/Rust token enums

### Example Code

Look at:
- Zig's lexer: `lib/std/zig/tokenizer.zig`
- Rust's lexer: `compiler/rustc_lexer/src/lib.rs`

### Community

- **GitHub Discussions**: Ask questions
- **Discord**: Real-time help (coming soon)

---

## Celebration Checklist

At end of week 1, treat yourself:
- [ ] Tweet/post about progress
- [ ] Update README with "Week 1 complete"
- [ ] Share in GitHub Discussions
- [ ] Take a break / have fun
- [ ] Plan week 2 with confidence

---

## Important Reminders

1. **It's OK to be slow**: Week 1 is about learning
2. **Tests matter**: Don't skip them
3. **Ask for help**: Use Discussions
4. **Document**: Future you will thank you
5. **Have fun**: Enjoy the process!

---

## Week 1 Template

Copy this and track your progress:

```markdown
# My Week 1 Progress

## Day 1: Setup
- [ ] Environment ready
- [ ] First test running
- Notes: 

## Day 2: Tokens
- [ ] TokenType enum complete
- [ ] Tests passing
- Notes:

## Day 3: Lexer (Part 1)
- [ ] Basic lexing working
- [ ] Numbers and identifiers
- Notes:

## Day 4: Lexer (Part 2)
- [ ] Strings and operators
- [ ] Error handling
- Notes:

## Day 5: CLI
- [ ] `ion parse` working
- [ ] Examples created
- Notes:

## Day 6: Testing
- [ ] 50+ tests
- [ ] Benchmarks run
- Notes:

## Week 1 Complete! 🎉
Total time: ___ hours
Challenges faced:
Lessons learned:
Ready for week 2: YES / NO
```

---

**You've got this. Start with Day 1, one step at a time.** 🚀

*Last updated: 2025-10-21*
