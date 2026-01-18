# Metaprogramming

Metaprogramming in Home enables writing code that generates, analyzes, or transforms other code. This powerful capability allows for reducing boilerplate, creating domain-specific languages, and implementing advanced abstractions.

## Overview

Home's metaprogramming facilities include:

- **Compile-time reflection**: Inspect types and their structure
- **Procedural macros**: Generate code programmatically
- **Derive macros**: Auto-implement traits
- **Build scripts**: Pre-compilation code generation
- **Source generation**: Create Home code from external data

## Compile-Time Reflection

### Type Introspection

```home
const fn describe_type<T>() -> TypeDescription {
    TypeDescription {
        name: type_name::<T>(),
        size: size_of::<T>(),
        align: align_of::<T>(),
        kind: type_kind::<T>(),
    }
}

enum TypeKind {
    Struct { fields: []FieldInfo },
    Enum { variants: []VariantInfo },
    Primitive,
    Pointer { pointee: Type },
    Array { element: Type, length: usize },
    Slice { element: Type },
    Function { params: []Type, return_type: Type },
    Trait { methods: []MethodInfo },
}

fn main() {
    let desc = describe_type::<MyStruct>()
    print("Type: {}", desc.name)
    print("Size: {} bytes", desc.size)
}
```

### Field Reflection

```home
struct User {
    id: u64,
    name: string,
    email: string,
    active: bool,
}

const USER_FIELDS: []FieldInfo = fields_of::<User>()

fn print_fields() {
    for field in USER_FIELDS {
        print("Field: {} ({})", field.name, field.type_name)
        print("  Offset: {}", field.offset)
        print("  Size: {}", field.size)
    }
}

// Output:
// Field: id (u64)
//   Offset: 0
//   Size: 8
// Field: name (string)
//   Offset: 8
//   Size: 24
// ...
```

### Method Reflection

```home
trait Service {
    fn start(&mut self) -> Result<(), Error>
    fn stop(&mut self) -> Result<(), Error>
    fn status(&self) -> Status
}

const SERVICE_METHODS: []MethodInfo = methods_of::<dyn Service>()

fn generate_proxy<T: Service>() -> ServiceProxy<T> {
    comptime {
        for method in SERVICE_METHODS {
            // Generate proxy method that adds logging
            generate_logged_method(method)
        }
    }
}
```

## Procedural Code Generation

### Generating Structs

```home
const fn generate_dto<T>(prefix: &str) -> Type {
    comptime {
        let fields = fields_of::<T>()

        let dto_fields = fields
            .filter(|f| !f.has_attribute("internal"))
            .map(|f| FieldDef {
                name: f.name,
                ty: if f.has_attribute("optional") {
                    Option::<f.ty>
                } else {
                    f.ty
                },
            })

        define_struct(
            format!("{prefix}{}", type_name::<T>()),
            dto_fields,
        )
    }
}

// Original
struct User {
    id: u64,
    name: string,
    #[internal]
    password_hash: string,
    #[optional]
    bio: string,
}

// Generated: UserDto { id: u64, name: string, bio: ?string }
type UserDto = generate_dto::<User>("Dto")
```

### Generating Functions

```home
const fn generate_getters<T>() {
    comptime {
        for field in fields_of::<T>() {
            // Generate getter method
            fn get_{field.name}(&self) -> &{field.ty} {
                &self.{field.name}
            }

            // Generate setter if mutable
            if !field.has_attribute("readonly") {
                fn set_{field.name}(&mut self, value: {field.ty}) {
                    self.{field.name} = value
                }
            }
        }
    }
}

struct Config {
    #[readonly]
    id: u64,
    name: string,
    value: i32,
}

impl Config {
    generate_getters!()
}

// Now has: get_id(), get_name(), set_name(), get_value(), set_value()
```

### Generating Enums

```home
const fn generate_error_enum(
    name: &str,
    variants: [](&str, &str)
) -> Type {
    comptime {
        let enum_variants = variants.map(|(name, message)| {
            VariantDef {
                name: name,
                fields: [],
                attributes: [Attribute.error_message(message)],
            }
        })

        define_enum(name, enum_variants)
    }
}

type NetworkError = generate_error_enum!("NetworkError", [
    ("ConnectionRefused", "Connection was refused by remote host"),
    ("Timeout", "Operation timed out"),
    ("DnsFailure", "DNS resolution failed"),
])
```

## Trait Implementation Generation

### Derive-Style Generation

