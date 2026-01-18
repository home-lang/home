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
    fn puts(s: *const c_char) -> c_int
    fn printf(format: *const c_char, ...) -> c_int
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
#[link(name = "m")]
extern "C" {
    fn sin(x: f64) -> f64
    fn cos(x: f64) -> f64
    fn sqrt(x: f64) -> f64
}

// Link to static library
#[link(name = "mylib", kind = "static")]
extern "C" {
    fn custom_function(x: i32) -> i32
}

// Link to dynamic library
#[link(name = "openssl")]
extern "C" {
    fn SSL_library_init() -> c_int
}
```

### C Type Mappings

```home
// C-compatible type aliases
type c_char = i8
type c_short = i16
type c_int = i32
type c_long = i64  // Platform-dependent in C, fixed in Home
type c_float = f32
type c_double = f64
type c_void = void
type size_t = usize
type ssize_t = isize

// Pointer types
type c_str = *const c_char
type c_str_mut = *mut c_char
```

## Struct Layout

### C-Compatible Structs

```home
// Ensure C-compatible layout
#[repr(C)]
struct Point {
    x: f64,
    y: f64,
}

#[repr(C)]
struct Rectangle {
    origin: Point,
    size: Point,
}

extern "C" {
    fn draw_rectangle(rect: *const Rectangle)
}

fn main() {
    let rect = Rectangle {
        origin: Point { x: 0.0, y: 0.0 },
        size: Point { x: 100.0, y: 50.0 },
    }

    unsafe {
        draw_rectangle(&rect)
    }
}
```

### Packed Structs

```home
// Remove padding
#[repr(C, packed)]
struct PackedData {
    flag: u8,
    value: u32,
    // No padding between flag and value
}

// Specify alignment
#[repr(C, align(16))]
struct AlignedData {
    data: [f32; 4],
}
```

### Union Types

```home
#[repr(C)]
union Value {
    i: i64,
    f: f64,
    p: *mut void,
}

fn use_union() {
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
    fn register_callback(cb: CCallback, data: *mut void)
    fn trigger_callbacks()
}

// Home callback with C calling convention
extern "C" fn my_callback(data: *mut void, value: i32) -> i32 {
    let counter = unsafe { &mut *(data as *mut i32) }
    *counter += value
    *counter
}

