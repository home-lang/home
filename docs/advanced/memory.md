# Memory Safety

Home provides memory safety without garbage collection through a combination of ownership, borrowing, and lifetime analysis. This approach catches memory errors at compile time while maintaining predictable performance.

## Overview

Home's memory safety guarantees:

- **No null pointer dereferences**: Optional types replace null
- **No use-after-free**: Ownership prevents dangling pointers
- **No double-free**: Single ownership ensures one deallocation
- **No data races**: Borrowing rules prevent concurrent mutation
- **No buffer overflows**: Bounds checking with opt-out

## Ownership Model

### Single Ownership

Every value has exactly one owner:

```home
fn main() {
    let s1 = String.from("hello")  // s1 owns the string
    let s2 = s1                     // Ownership moves to s2
    // print(s1)                    // Error: s1 no longer valid

    print(s2)  // OK: s2 is the owner
}  // s2 is dropped here, memory freed
```

### Move Semantics

```home
struct LargeData {
    buffer: [u8; 1_000_000],
}

fn process(data: LargeData) {
    // data is moved in, this function owns it
    // ...
}  // data dropped here

fn main() {
    let data = LargeData { buffer: [0; 1_000_000] }
    process(data)      // Ownership transfers
    // process(data)   // Error: data was moved
}
```

### Copy Types

Small, simple types implement Copy for implicit duplication:

```home
#[derive(Copy, Clone)]
struct Point {
    x: i32,
    y: i32,
}

fn main() {
    let p1 = Point { x: 1, y: 2 }
    let p2 = p1  // p1 is copied, not moved
    print("{p1.x}, {p2.x}")  // Both valid
}
```

### Clone for Explicit Copies

```home
let s1 = String.from("hello")
let s2 = s1.clone()  // Explicit deep copy
print("{s1}, {s2}")  // Both valid
```

## Borrowing

### Immutable Borrows

```home
fn calculate_length(s: &string) -> usize {
    s.len()
}  // s goes out of scope, but doesn't drop (it's borrowed)

fn main() {
    let s = String.from("hello")
    let len = calculate_length(&s)  // Borrow s
    print("Length of '{s}' is {len}")  // s still valid
}
```

### Mutable Borrows

```home
fn append_world(s: &mut string) {
    s.push_str(", world!")
}

fn main() {
    let mut s = String.from("hello")
    append_world(&mut s)  // Mutable borrow
    print(s)  // "hello, world!"
}
```

### Borrowing Rules

```home
fn main() {
    let mut data = vec![1, 2, 3]

    // Multiple immutable borrows OK
    let r1 = &data
    let r2 = &data
    print("{r1:?}, {r2:?}")

    // Mutable borrow requires exclusivity
    let r3 = &mut data
    // let r4 = &data       // Error: can't borrow while mutably borrowed
    // let r5 = &mut data   // Error: only one mutable borrow
    r3.push(4)

    // After mutable borrow ends, immutable borrows OK again
    print("{data:?}")
}
```

## Lifetimes

### Lifetime Annotations

```home
// Return reference must live as long as input
fn longest<'a>(x: &'a str, y: &'a str) -> &'a str {
    if x.len() > y.len() { x } else { y }
}

fn main() {
    let s1 = String.from("long string")
    let result

    {
        let s2 = String.from("short")
        result = longest(&s1, &s2)
        print("Longest: {result}")
    }  // s2 dropped here

    // print(result)  // Error: result might reference s2
}
```

### Lifetime Elision

Common patterns have implicit lifetimes:

```home
// These are equivalent:
fn first_word(s: &str) -> &str
fn first_word<'a>(s: &'a str) -> &'a str

// Multiple references with different lifetimes:
fn pick_first<'a, 'b>(x: &'a str, y: &'b str) -> &'a str {
    x
}
```

### Struct Lifetimes

```home
struct Parser<'input> {
    source: &'input str,
    position: usize,
}

impl<'input> Parser<'input> {
    fn new(source: &'input str) -> Self {
        Parser { source, position: 0 }
    }

    fn remaining(&self) -> &'input str {
        &self.source[self.position..]
    }
}
```

### Static Lifetime