```home
const fn derive_serialize<T>() {
    comptime {
        impl Serialize for T {
            fn serialize(&self, serializer: &mut Serializer) -> Result<(), Error> {
                serializer.begin_object(type_name::<T>())?;

                $(
                    for field in fields_of::<T>() {
                        let field_name = field.name;
                        if field.has_attribute("skip") {
                            continue;
                        }

                        let key = field.get_attribute("rename")
                            .unwrap_or(field_name);

                        serializer.field(key, &self.{field_name})?;
                    }
                )*

                serializer.end_object()
            }
        }
    }
}

#[derive(Serialize)]
struct Product {
    id: u64,
    #[rename = "product_name"]
    name: string,
    price: f64,
    #[skip]
    internal_code: string,
}
```

### Conditional Trait Implementation

```home
const fn derive_clone_if_possible<T>() {
    comptime {
        let all_fields_clone = fields_of::<T>()
            .all(|f| f.ty: Clone)

        if all_fields_clone {
            impl Clone for T {
                fn clone(&self) -> Self {
                    Self {
                        $(
                            {field.name}: self.{field.name}.clone()
                        ),*
                    }
                }
            }
        } else {
            // Generate helpful compile error
            compile_error!(
                "Cannot derive Clone for {}: field '{}' does not implement Clone",
                type_name::<T>(),
                fields_of::<T>().find(|f| !(f.ty: Clone)).unwrap().name
            )
        }
    }
}
```

## Domain-Specific Languages

### Query DSL

```home
macro query($($tokens:tt)*) {
    comptime {
        let ast = parse_query!($($tokens)*)
        validate_query(ast)?
        generate_query_code(ast)
    }
}

fn get_users() -> Vec<User> {
    query! {
        SELECT * FROM users
        WHERE active = true
        AND created_at > @start_date
        ORDER BY name
        LIMIT 100
    }
}

// Expands to type-safe, optimized query code
```

### State Machine DSL

```home
macro state_machine($name:ident { $($states:tt)* }) {
    comptime {
        let states = parse_states!($($states)*)
        validate_transitions(states)?

        generate_state_enum(states)
        generate_state_machine_struct(name, states)
        generate_transition_methods(name, states)
    }
}

state_machine! {
    OrderStateMachine {
        Pending -> [Confirmed, Cancelled],
        Confirmed -> [Shipped, Cancelled],
        Shipped -> [Delivered, Returned],
        Delivered -> [Returned],
        Cancelled -> [],
        Returned -> [],
    }
}

// Generates type-safe state transitions
let mut order = OrderStateMachine.new()  // Starts in Pending
order.confirm()?   // Pending -> Confirmed
order.ship()?      // Confirmed -> Shipped
// order.confirm()  // Compile error: Shipped cannot transition to Confirmed
```

### Builder DSL

```home
macro builder($struct:ty) {
    comptime {
        let fields = fields_of::<$struct>()

        struct {$struct}Builder {
            $(
                {field.name}: Option<{field.ty}>
            ),*
        }

        impl {$struct}Builder {
            fn new() -> Self {
                Self {
                    $(
                        {field.name}: None
                    ),*
                }
            }

            $(
                fn {field.name}(mut self, value: {field.ty}) -> Self {
                    self.{field.name} = Some(value)
                    self
                }
            )*

            fn build(self) -> Result<{$struct}, BuilderError> {
                Ok({$struct} {
                    $(
                        {field.name}: self.{field.name}
                            .ok_or(BuilderError.missing("{field.name}"))?
                    ),*
                })
            }
        }
    }
}

#[builder]
struct Request {
    method: HttpMethod,
    url: Url,
    headers: Headers,
    body: ?Body,
}

let request = RequestBuilder.new()
    .method(HttpMethod.Get)
    .url(Url.parse("https://example.com")?)
    .headers(Headers.default())
    .build()?
```

## Build-Time Code Generation

### Build Scripts

```home
// build.home
fn main() {
    // Generate code from protobuf definitions
    protobuf.compile(&["src/proto/api.proto"], &["src/proto/"])
        .output("src/generated/")
        .run()?

    // Generate bindings from C headers
    bindgen.builder()
        .header("native/wrapper.h")
        .generate()?
        .write_to_file("src/bindings.home")?

    // Generate version info
    let version = env.var("CARGO_PKG_VERSION")?
    let git_hash = git.head_commit_hash()?

    write_file("src/version.home", format!(r#"
        pub const VERSION: &str = "{version}";
        pub const GIT_HASH: &str = "{git_hash}";
        pub const BUILD_TIME: &str = "{build_time}";
    "#, build_time = now()))?
}
```

### Code Generation from Data

```home
// build.home
fn generate_country_codes() {
    let countries: []CountryData = json.parse(include_str!("data/countries.json"))?

    let mut code = String.new()
    code += "pub enum Country {\n"

    for country in countries {
        code += format!("    {} = {},\n", country.code, country.numeric_code)
    }

    code += "}\n\n"
    code += "impl Country {\n"
    code += "    pub fn name(&self) -> &'static str {\n"
    code += "        match self {\n"

    for country in countries {
        code += format!("            Self.{} => \"{}\",\n", country.code, country.name)
    }

    code += "        }\n"
    code += "    }\n"
    code += "}\n"

    write_file("src/countries.home", code)?
}
```

