interface Shape { a: number; b: string }
interface One { a: number }
interface Empty {}
class Klass { x = 1; y = 2 }
type Obj = { a: number; b: string };
interface Box<T> { value: T; other: T }
type KS = keyof Shape;
type KO = keyof One;
type KB = keyof boolean;
type Lit = "x";

// `keyof X` is kept as the name of a key union whose operand is a class, an
// interface, a reference or an aliased object type. Spacing and comments in
// the annotation are not part of it, and an alias for it shows the same name.
const kept: keyof Shape = "bogus";
const spaced: keyof   Shape = "bogus";
const commented: keyof /* note */ Shape = "bogus";
const klass: keyof Klass = "bogus";
const aliasedObject: keyof Obj = "bogus";
const generic: keyof Box<number> = "bogus";
const viaAlias: KS = "bogus";

// Everything else shows its keys. A single key is that literal, no key is
// `never`, and a primitive, an anonymous object or a union operand expands.
const single: keyof One = "bogus";
const singleViaAlias: KO = "bogus";
const none: keyof Empty = "bogus";
const primitive: keyof boolean = "bogus";
const primitiveSpaced: keyof   boolean = "bogus";
const primitiveViaAlias: KB = "bogus";
const anonymous: keyof { a: number; b: string } = "bogus";
const common: keyof (Shape | One) = "bogus";
const element: (keyof boolean)[] = ["bogus"];
let reassigned: keyof boolean = "valueOf";
reassigned = "bogus";
function parameter(p: keyof boolean) { void p; }
parameter("bogus");

// An alias for a single literal is never shown, on its own annotation or on
// an unrelated one that happens to use the same literal.
const literalViaAlias: Lit = "y";
const literalDirect: "x" = "y";

void [kept, spaced, commented, klass, aliasedObject, generic, viaAlias, single,
  singleViaAlias, none, primitive, primitiveSpaced, primitiveViaAlias,
  anonymous, common, element, reassigned, literalViaAlias, literalDirect];
