// expected: no diagnostics
class Foo {
  count: number = 0;
  inc(): number {
    return this.count;
  }
}