## Advanced Patterns

### Type-Safe Wrappers

```home
const fn newtype_wrapper<T, Name: &str>() {
    comptime {
        struct {Name}(T);

        impl {Name} {
            fn new(value: T) -> Self {
                {Name}(value)
            }

            fn into_inner(self) -> T {
                self.0
            }
        }

        impl Deref for {Name} {
            type Target = T

            fn deref(&self) -> &T {
                &self.0
            }
        }

        impl From<T> for {Name} {
            fn from(value: T) -> Self {
                {Name}(value)
            }
        }

        impl Into<T> for {Name} {
            fn into(self) -> T {
                self.0
            }
        }
    }
}

// Generate strongly-typed wrappers
newtype_wrapper!(u64, "UserId")
newtype_wrapper!(u64, "OrderId")
newtype_wrapper!(string, "Email")

// Type system prevents mixing them up
fn get_user(id: UserId) -> User { /* ... */ }
fn get_order(id: OrderId) -> Order { /* ... */ }
```

### Aspect-Oriented Programming

```home
macro aspect($aspect:ident, $($method:ident),*) {
    comptime {
        $(
            let original = get_method::<Self>($method)

            fn $method($(original.params)*) -> $(original.return_type) {
                $aspect::before(stringify!($method))
                let result = original.call($(original.param_names)*)
                $aspect::after(stringify!($method), &result)
                result
            }
        )*
    }
}

struct LoggingAspect;

impl LoggingAspect {
    fn before(method: &str) {
        log.debug("Entering {method}")
    }

    fn after<T>(method: &str, result: &T) {
        log.debug("Exiting {method}")
    }
}

impl UserService {
    #[aspect(LoggingAspect, create_user, update_user, delete_user)]
}
```

### Plugin Systems

```home
trait Plugin {
    const NAME: &str
    const VERSION: &str

    fn initialize(&mut self, context: &PluginContext)
    fn shutdown(&mut self)
}

macro register_plugins($($plugin:ty),*) {
    comptime {
        static PLUGINS: []PluginInfo = [
            $(
                PluginInfo {
                    name: <$plugin>::NAME,
                    version: <$plugin>::VERSION,
                    create: || Box.new(<$plugin>::new()),
                }
            ),*
        ];

        pub fn load_plugins(context: &PluginContext) -> Vec<Box<dyn Plugin>> {
            PLUGINS.iter()
                .map(|info| {
                    let mut plugin = (info.create)();
                    plugin.initialize(context);
                    plugin
                })
                .collect()
        }
    }
}

register_plugins!(
    AuthPlugin,
    LoggingPlugin,
    MetricsPlugin,
)
```

## Best Practices

1. **Generate readable code**:
   ```home
   // Generated code should be human-readable for debugging
   const fn generate_impl<T>() {
       comptime {
           // Add comments explaining generation
           /// Auto-generated implementation for {type_name::<T>()}
           impl Debug for T { /* ... */ }
       }
   }
   ```

2. **Provide good error messages**:
   ```home
   const fn derive_feature<T>() {
       comptime {
           if !has_required_fields::<T>() {
               compile_error!(
                   "Cannot derive Feature for {}: missing required field 'id'.\n\
                    Add a field: id: u64",
                   type_name::<T>()
               )
           }
       }
   }
   ```

3. **Test generated code**:
   ```home
   #[test]
   fn test_generated_serializer() {
       #[derive(Serialize, Deserialize)]
       struct TestStruct { value: i32 }

       let original = TestStruct { value: 42 }
       let json = serialize(&original)
       let restored: TestStruct = deserialize(json)?

       assert_eq!(original.value, restored.value)
   }
   ```

4. **Document generation behavior**:
   ```home
   /// Generates a builder for the annotated struct.
   ///
   /// # Generated Methods
   /// - `new()` - Creates empty builder
   /// - `field_name(value)` - Sets each field
   /// - `build()` - Constructs the struct
   ///
   /// # Attributes
   /// - `#[default = value]` - Provides default value
   /// - `#[required]` - Must be set before build
   macro builder($struct:ty) { /* ... */ }
   ```

5. **Prefer standard derives when available**:
   ```home
   // Use built-in derives when possible
   #[derive(Debug, Clone, PartialEq)]
   struct Simple { value: i32 }

   // Custom derives for domain-specific needs
   #[derive(Serialize, Validate, Audit)]
   struct DomainObject { /* ... */ }
   ```
