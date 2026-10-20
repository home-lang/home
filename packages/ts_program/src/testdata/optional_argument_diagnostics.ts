declare function optional(value?: string): void;
declare function explicit(value: string | undefined): void;
declare const mixed: string | number;
declare const maybenull: string | null;
declare const unknownValue: unknown;
declare const numberValue: number;
optional(numberValue);
optional(mixed);
optional(maybenull);
optional(unknownValue);
optional(null);
optional(true);
optional(undefined);
explicit(numberValue);
explicit(mixed);
explicit(maybenull);
explicit(unknownValue);
explicit(null);
explicit(true);
interface IEye { color: number }
interface IFrenchEye { coleur: number }
declare function compare(a: IFrenchEye, b: IFrenchEye): number;
declare let eyes: IEye[];
eyes.sort(compare);
