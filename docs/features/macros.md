# Macros

Home's macro system provides powerful metaprogramming capabilities, enabling code generation, domain-specific languages, and compile-time computation. Macros operate on the abstract syntax tree, providing type-aware transformations.

## Overview

Home macros offer:

- **Declarative macros**: Pattern-based code generation
- **Procedural macros**: Full programmatic AST manipulation
- **Derive macros**: Automatic trait implementation generation
- **Attribute macros**: Transform items with custom attributes
- **Hygiene**: Prevent accidental name capture and conflicts

## Declarative Macros

### Basic Syntax

Declarative macros match patterns and expand to code:

```home
macro vec($($element:expr),* $(,)?) {
    {
        let mut temp = Vec.new()
        $(temp.push($element);)*
        temp
    }
}

// Usage
let numbers = vec![1, 2, 3, 4, 5]
let strings = vec!["a", "b", "c"]
```

### Pattern Matching in Macros

```home
macro match_type($value:expr) {
    match $value {
        _ if std.type_name::<typeof($value)>() == "i32" => "integer",
        _ if std.type_name::<typeof($value)>() == "string" => "string",
        _ => "unknown",
    }
}
```

### Repetition Patterns

```home
// Zero or more (*)
macro println($fmt:literal $(, $arg:expr)*) {
    print($fmt $(, $arg)*)
    print("\n")
}

// One or more (+)
macro min($first:expr $(, $rest:expr)+) {
    {
        let mut result = $first
        $(
            if $rest < result {
                result = $rest
            }
        )+
        result
    }
}

// Zero or one (?)
macro optional_init($name:ident: $type:ty $(= $default:expr)?) {
    let $name: $type = $($default)?
}
```

### Fragment Types

```home
macro demonstrate_fragments(
    $ident:ident,        // Identifier
    $expr:expr,          // Expression
    $ty:ty,              // Type
    $pat:pat,            // Pattern
    $stmt:stmt,          // Statement
    $block:block,        // Block expression
    $item:item,          // Item (fn, struct, etc.)
    $path:path,          // Type path
    $literal:literal,    // Literal value
    $lifetime:lifetime,  // Lifetime
    $meta:meta,          // Attribute content
) {
    // ... expansion
}
```

### Recursive Macros

```home
macro count($($element:tt)*) {
    0 $(+ count!(@single $element))*
}

macro count(@single $element:tt) {
    1
}

// Usage
let n = count!(a b c d e)  // 5
```

## Procedural Macros

### Function-like Procedural Macros

```home
#[proc_macro]
fn sql(input: TokenStream) -> TokenStream {
    let query = parse_sql(input)
    let validated = validate_query(query)
    generate_query_code(validated)
}

// Usage
let users = sql!(SELECT * FROM users WHERE age > 18)
```

### Implementing Procedural Macros

```home
use home.proc_macro.{TokenStream, TokenTree, Literal, Ident, Punct}

#[proc_macro]
fn json(input: TokenStream) -> TokenStream {
    let parsed = parse_json_tokens(input)

    let mut output = TokenStream.new()
    output.extend(quote! {
        JsonValue.Object(HashMap.from([
            #(#parsed),*
        ]))
    })

    output
}
```

## Derive Macros

### Basic Derive

```home
#[derive(Debug, Clone, PartialEq)]
struct Point {
    x: f64,
    y: f64,
}

// Automatically implements:
// - Debug: formatted debug output
// - Clone: value copying
// - PartialEq: equality comparison
```

### Custom Derive Macros

```home
#[proc_macro_derive(Serialize)]
fn derive_serialize(input: TokenStream) -> TokenStream {
    let ast = parse_derive_input(input)
    let name = ast.ident
    let fields = get_fields(ast)

    quote! {
        impl Serialize for #name {
            fn serialize(&self, serializer: &mut Serializer) -> Result<(), Error> {
                serializer.begin_object()?
                #(
                    serializer.field(stringify!(#fields), &self.#fields)?
                )*
                serializer.end_object()
            }
        }
    }
}
```

### Derive with Attributes

```home
#[proc_macro_derive(Serialize, attributes(serde))]
fn derive_serialize_with_attrs(input: TokenStream) -> TokenStream {
    // Can now process #[serde(...)] attributes on fields
}

// Usage
#[derive(Serialize)]
struct User {
    #[serde(rename = "user_name")]
    name: string,

    #[serde(skip)]
    password_hash: string,

    #[serde(default)]
    active: bool,
}
```

## Attribute Macros

### Basic Attribute Macros

```home
#[proc_macro_attribute]
fn route(attr: TokenStream, item: TokenStream) -> TokenStream {
    let route_path = parse_route_path(attr)
    let function = parse_fn(item)

    quote! {
        #[doc = concat!("Route: ", #route_path)]
        #function

        inventory.submit! {
            Route {
                path: #route_path,
                handler: #function.name,
            }
        }
    }
}

// Usage
#[route("/api/users")]
fn get_users() -> Response {
    // ...
}
```

### Transforming Items

```home
#[proc_macro_attribute]
fn async_trait(_attr: TokenStream, item: TokenStream) -> TokenStream {
    let trait_def = parse_trait(item)

    // Transform async fn to return BoxFuture
    let transformed = trait_def.methods.map(|method| {
        if method.is_async {
            transform_async_method(method)
        } else {
            method
        }
    })

    quote! {
        trait #trait_def.name {
            #(#transformed)*
        }
    }
}
```

## Macro Hygiene

### Hygienic Identifiers

```home
macro create_var() {
    let x = 42  // This 'x' won't conflict with outer 'x'
}

let x = 10
create_var!()
print(x)  // Still 10, macro's x is separate
```

