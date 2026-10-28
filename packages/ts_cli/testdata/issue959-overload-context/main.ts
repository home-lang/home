declare function match<T>(cb: (value: T) => boolean): T;

interface Use {
  (point: [number?], tag: 'numeric'): boolean;
  (point: [string?], tag: 'text'): boolean;
}

declare const use: Use;
use([match(y => y.length > 0)], 'text');
