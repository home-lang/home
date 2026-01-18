# Compile-Time Evaluation

Home provides powerful compile-time evaluation capabilities, allowing computation to happen during compilation rather than at runtime. This enables zero-cost abstractions, static verification, and optimized code generation.

## Overview

Compile-time evaluation in Home offers:

- **const evaluation**: Execute functions at compile time
- **comptime blocks**: Arbitrary compile-time computation
- **Static assertions**: Verify invariants at compile time
- **Type-level computation**: Generate types based on values
- **Code generation**: Produce code based on compile-time analysis

## Const Evaluation

### Const Variables

```home
const PI: f64 = 3.14159265358979323846
const TAU: f64 = PI * 2.0
const BUFFER_SIZE: usize = 1024 * 1024  // 1 MB

// Const arrays
const PRIMES: [i32; 10] = [2, 3, 5, 7, 11, 13, 17, 19, 23, 29]

// Const strings
const VERSION: &str = "1.0.0"
const APP_NAME: &str = concat!("MyApp v", VERSION)
```

### Const Functions

```home
const fn factorial(n: u64) -> u64 {
    if n <= 1 {
        1
    } else {
        n * factorial(n - 1)
    }
}

const FACT_10: u64 = factorial(10)  // Computed at compile time

const fn fibonacci(n: u32) -> u64 {
    match n {
        0 => 0,
        1 => 1,
        _ => fibonacci(n - 1) + fibonacci(n - 2),
    }
}

const FIB_20: u64 = fibonacci(20)  // 6765, computed at compile time
```

### Const in Generics

```home
const fn array_size<T>() -> usize {
    std.mem.size_of::<T>() * 8
}

struct BitArray<T, const N: usize = { array_size::<T>() }> {
    bits: [bool; N],
    _marker: PhantomData<T>,
}
```

## Comptime Blocks

### Basic Comptime

```home
fn main() {
    // This entire block executes at compile time
    const LOOKUP_TABLE: [u8; 256] = comptime {
        let mut table = [0u8; 256]
        for i in 0..256 {
            table[i] = compute_value(i as u8)
        }
        table
    }

    // Table is embedded in binary, no runtime computation
    let value = LOOKUP_TABLE[input]
}
```

### Comptime Type Generation

```home
fn generate_wrapper<T>() -> Type {
    comptime {
        struct Wrapper {
            value: T,
            metadata: compute_metadata::<T>(),
        }
        Wrapper
    }
}

// Creates different struct types based on T
type IntWrapper = generate_wrapper::<i32>()
type StringWrapper = generate_wrapper::<string>()
```

### Comptime Loops

```home
const fn generate_powers_of_two() -> [u64; 64] {
    comptime {
        let mut result = [0u64; 64]
        for i in 0..64 {
            result[i] = 1u64 << i
        }
        result
    }
}

const POWERS_OF_TWO: [u64; 64] = generate_powers_of_two()
```

## Static Assertions

### Basic Static Assertions

```home
// Verify at compile time
static_assert!(size_of::<i32>() == 4, "i32 must be 4 bytes")
static_assert!(align_of::<u64>() == 8, "u64 must be 8-byte aligned")

// Verify struct layout
#[repr(C)]
struct Header {
    magic: u32,
    version: u16,
    flags: u16,
}

static_assert!(size_of::<Header>() == 8, "Header must be exactly 8 bytes")
static_assert!(offset_of!(Header, version) == 4, "version must be at offset 4")
```

### Compile-Time Invariants

```home
const fn validate_config(config: &Config) -> bool {
    config.max_connections > 0 &&
    config.max_connections <= 10000 &&
    config.timeout_ms >= 100
}

const CONFIG: Config = Config {
    max_connections: 1000,
    timeout_ms: 5000,
}

static_assert!(validate_config(&CONFIG), "Invalid configuration")
```

### Type Constraints

