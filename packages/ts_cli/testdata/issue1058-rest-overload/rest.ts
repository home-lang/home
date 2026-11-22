declare function choose(...values: number[]): number;
declare function choose(...values: string[]): string;
declare function withPrefix(prefix: "p", ...values: number[]): number;
declare function withPrefix(prefix: "p", ...values: string[]): string;
declare const badSpread: boolean[];

choose(true);
withPrefix("p", true);
choose([true]);
choose(...[true]);
choose(...badSpread);

choose(1);
choose("x");
choose(...[1, 2]);
withPrefix("p", 1);
withPrefix("p", "x");
