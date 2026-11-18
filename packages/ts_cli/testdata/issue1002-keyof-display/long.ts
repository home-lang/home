interface Shape { a: number; b: string }
type StringKeys = keyof string;
declare const wrong: { q: 1 };
const viaAlias: StringKeys = "bogus";
const direct: keyof string = "bogus";
function accepts(p: keyof string) { void p; }
accepts("bogus");
const numberKeys: (keyof number)[] = ["bogus"];
const literal: keyof "abc" = "bogus";
const common: keyof (string | number) = "bogus";
const named: keyof Shape = "bogus";
