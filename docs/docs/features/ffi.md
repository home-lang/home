# Foreign Function Interface (FFI)

Home's FFI system enables seamless interoperability with C, C++, and other languages. It provides safe abstractions over foreign code while maintaining Home's safety guarantees at the boundary.

## Overview

Home FFI offers:

- **C ABI compatibility**: Direct calling of C functions
- **Safe wrappers**: Type-safe interfaces over unsafe foreign code
- **Bidirectional bindings**: Call foreign code and expose Home functions
- **Automatic binding generation**: Generate bindings from C headers
- **Platform-specific linking**: Configure library linking per platform

## Basic C FFI

### Declaring External Functions

```home
// Declare external C functions
extern "C" {
    fn puts(s: *const c*char) -> c*int
    fn printf(format: *const c*char, ...) -> c*int
    fn malloc(size: usize) -> *mut void
    fn free(ptr: *mut void)
}

// Usage
fn main() {
    unsafe {
        let msg = c"Hello from Home!"
        puts(msg)
    }
}
```

### Linking Libraries

```home
// Link to system library
# [link(name = "m")]
extern "C" {
    fn sin(x: f64) -> f64
    fn cos(x: f64) -> f64
    fn sqrt(x: f64) -> f64
}

// Link to static library
# [link(name = "mylib", kind = "static")]
extern "C" {
    fn custom*function(x: i32) -> i32
}

// Link to dynamic library
# [link(name = "openssl")]
extern "C" {
    fn SSL*library*init() -> c*int
}
```

### C Type Mappings

```home
// C-compatible type aliases
type c*char = i8
type c*short = i16
type c*int = i32
type c*long = i64  // Platform-dependent in C, fixed in Home
type c*float = f32
type c*double = f64
type c*void = void
type size*t = usize
type ssize*t = isize

// Pointer types
type c*str = *const c*char
type c*str*mut = *mut c*char
```

## Struct Layout

### C-Compatible Structs

```home
// Ensure C-compatible layout
# [repr(C)]
struct Point {
    x: f64,
    y: f64,
}

# [repr(C)]
struct Rectangle {
    origin: Point,
    size: Point,
}

extern "C" {
    fn draw*rectangle(rect: *const Rectangle)
}

fn main() {
    let rect = Rectangle {
        origin: Point { x: 0.0, y: 0.0 },
        size: Point { x: 100.0, y: 50.0 },
    }

    unsafe {
        draw*rectangle(&rect)
    }
}
```

### Packed Structs

```home
// Remove padding
# [repr(C, packed)]
struct PackedData {
    flag: u8,
    value: u32,
    // No padding between flag and value
}

// Specify alignment
# [repr(C, align(16))]
struct AlignedData {
    data: [f32; 4],
}
```

### Union Types

```home
# [repr(C)]
union Value {
    i: i64,
    f: f64,
    p: *mut void,
}

fn use*union() {
    let mut v = Value { i: 42 }

    unsafe {
        print("as int: {}", v.i)
        v.f = 3.14
        print("as float: {}", v.f)
    }
}
```

## Callbacks and Function Pointers

### Passing Callbacks to C

```home
// C function type
type CCallback = extern "C" fn(data: *mut void, value: i32) -> i32

extern "C" {
    fn register*callback(cb: CCallback, data: *mut void)
    fn trigger*callbacks()
}

// Home callback with C calling convention
extern "C" fn my*callback(data: *mut void, value: i32) -> i32 {
    let counter = unsafe { &mut *(data as *mut i32) }
    *counter += value
    *counter
}

fn main() {
    let mut counter = 0i32

    unsafe {
        register*callback(my*callback, &mut counter as *mut i32 as *mut void)
        trigger*callbacks()
        print("Counter: {counter}")
    }
}
```

### Closures as Callbacks

```home
// Wrapper for closure-based callbacks
struct CallbackWrapper<F> {
    callback: F,
}

extern "C" fn trampoline<F: Fn(i32) -> i32>(data: *mut void, value: i32) -> i32 {
    let wrapper = unsafe { &*(data as *const CallbackWrapper<F>) }
    (wrapper.callback)(value)
}

fn with*callback<F: Fn(i32) -> i32>(callback: F) {
    let wrapper = CallbackWrapper { callback }

    unsafe {
        register*callback(
            trampoline::<F>,
            &wrapper as *const * as *mut void
        )
        trigger*callbacks()
    }
}
```

## String Handling

### C Strings

