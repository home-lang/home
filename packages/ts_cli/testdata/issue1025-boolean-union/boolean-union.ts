declare const cond: boolean;

let orValue: boolean = cond;
orValue ||= cond;
const orReport: false = orValue;

let andValue: boolean = cond;
andValue &&= cond;
const andReport: false = andValue;

let nullishValue: boolean | undefined = cond;
nullishValue ??= cond;
const nullishReport: false = nullishValue;

type BooleanWithLiteral = boolean | true;
declare const unionValue: BooleanWithLiteral;
const unionReport: false = unionValue;

type LiteralBoolean = true | false;
declare const literalUnionValue: LiteralBoolean;
const literalUnionReport: false = literalUnionValue;

export {};
