# Generic `keyof` writes (#998)

An unconstrained type parameter, `extends any`, and `extends unknown` do not
guarantee a literal key. A named object constraint guarantees only its declared
keys. A type parameter constrained to `never` follows TypeScript's property-key
domain rule. The oracle audit compares the complete diagnostic stream and exit
status with TypeScript 5.7.3.
