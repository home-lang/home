#1049: tuple to array element elaboration

A tuple's number index carries its element type when assigned to an array.
TypeScript widens fresh tuple element literals in the nested explanation,
while the outer diagnostic retains the literal tuple. The fixture covers
readonly and mutable sources, numeric and string literals, singleton targets
that retain the literal element name, and the separate
readonly-to-mutable reason. Mixed tuple element unions are tracked in #1050.

The exact diagnostic stream is checked against TypeScript 5.7.3.