```home
// Lives for entire program
let s: &'static str = "Hello, world!"

// Static references from const
const CONFIG: &'static Config = &Config {
    debug: true,
    max_connections: 100,
}

// Lazy static for runtime initialization
static DATABASE: Lazy<Database> = Lazy.new(|| {
    Database.connect("localhost:5432")
})
```

## Stack and Heap Allocation

### Stack Allocation

```home
fn stack_example() {
    // Allocated on stack, fixed size
    let array: [i32; 100] = [0; 100]
    let point = Point { x: 1, y: 2 }
    let number: i32 = 42

    // Fast allocation and deallocation
    // Automatically cleaned up when scope ends
}
```

### Heap Allocation

```home
fn heap_example() {
    // Box: heap allocation with ownership
    let boxed: Box<[i32; 1000000]> = Box.new([0; 1000000])

    // Vec: growable heap array
    let mut vec: Vec<i32> = Vec.new()
    vec.push(1)
    vec.push(2)

    // String: heap-allocated UTF-8 text
    let s = String.from("hello")

    // All heap memory freed when owners go out of scope
}
```

### Custom Allocators

```home
use std.alloc.{Allocator, Global, Layout}

struct BumpAllocator {
    arena: []u8,
    offset: usize,
}

impl Allocator for BumpAllocator {
    fn allocate(&mut self, layout: Layout) -> Result<*mut u8, AllocError> {
        let aligned_offset = align_up(self.offset, layout.align())
        let end = aligned_offset + layout.size()

        if end > self.arena.len() {
            return Err(AllocError)
        }

        let ptr = &mut self.arena[aligned_offset] as *mut u8
        self.offset = end
        Ok(ptr)
    }

    fn deallocate(&mut self, _ptr: *mut u8, _layout: Layout) {
        // Bump allocators don't deallocate individually
    }
}

// Use with collections
let allocator = BumpAllocator.new(arena)
let vec: Vec<i32, BumpAllocator> = Vec.new_in(allocator)
```

## Smart Pointers

### Box<T>

```home
// Heap allocation with single ownership
let boxed = Box.new(5)
print(*boxed)  // Dereference to access value

// Recursive types require Box
struct Node {
    value: i32,
    next: ?Box<Node>,
}
```

### Rc<T> - Reference Counting

```home
use std.rc.Rc

fn shared_data() {
    let data = Rc.new(vec![1, 2, 3])

    let clone1 = Rc.clone(&data)  // Increment count
    let clone2 = Rc.clone(&data)  // Increment count

    print("Count: {}", Rc.strong_count(&data))  // 3

    drop(clone1)  // Decrement count
    print("Count: {}", Rc.strong_count(&data))  // 2
}  // Remaining refs dropped, data freed
```

### Arc<T> - Atomic Reference Counting

```home
use std.sync.Arc
use std.thread

fn concurrent_access() {
    let data = Arc.new(vec![1, 2, 3])
    let mut handles = vec![]

    for i in 0..3 {
        let data_clone = Arc.clone(&data)
        let handle = thread.spawn(move || {
            print("Thread {i}: {data_clone:?}")
        })
        handles.push(handle)
    }

    for handle in handles {
        handle.join().unwrap()
    }
}
```

### Weak<T> - Non-Owning References

```home
use std.rc.{Rc, Weak}

struct Node {
    value: i32,
    parent: Weak<Node>,  // Prevent cycles
    children: Vec<Rc<Node>>,
}

fn build_tree() {
    let parent = Rc.new(Node {
        value: 1,
        parent: Weak.new(),
        children: vec![],
    })

    let child = Rc.new(Node {
        value: 2,
        parent: Rc.downgrade(&parent),  // Weak reference
        children: vec![],
    })

    // Access weak reference
    if let Some(p) = child.parent.upgrade() {
        print("Parent: {p.value}")
    }
}
```

## Interior Mutability

### Cell<T>

```home
use std.cell.Cell

struct Counter {
    value: Cell<i32>,  // Mutable through shared reference
}

impl Counter {
    fn increment(&self) {  // Note: &self, not &mut self
        let v = self.value.get()
        self.value.set(v + 1)
    }
}

fn main() {
    let counter = Counter { value: Cell.new(0) }
    counter.increment()
    counter.increment()
    print("Count: {}", counter.value.get())  // 2
}
```

