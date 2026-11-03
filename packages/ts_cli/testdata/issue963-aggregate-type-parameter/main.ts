export function cast<T>(value: T): {
  as: <K extends T>() => null extends T ? K | null : undefined extends T ? K | undefined : K;
} {
  return {
    as: <K extends T>(): null extends T ? K | null : undefined extends T ? K | undefined : K => {
      return value as K;
    },
  };
}

const nullable: string | null = cast<string | null>('text').as<string>();
const invalid: number = cast<string | null>('text').as<string>();
void [nullable, invalid];