```home
const fn is_power_of_two(n: usize) -> bool {
    n > 0 && (n & (n - 1)) == 0
}

fn create_buffer<const SIZE: usize>() -> Buffer<SIZE>
where
    const is_power_of_two(SIZE),
{
    Buffer { data: [0; SIZE] }
}

// OK
let buf = create_buffer::<1024>()

// Compile error: 1000 is not a power of two
// let bad = create_buffer::<1000>()
```

## Type-Level Computation

### Computing Types

```home
const fn select_storage_type(max_value: u64) -> Type {
    if max_value <= 255 {
        u8
    } else if max_value <= 65535 {
        u16
    } else if max_value <= 4294967295 {
        u32
    } else {
        u64
    }
}

struct Counter<const MAX: u64> {
    value: select_storage_type(MAX),
}

let small: Counter<100> = Counter { value: 0u8 }      // Uses u8
let large: Counter<1000000> = Counter { value: 0u32 } // Uses u32
```

### Type Lists

```home
const fn type_list<T...>() -> []Type {
    comptime {
        [$(T),*]
    }
}

const NUMERIC_TYPES: []Type = type_list::<i8, i16, i32, i64, f32, f64>()

const fn generate_parsers() -> []Parser {
    comptime {
        NUMERIC_TYPES.map(|T| Parser.for_type::<T>())
    }
}
```

## Compile-Time Reflection

### Type Information

```home
const fn type_info<T>() -> TypeInfo {
    TypeInfo {
        name: type_name::<T>(),
        size: size_of::<T>(),
        align: align_of::<T>(),
        is_copy: T: Copy,
        is_clone: T: Clone,
    }
}

const fn generate_serializer<T>() -> Serializer {
    comptime {
        let info = type_info::<T>()
        match info.kind {
            TypeKind.Struct => generate_struct_serializer::<T>(),
            TypeKind.Enum => generate_enum_serializer::<T>(),
            TypeKind.Primitive => generate_primitive_serializer::<T>(),
            _ => compile_error!("Unsupported type"),
        }
    }
}
```

### Field Iteration

```home
const fn generate_debug<T>() -> fn(&T) -> string {
    comptime {
        |value: &T| {
            let mut result = type_name::<T>() + " { "

            for field in fields_of::<T>() {
                result += field.name + ": "
                result += format_value(field.get(value))
                result += ", "
            }

            result + "}"
        }
    }
}
```

## Compile-Time String Processing

### String Manipulation

```home
const fn to_snake_case(s: &str) -> string {
    comptime {
        let mut result = String.new()
        for (i, c) in s.chars().enumerate() {
            if c.is_uppercase() && i > 0 {
                result.push('_')
            }
            result.push(c.to_lowercase())
        }
        result
    }
}

const TABLE_NAME: &str = to_snake_case("UserProfile")  // "user_profile"
```

### Parse at Compile Time

```home
const fn parse_version(s: &str) -> (u32, u32, u32) {
    comptime {
        let parts: []&str = s.split('.')
        (
            parts[0].parse::<u32>().unwrap(),
            parts[1].parse::<u32>().unwrap(),
            parts[2].parse::<u32>().unwrap(),
        )
    }
}

const VERSION: (u32, u32, u32) = parse_version("1.2.3")
static_assert!(VERSION.0 >= 1, "Major version must be at least 1")
```

## Compile-Time Code Generation

### Generate Implementations

```home
macro derive_arithmetic($name:ident) {
    comptime {
        impl Add for $name {
            type Output = Self

            fn add(self, other: Self) -> Self {
                Self {
                    $(
                        $field: self.$field + other.$field
                    ),*
                }
            }
        }

        impl Sub for $name {
            type Output = Self

            fn sub(self, other: Self) -> Self {
                Self {
                    $(
                        $field: self.$field - other.$field
                    ),*
                }
            }
        }
    }
}

#[derive_arithmetic]
struct Vector3 {
    x: f64,
    y: f64,
    z: f64,
}
```

