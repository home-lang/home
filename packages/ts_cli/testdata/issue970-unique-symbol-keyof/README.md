# Unique symbol keys in arrays (#970)

The array control compares the well-known `Symbol.unscopables` key with an unrelated declared `unique symbol` and a broad `symbol`. TypeScript 5.7.3 accepts the well-known key for both mutable and readonly arrays and rejects the other two identities. This checks both receiver surfaces without widening all symbol keys.

The computed-member control declares two distinct unique-symbol properties on an interface. Both are valid `keyof Box` values and readable through indexed access. The well-known array symbol is unrelated and must be rejected as a key of that interface.

The Program control exports a declared unique symbol and an interface keyed by it, then imports both from another file. The imported key remains the same nominal type through direct and `Readonly<Box>` indexed reads, while an unrelated declaration is rejected for both.
