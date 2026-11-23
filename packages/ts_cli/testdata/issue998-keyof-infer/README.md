# Inference from `keyof` arguments (#998)

Literal keys supply a low-priority object-shape candidate for the type
parameter beneath `keyof`. Separate arguments contribute separate candidate
shapes. A normal value argument takes priority over the key-derived shape.
The oracle audit compares the complete diagnostic stream with TypeScript 5.7.3.