fn main() {
    let mut counter = 0i32

    unsafe {
        register_callback(my_callback, &mut counter as *mut i32 as *mut void)
        trigger_callbacks()
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

fn with_callback<F: Fn(i32) -> i32>(callback: F) {
    let wrapper = CallbackWrapper { callback }

    unsafe {
        register_callback(
            trampoline::<F>,
            &wrapper as *const _ as *mut void
        )
        trigger_callbacks()
    }
}
```

## String Handling

### C Strings

```home
use std.ffi.{CString, CStr}

fn c_string_example() {
    // Create C string from Home string
    let home_str = "Hello, World!"
    let c_str = CString.new(home_str).unwrap()

    unsafe {
        puts(c_str.as_ptr())
    }

    // Convert C string back to Home string
    unsafe {
        let ptr = get_c_string()  // Returns *const c_char
        let c_str = CStr.from_ptr(ptr)
        let home_str = c_str.to_string()
    }
}
```

### String Literals

```home
// C string literals
let c_literal = c"This is a C string\0"  // *const c_char

// Wide string literals
let wide_literal = w"Wide string"  // *const wchar_t

// UTF-16 literals (for Windows)
let utf16_literal = u16"UTF-16 string"  // *const u16
```

## Memory Management

### Ownership Across FFI

```home
extern "C" {
    // C allocates, we must free
    fn create_buffer(size: usize) -> *mut u8
    fn destroy_buffer(ptr: *mut u8)

    // We allocate, C uses
    fn process_data(data: *const u8, len: usize)
}

fn safe_buffer_usage() {
    // RAII wrapper for C-allocated memory
    struct CBuffer {
        ptr: *mut u8,
        len: usize,
    }

    impl CBuffer {
        fn new(size: usize) -> Self {
            let ptr = unsafe { create_buffer(size) }
            CBuffer { ptr, len: size }
        }
    }

    impl Drop for CBuffer {
        fn drop(mut self) {
            unsafe { destroy_buffer(self.ptr) }
        }
    }

    let buffer = CBuffer.new(1024)
    // Automatically freed when buffer goes out of scope
}
```

### Box and FFI

```home
extern "C" {
    fn store_data(data: *mut Data)
    fn retrieve_data() -> *mut Data
}

fn box_ffi() {
    // Pass owned data to C
    let data = Box.new(Data { value: 42 })
    unsafe {
        store_data(Box.into_raw(data))
    }

    // Retrieve and take ownership back
    unsafe {
        let ptr = retrieve_data()
        let data = Box.from_raw(ptr)
        // data is now managed by Home again
    }
}
```

## Error Handling

### C Error Codes

```home
extern "C" {
    fn open_file(path: *const c_char) -> c_int
    fn get_last_error() -> c_int
    fn error_message(code: c_int) -> *const c_char
}

fn safe_open(path: &str) -> Result<FileHandle, Error> {
    let c_path = CString.new(path)?

    let fd = unsafe { open_file(c_path.as_ptr()) }

    if fd < 0 {
        let code = unsafe { get_last_error() }
        let msg = unsafe {
            CStr.from_ptr(error_message(code)).to_string()
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

fn with_errno<T>(f: fn() -> T, success: fn(T) -> bool) -> Result<T, Error> {
    errno.set(0)
    let result = f()

    if success(result) {
        Ok(result)
    } else {
        let code = errno.get()
        Err(Error.from_errno(code))
    }
}
```

## Opaque Types

### Working with Opaque Pointers

```home
// Opaque type (size unknown)
#[repr(C)]
struct OpaqueHandle {
    _private: [u8; 0],
}

extern "C" {
    fn create_handle() -> *mut OpaqueHandle
    fn use_handle(handle: *mut OpaqueHandle)
    fn destroy_handle(handle: *mut OpaqueHandle)
}

// Safe wrapper
struct Handle {
    raw: *mut OpaqueHandle,
}

impl Handle {
    fn new() -> Self {
        Handle { raw: unsafe { create_handle() } }
    }

    fn use_it(&self) {
        unsafe { use_handle(self.raw) }
    }
}

impl Drop for Handle {
    fn drop(mut self) {
        unsafe { destroy_handle(self.raw) }
    }
}
```

## Platform-Specific Code

### Conditional Compilation

```home
#[cfg(target_os = "windows")]
#[link(name = "kernel32")]
extern "C" {
    fn GetLastError() -> u32
    fn SetLastError(code: u32)
}

#[cfg(target_os = "linux")]
#[link(name = "pthread")]
extern "C" {
    fn pthread_create(...) -> c_int
    fn pthread_join(...) -> c_int
}

#[cfg(target_os = "macos")]
#[link(name = "System")]
extern "C" {
    fn dispatch_async(...)
}
```

### Platform-Specific Types

```home
#[cfg(target_os = "windows")]
type RawHandle = *mut void
#[cfg(target_os = "windows")]
const INVALID_HANDLE: RawHandle = -1 as *mut void

#[cfg(unix)]
type RawFd = c_int
#[cfg(unix)]
const INVALID_FD: RawFd = -1
```

## Automatic Binding Generation

### Using bindgen

```home
// build.home
fn main() {
    bindgen.builder()
        .header("wrapper.h")
        .allowlist_function("mylib_.*")
        .allowlist_type("MyLib.*")
        .generate()
        .write_to_file("src/bindings.home")
}

// Generates type-safe bindings from C headers
```

### Inline Headers

```home
#[ffi_header(r#"
    typedef struct {
        int x;
        int y;
    } Point;

    Point* create_point(int x, int y);
    void destroy_point(Point* p);
"#)]
mod c_bindings {}

// Automatically generates Home bindings
```

## Exporting Home Functions

### C-Callable Functions

```home
// Export function with C ABI
#[no_mangle]
pub extern "C" fn home_add(a: i32, b: i32) -> i32 {
    a + b
}

// Export with custom name
#[no_mangle]
#[export_name = "calculate"]
pub extern "C" fn home_calculate(x: f64) -> f64 {
    x * x + 2.0 * x + 1.0
}
```

### Creating Shared Libraries

```home
// lib.home
#[no_mangle]
pub extern "C" fn library_init() -> c_int {
    // Initialize library
    0
}

#[no_mangle]
pub extern "C" fn library_process(data: *const u8, len: usize) -> *mut u8 {
    // Process data
}

#[no_mangle]
pub extern "C" fn library_cleanup() {
    // Cleanup
}
```

## Edge Cases

### Varargs Functions

```home
extern "C" {
    fn printf(format: *const c_char, ...) -> c_int
}

fn call_printf() {
    unsafe {
        printf(c"Integer: %d, Float: %f\n", 42i32, 3.14f64)
    }
}
```

### Bitfields

```home
// Bitfields require manual handling
#[repr(C)]
struct Flags {
    bits: u32,
}

impl Flags {
    fn flag_a(self) -> bool { (self.bits & 0x1) != 0 }
    fn flag_b(self) -> bool { (self.bits & 0x2) != 0 }
    fn set_flag_a(mut self, val: bool) {
        if val { self.bits |= 0x1 } else { self.bits &= !0x1 }
    }
}
```

### Callbacks with Lifetime Issues

```home
// Be careful with callback lifetimes
extern "C" {
    fn async_operation(callback: extern "C" fn(*mut void), data: *mut void)
}

fn dangerous_example() {
    let local_data = 42

    // WRONG: local_data may be gone when callback fires
    // async_operation(my_callback, &local_data as *const _ as *mut void)

    // CORRECT: Use heap allocation
    let boxed = Box.new(42)
    async_operation(my_callback, Box.into_raw(boxed) as *mut void)
}
```

## Best Practices

1. **Wrap unsafe FFI in safe interfaces**:
   ```home
   // Internal unsafe implementation
   mod ffi {
       extern "C" {
           pub fn dangerous_function(ptr: *mut u8)
       }
   }

   // Safe public API
   pub fn safe_function(data: &mut [u8]) {
       unsafe {
           ffi.dangerous_function(data.as_mut_ptr())
       }
   }
   ```

2. **Document safety requirements**:
   ```home
   /// Calls the C function `process_buffer`.
   ///
   /// # Safety
   /// - `ptr` must be valid for reads of `len` bytes
   /// - `ptr` must be properly aligned
   /// - The memory must not be mutated during this call
   unsafe fn process(ptr: *const u8, len: usize) {
       ffi.process_buffer(ptr, len)
   }
   ```

3. **Use RAII for resource management**:
   ```home
   struct CResource {
       handle: *mut void,
   }

   impl Drop for CResource {
       fn drop(mut self) {
           if !self.handle.is_null() {
               unsafe { free_resource(self.handle) }
           }
       }
   }
   ```

4. **Validate at the FFI boundary**:
   ```home
   #[no_mangle]
   pub extern "C" fn api_function(ptr: *const u8, len: usize) -> c_int {
       if ptr.is_null() {
           return -1  // Error code
       }

       let slice = unsafe { std.slice.from_raw_parts(ptr, len) }

       match internal_function(slice) {
           Ok(_) => 0,
           Err(_) => -2,
       }
   }
   ```

5. **Test FFI code thoroughly**:
   ```home
   #[test]
   fn test_c_interop() {
       let data = [1u8, 2, 3, 4]
       let result = unsafe {
           c_function(data.as_ptr(), data.len())
       }
       assert(result == expected_value)
   }
   ```