```home
use std.ffi.{CString, CStr}

fn c*string*example() {
    // Create C string from Home string
    let home*str = "Hello, World!"
    let c*str = CString.new(home*str).unwrap()

    unsafe {
        puts(c*str.as*ptr())
    }

    // Convert C string back to Home string
    unsafe {
        let ptr = get*c*string()  // Returns *const c*char
        let c*str = CStr.from*ptr(ptr)
        let home*str = c*str.to*string()
    }
}
```

### String Literals

```home
// C string literals
let c*literal = c"This is a C string\0"  // *const c*char

// Wide string literals
let wide*literal = w"Wide string"  // *const wchar*t

// UTF-16 literals (for Windows)
let utf16*literal = u16"UTF-16 string"  // *const u16
```

## Memory Management

### Ownership Across FFI

```home
extern "C" {
    // C allocates, we must free
    fn create*buffer(size: usize) -> *mut u8
    fn destroy*buffer(ptr: *mut u8)

    // We allocate, C uses
    fn process*data(data: *const u8, len: usize)
}

fn safe*buffer*usage() {
    // RAII wrapper for C-allocated memory
    struct CBuffer {
        ptr: *mut u8,
        len: usize,
    }

    impl CBuffer {
        fn new(size: usize) -> Self {
            let ptr = unsafe { create*buffer(size) }
            CBuffer { ptr, len: size }
        }
    }

    impl Drop for CBuffer {
        fn drop(mut self) {
            unsafe { destroy*buffer(self.ptr) }
        }
    }

    let buffer = CBuffer.new(1024)
    // Automatically freed when buffer goes out of scope
}
```

### Box and FFI

```home
extern "C" {
    fn store*data(data: *mut Data)
    fn retrieve*data() -> *mut Data
}

fn box*ffi() {
    // Pass owned data to C
    let data = Box.new(Data { value: 42 })
    unsafe {
        store*data(Box.into*raw(data))
    }

    // Retrieve and take ownership back
    unsafe {
        let ptr = retrieve*data()
        let data = Box.from*raw(ptr)
        // data is now managed by Home again
    }
}
```

## Error Handling

### C Error Codes

```home
extern "C" {
    fn open*file(path: *const c*char) -> c*int
    fn get*last*error() -> c*int
    fn error*message(code: c*int) -> *const c*char
}

fn safe*open(path: &str) -> Result<FileHandle, Error> {
    let c*path = CString.new(path)?

    let fd = unsafe { open*file(c*path.as*ptr()) }

    if fd < 0 {
        let code = unsafe { get*last*error() }
        let msg = unsafe {
            CStr.from*ptr(error*message(code)).to*string()
        }
        Err(Error.new(msg))
    } else {
        Ok(FileHandle { fd })
    }
}
```

### errno Handling

```home
use std.ffi.errno

fn with*errno<T>(f: fn() -> T, success: fn(T) -> bool) -> Result<T, Error> {
    errno.set(0)
    let result = f()

    if success(result) {
        Ok(result)
    } else {
        let code = errno.get()
        Err(Error.from*errno(code))
    }
}
```

## Opaque Types

### Working with Opaque Pointers

```home
// Opaque type (size unknown)
# [repr(C)]
struct OpaqueHandle {
    *private: [u8; 0],
}

extern "C" {
    fn create*handle() -> *mut OpaqueHandle
    fn use*handle(handle: *mut OpaqueHandle)
    fn destroy*handle(handle: *mut OpaqueHandle)
}

// Safe wrapper
struct Handle {
    raw: *mut OpaqueHandle,
}

impl Handle {
    fn new() -> Self {
        Handle { raw: unsafe { create*handle() } }
    }

    fn use*it(&self) {
        unsafe { use*handle(self.raw) }
    }
}

impl Drop for Handle {
    fn drop(mut self) {
        unsafe { destroy*handle(self.raw) }
    }
}
```

## Platform-Specific Code

### Conditional Compilation

```home
# [cfg(target*os = "windows")]
# [link(name = "kernel32")]
extern "C" {
    fn GetLastError() -> u32
    fn SetLastError(code: u32)
}

# [cfg(target*os = "linux")]
# [link(name = "pthread")]
extern "C" {
    fn pthread*create(...) -> c*int
    fn pthread*join(...) -> c*int
}

# [cfg(target*os = "macos")]
# [link(name = "System")]
extern "C" {
    fn dispatch*async(...)
}
```

### Platform-Specific Types

```home
# [cfg(target*os = "windows")]
type RawHandle = *mut void
# [cfg(target*os = "windows")]
const INVALID*HANDLE: RawHandle = -1 as *mut void

# [cfg(unix)]
type RawFd = c*int
# [cfg(unix)]
const INVALID*FD: RawFd = -1
```