### Generate Tests

```home
const fn generate_property_tests<T>() {
    comptime {
        for field in fields_of::<T>() {
            #[test]
            fn test_{field.name}_roundtrip() {
                let original = T.random()
                let serialized = serialize(original.{field.name})
                let deserialized = deserialize(serialized)
                assert_eq!(original.{field.name}, deserialized)
            }
        }
    }
}

generate_property_tests::<User>()
```

## Compile-Time Validation

### Validate at Compile Time

```home
const fn validate_regex(pattern: &str) -> Result<(), &str> {
    comptime {
        let mut paren_depth = 0
        for c in pattern.chars() {
            match c {
                '(' => paren_depth += 1,
                ')' => {
                    paren_depth -= 1
                    if paren_depth < 0 {
                        return Err("Unmatched closing parenthesis")
                    }
                }
                _ => {}
            }
        }
        if paren_depth != 0 {
            Err("Unmatched opening parenthesis")
        } else {
            Ok(())
        }
    }
}

// Compile error if regex is invalid
const PATTERN: Regex = comptime {
    validate_regex(r"(\d+)-(\d+)").unwrap()
    Regex.compile(r"(\d+)-(\d+)")
}
```

### Validate SQL at Compile Time

```home
const fn validate_sql(query: &str) -> Result<Query, SqlError> {
    comptime {
        let parsed = parse_sql(query)?
        validate_table_names(parsed)?
        validate_column_names(parsed)?
        Ok(parsed)
    }
}

// Type-safe, validated SQL
const QUERY: Query = validate_sql!(
    "SELECT name, email FROM users WHERE id = ?"
)
```

## Performance Optimization

### Lookup Tables

```home
// Generate CRC32 table at compile time
const CRC32_TABLE: [u32; 256] = comptime {
    let mut table = [0u32; 256]
    for i in 0..256 {
        let mut crc = i as u32
        for _ in 0..8 {
            crc = if crc & 1 != 0 {
                0xEDB88320 ^ (crc >> 1)
            } else {
                crc >> 1
            }
        }
        table[i] = crc
    }
    table
}

fn crc32(data: &[u8]) -> u32 {
    let mut crc = 0xFFFFFFFF
    for byte in data {
        let index = ((crc ^ *byte as u32) & 0xFF) as usize
        crc = CRC32_TABLE[index] ^ (crc >> 8)
    }
    !crc
}
```

### Constant Folding

```home
const fn optimize_expression() -> i32 {
    // All of this is evaluated at compile time
    let a = 10 * 20
    let b = a + 50
    let c = b * 2
    c / 5
}

const RESULT: i32 = optimize_expression()  // 90, no runtime computation
```

## Best Practices

1. **Use const for simple computations**:
   ```home
   const BUFFER_SIZE: usize = 4 * 1024  // Simple arithmetic
   const MASK: u32 = (1 << 16) - 1       // Bit manipulation
   ```

2. **Use comptime for complex generation**:
   ```home
   const TABLE: [u8; 256] = comptime {
       generate_complex_table()
   }
   ```

3. **Validate at compile time when possible**:
   ```home
   static_assert!(CONFIG.is_valid(), "Invalid configuration")
   ```

4. **Prefer compile-time over runtime checks**:
   ```home
   // Good: Compile-time check
   const fn create_array<const N: usize>() where const N <= 1024 {
       [0; N]
   }

   // Avoid: Runtime check for constants
   fn create_array(n: usize) {
       assert!(n <= 1024);
       vec![0; n]
   }
   ```

5. **Document compile-time requirements**:
   ```home
   /// Creates an optimized lookup table.
   ///
   /// # Compile-Time Requirements
   /// - SIZE must be a power of 2
   /// - SIZE must be <= 65536
   const fn create_table<const SIZE: usize>() -> [u8; SIZE]
   where
       const is_power_of_two(SIZE),
       const SIZE <= 65536,
   ```
