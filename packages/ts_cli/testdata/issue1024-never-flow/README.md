#1024: impossible branch narrowing

Identifier reads inside truthiness, equality, and typeof branches whose
intersection is empty have type `never`. The exact diagnostic stream is
compared with TypeScript 5.7.3.