### Breaking Hygiene When Needed

```home
macro declare($name:ident, $value:expr) {
    let $name = $value  // $name escapes hygiene
}

declare!(answer, 42)
print(answer)  // 42 - accessible because we used the caller's identifier
```

### Span Manipulation

```home
#[proc_macro]
fn with_span(input: TokenStream) -> TokenStream {
    let span = input.span()  // Preserve source location

    quote_spanned! { span =>
        // Generated code points to original location for errors
        compile_error!("Something went wrong")
    }
}
```

## Built-in Macros

### Compile-Time Assertions

```home
// Static assertion
static_assert!(size_of::<i32>() == 4)
static_assert!(align_of::<u64>() == 8)

// Const evaluation
const VALUE: i32 = const_eval!(factorial(10))
```

### Debug and Inspection

```home
// Print expression and value
let x = 5
dbg!(x * 2)  // Prints: [file:line] x * 2 = 10

// Get type name
let name = type_name!(Vec<i32>)  // "Vec<i32>"

// Get file/line/column
let location = source_location!()  // "src/main.home:42:5"
```

### Conditional Compilation

```home
macro cfg($condition:meta) {
    // Evaluates condition at compile time
}

#[cfg(target_os = "linux")]
fn platform_specific() {
    // Only compiled on Linux
}

let value = cfg!(debug_mode) ? "debug" : "release"
```

## Domain-Specific Languages

### SQL DSL

```home
macro sql($($tokens:tt)*) {
    parse_and_validate_sql!($($tokens)*)
}

let query = sql! {
    SELECT name, email
    FROM users
    WHERE active = true
    ORDER BY created_at DESC
    LIMIT 10
}
```

### HTML DSL

```home
macro html($($tokens:tt)*) {
    parse_html!($($tokens)*)
}

let page = html! {
    <div class="container">
        <h1>{title}</h1>
        <p>{content}</p>
        <ul>
            {for item in items {
                <li>{item}</li>
            }}
        </ul>
    </div>
}
```

### Regex DSL

```home
macro regex($pattern:literal) {
    // Compile-time regex validation
    compile_regex!($pattern)
}

let email_pattern = regex!(r"^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$")
```

## Advanced Techniques

### Token Tree Munching

```home
macro parse_list($($tokens:tt)*) {
    parse_list_impl!([] $($tokens)*)
}

macro parse_list_impl([$($acc:expr),*] $head:expr, $($rest:tt)*) {
    parse_list_impl!([$($acc,)* $head] $($rest)*)
}

macro parse_list_impl([$($acc:expr),*] $last:expr) {
    [$($acc,)* $last]
}

macro parse_list_impl([$($acc:expr),*]) {
    [$($acc),*]
}
```

### Push-Down Accumulation

```home
macro reverse($($items:expr),*) {
    reverse_impl!([] $($items),*)
}

macro reverse_impl([$($acc:expr),*] $head:expr $(, $rest:expr)*) {
    reverse_impl!([$head $(, $acc)*] $($rest),*)
}

macro reverse_impl([$($acc:expr),*]) {
    ($($acc),*)
}

let reversed = reverse!(1, 2, 3, 4, 5)  // (5, 4, 3, 2, 1)
```

### Callback Pattern

```home
macro with_each($callback:ident, $($items:expr),*) {
    $(
        $callback!($items);
    )*
}

macro print_item($item:expr) {
    print("{:?}", $item)
}

with_each!(print_item, 1, 2, 3)
```

## Edge Cases

### Macro Ordering

```home
// Macros must be defined before use in the same module
// Or imported from another module

// This works:
macro first() { 1 }
let a = first!()

// Forward references require imports:
use other_module.later_macro
let b = later_macro!()
```

### Ambiguous Syntax

```home
// Use parentheses to disambiguate
macro ambiguous($e:expr) {
    ($e) + 1  // Parentheses ensure correct parsing
}

// Token trees for maximum flexibility
macro flexible($($tt:tt)*) {
    // Can handle any syntax
}
```

### Recursive Expansion Limits

```home
// Home has a recursion limit (default 128)
#![recursion_limit = "256"]

macro deeply_recursive($n:expr) {
    // ... deep recursion ...
}
```

## Best Practices

1. **Prefer functions over macros when possible**:
   ```home
   // Use function
   fn add(a: i32, b: i32) -> i32 { a + b }

   // Use macro only when needed (variadic, syntax extension, etc.)
   macro sum($($n:expr),+) { 0 $(+ $n)+ }
   ```

2. **Document macro syntax clearly**:
   ```home
   /// Creates a HashMap with the given key-value pairs.
   ///
   /// # Syntax
   /// ```
   /// map! { key1 => value1, key2 => value2 }
   /// ```
   macro map($($key:expr => $value:expr),* $(,)?) {
       // ...
   }
   ```

3. **Provide helpful error messages**:
   ```home
   macro require_even($n:expr) {
       const _: () = {
           if $n % 2 != 0 {
               compile_error!(concat!(stringify!($n), " must be even"))
           }
       };
   }
   ```

4. **Test macro edge cases**:
   ```home
   #[test]
   fn test_vec_macro() {
       assert_eq!(vec![], Vec::<i32>.new())
       assert_eq!(vec![1], vec![1])
       assert_eq!(vec![1,], vec![1])  // Trailing comma
       assert_eq!(vec![1, 2, 3], vec![1, 2, 3])
   }
   ```

5. **Use appropriate macro delimiters**:
   ```home
   // Parentheses for function-like macros
   println!("hello")

   // Braces for block-like macros
   html! { <div>content</div> }

   // Brackets for collection-like macros
   vec![1, 2, 3]
   ```
