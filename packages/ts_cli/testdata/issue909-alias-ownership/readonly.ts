interface Part {
  id: number;
  name: string;
  subparts: Part[];
  updatePart(newName: string): void;
}

type NonFunctionPropertyNames<T> = {
  [K in keyof T]: T[K] extends Function ? never : K
}[keyof T];

type DeepReadonly<T> =
  T extends any[] ? DeepReadonlyArray<T[number]> :
  T extends object ? DeepReadonlyObject<T> :
  T;

interface DeepReadonlyArray<T> extends ReadonlyArray<DeepReadonly<T>> {}
type DeepReadonlyObject<T> = {
  readonly [P in NonFunctionPropertyNames<T>]: DeepReadonly<T[P]>;
};

function check(part: DeepReadonly<Part>) {
  let name: string = part.name;
  let id: number = part.subparts[0].id;
  part.id = part.id;
  part.subparts[0] = part.subparts[0];
  part.subparts[0].id = part.subparts[0].id;
  part.updatePart("hello");
}
