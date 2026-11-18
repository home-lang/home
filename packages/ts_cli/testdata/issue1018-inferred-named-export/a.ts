interface Foo { a: number }
type Bar = { b: number };

function mkFoo(): Foo { return { a: 1 }; }
function mkBar(): Bar { return { b: 1 }; }

export const inferredInterface = mkFoo();
export const annotatedInterface: Foo = mkFoo();
export const inferredAlias = mkBar();
export const unrelated = { a: 1 };