## Automatic Binding Generation

### Using bindgen

```home
// build.home
fn main() {
    bindgen.builder()
        .header("wrapper.h")
        .allowlist*function("mylib*.*")
        .allowlist*type("MyLib.*")
        .generate()
        .write*to*file("src/bindings.home")
}

// Generates type-safe bindings from C headers
```

### Inline Headers

```home
# [ffi*header(r#"
    typedef struct {
        int x;
        int y;
    } Point;

    Point* create*point(int x, int y);
    void destroy*point(Point* p);
"#)]
mod c*bindings {}

// Automatically generates Home bindings
```

## Exporting Home Functions

### C-Callable Functions

```home
// Export function with C ABI
# [no*mangle]
pub extern "C" fn home*add(a: i32, b: i32) -> i32 {
    a + b
}

// Export with custom name
# [no*mangle]
# [export*name = "calculate"]
pub extern "C" fn home*calculate(x: f64) -> f64 {
    x * x + 2.0 * x + 1.0
}
```

### Creating Shared Libraries

```home
// lib.home
# [no*mangle]
pub extern "C" fn library*init() -> c*int {
    // Initialize library
    0
}

# [no*mangle]
pub extern "C" fn library*process(data: *const u8, len: usize) -> *mut u8 {
    // Process data
}

# [no*mangle]
pub extern "C" fn library*cleanup() {
    // Cleanup
}
```

## Edge Cases

### Varargs Functions

```home
extern "C" {
    fn printf(format: *const c*char, ...) -> c*int
}

fn call*printf() {
    unsafe {
        printf(c"Integer: %d, Float: %f\n", 42i32, 3.14f64)
    }
}
```

### Bitfields

```home
// Bitfields require manual handling
# [repr(C)]
struct Flags {
    bits: u32,
}

impl Flags {
    fn flag*a(self) -> bool { (self.bits & 0x1) != 0 }
    fn flag*b(self) -> bool { (self.bits & 0x2) != 0 }
    fn set*flag*a(mut self, val: bool) {
        if val { self.bits |= 0x1 } else { self.bits &= !0x1 }
    }
}
```

### Callbacks with Lifetime Issues

```home
// Be careful with callback lifetimes
extern "C" {
    fn async*operation(callback: extern "C" fn(*mut void), data: *mut void)
}

fn dangerous*example() {
    let local*data = 42

    // WRONG: local*data may be gone when callback fires
    // async*operation(my*callback, &local*data as *const * as *mut void)

    // CORRECT: Use heap allocation
    let boxed = Box.new(42)
    async*operation(my*callback, Box.into*raw(boxed) as *mut void)
}
```

## Best Practices

1. **Wrap unsafe FFI in safe interfaces**:

   ```home
   // Internal unsafe implementation
   mod ffi {
       extern "C" {
           pub fn dangerous*function(ptr: *mut u8)
       }
   }

   // Safe public API
   pub fn safe*function(data: &mut [u8]) {
       unsafe {
           ffi.dangerous*function(data.as*mut*ptr())
       }
   }
   ```

2. **Document safety requirements**:

   ```home
   /// Calls the C function `process*buffer`.
   ///
   /// # Safety
   /// - `ptr` must be valid for reads of `len` bytes
   /// - `ptr` must be properly aligned
   /// - The memory must not be mutated during this call
   unsafe fn process(ptr: *const u8, len: usize) {
       ffi.process*buffer(ptr, len)
   }
   ```

3. **Use RAII for resource management**:

   ```home
   struct CResource {
       handle: *mut void,
   }

   impl Drop for CResource {
       fn drop(mut self) {
           if !self.handle.is*null() {
               unsafe { free*resource(self.handle) }
           }
       }
   }
   ```

4. **Validate at the FFI boundary**:

   ```home
   #[no*mangle]
   pub extern "C" fn api*function(ptr: *const u8, len: usize) -> c*int {
       if ptr.is*null() {
           return -1  // Error code
       }

       let slice = unsafe { std.slice.from*raw*parts(ptr, len) }

       match internal*function(slice) {
           Ok(*) => 0,
           Err(*) => -2,
       }
   }
   ```

5. **Test FFI code thoroughly**:

   ```home
   #[test]
   fn test*c*interop() {
       let data = [1u8, 2, 3, 4]
       let result = unsafe {
           c*function(data.as*ptr(), data.len())
       }
       assert(result == expected_value)
   }
   ```