### RefCell<T>

```home
use std.cell.RefCell

struct Graph {
    nodes: RefCell<Vec<Node>>,
}

impl Graph {
    fn add_node(&self, node: Node) {
        self.nodes.borrow_mut().push(node)
    }

    fn print_nodes(&self) {
        for node in self.nodes.borrow().iter() {
            print("{node:?}")
        }
    }
}
```

### Mutex<T>

```home
use std.sync.Mutex

static COUNTER: Mutex<i32> = Mutex.new(0)

fn increment() {
    let mut count = COUNTER.lock().unwrap()
    *count += 1
}  // Lock released here

fn main() {
    let handles: Vec<_> = (0..10)
        .map(|_| thread.spawn(increment))
        .collect()

    for h in handles {
        h.join().unwrap()
    }

    print("Final: {}", *COUNTER.lock().unwrap())  // 10
}
```

## Unsafe Code

### When Unsafe is Needed

```home
// Raw pointer operations
unsafe fn deref_raw(ptr: *const i32) -> i32 {
    *ptr
}

// Calling unsafe functions
fn use_raw_pointer() {
    let x = 42
    let ptr = &x as *const i32

    unsafe {
        print("Value: {}", deref_raw(ptr))
    }
}
```

### Unsafe Blocks

```home
fn split_at_mut(slice: &mut [i32], mid: usize) -> (&mut [i32], &mut [i32]) {
    let len = slice.len()
    let ptr = slice.as_mut_ptr()

    assert(mid <= len)

    unsafe {
        (
            std.slice.from_raw_parts_mut(ptr, mid),
            std.slice.from_raw_parts_mut(ptr.add(mid), len - mid),
        )
    }
}
```

### Safe Abstractions over Unsafe Code

```home
pub struct SafeBuffer {
    ptr: *mut u8,
    len: usize,
    cap: usize,
}

impl SafeBuffer {
    pub fn new(capacity: usize) -> Self {
        let layout = Layout.array::<u8>(capacity).unwrap()
        let ptr = unsafe { std.alloc.alloc(layout) }

        SafeBuffer {
            ptr,
            len: 0,
            cap: capacity,
        }
    }

    pub fn push(&mut self, byte: u8) {
        assert(self.len < self.cap, "Buffer full")
        unsafe {
            *self.ptr.add(self.len) = byte
        }
        self.len += 1
    }

    pub fn as_slice(&self) -> &[u8] {
        unsafe {
            std.slice.from_raw_parts(self.ptr, self.len)
        }
    }
}

impl Drop for SafeBuffer {
    fn drop(&mut self) {
        let layout = Layout.array::<u8>(self.cap).unwrap()
        unsafe {
            std.alloc.dealloc(self.ptr, layout)
        }
    }
}
```

## Best Practices

1. **Minimize unsafe code**:
   ```home
   // Encapsulate unsafe in small, well-audited functions
   fn safe_wrapper(data: &[u8]) -> u32 {
       unsafe { internal_unsafe_operation(data.as_ptr(), data.len()) }
   }
   ```

2. **Prefer borrowing over ownership transfer**:
   ```home
   // Good: Only borrows what it needs
   fn analyze(data: &[Point]) -> Summary

   // Avoid: Takes ownership unnecessarily
   fn analyze(data: Vec<Point>) -> Summary
   ```

3. **Use appropriate smart pointers**:
   ```home
   // Single owner: Box
   let data = Box.new(large_struct)

   // Shared read-only: Rc or Arc
   let shared = Rc.new(config)

   // Shared mutable: Arc<Mutex<T>> or Arc<RwLock<T>>
   let concurrent = Arc.new(Mutex.new(state))
   ```

4. **Document lifetime requirements**:
   ```home
   /// Returns a reference to the first matching element.
   ///
   /// The returned reference is valid as long as `items` is not modified.
   fn find<'a>(items: &'a [Item], predicate: fn(&Item) -> bool) -> ?&'a Item
   ```

5. **Use RAII for resource management**:
   ```home
   struct FileGuard {
       handle: FileHandle,
   }

   impl Drop for FileGuard {
       fn drop(&mut self) {
           self.handle.close()
       }
   }
   ```
