# Async Programming

Home provides first-class async/await support for writing efficient concurrent code. The async runtime is designed for high-performance I/O-bound applications while maintaining the language's safety guarantees.

## Overview

Home's async model features:

- **Zero-cost futures**: State machines compiled from async functions
- **Structured concurrency**: Clear ownership of concurrent tasks
- **Cancellation safety**: Proper resource cleanup on cancellation
- **Runtime agnostic**: Pluggable runtime implementations

## Async Functions

### Basic Async Functions

```home
async fn fetch_data(url: string) -> Result<string, Error> {
    let response = http.get(url).await?
    let body = response.text().await?
    Ok(body)
}

async fn main() {
    let data = fetch_data("https://api.example.com/data").await
    match data {
        Ok(content) => print("Got: {content}"),
        Err(e) => print("Error: {e}"),
    }
}
```

### Async Closures

```home
let fetch = async |url: string| -> Result<string, Error> {
    let resp = http.get(url).await?
    resp.text().await
}

let result = fetch("https://example.com").await?
```

### Async Blocks

```home
fn start_operation() -> impl Future<Output = i32> {
    async {
        let a = compute_a().await
        let b = compute_b().await
        a + b
    }
}
```

## Futures and Polling

### The Future Trait

```home
trait Future {
    type Output

    fn poll(self: Pin<&mut Self>, cx: &mut Context) -> Poll<Self.Output>
}

enum Poll<T> {
    Ready(T),
    Pending,
}
```

### Implementing Custom Futures

```home
struct Delay {
    when: Instant,
}

impl Future for Delay {
    type Output = ()

    fn poll(self: Pin<&mut Self>, cx: &mut Context) -> Poll<()> {
        if Instant.now() >= self.when {
            Poll.Ready(())
        } else {
            // Schedule wake-up
            let waker = cx.waker().clone()
            let when = self.when

            thread.spawn(move || {
                thread.sleep(when - Instant.now())
                waker.wake()
            })

            Poll.Pending
        }
    }
}

async fn delay(duration: Duration) {
    Delay { when: Instant.now() + duration }.await
}
```

## Concurrent Execution

### Join - Concurrent Execution

```home
use async.join

async fn fetch_all() -> (User, Posts, Comments) {
    // All three requests run concurrently
    let (user, posts, comments) = join!(
        fetch_user(user_id),
        fetch_posts(user_id),
        fetch_comments(user_id),
    ).await

    (user, posts, comments)
}
```

### Select - Racing Futures

```home
use async.select

async fn with_timeout<T>(
    future: impl Future<Output = T>,
    timeout: Duration,
) -> Result<T, TimeoutError> {
    select! {
        result = future => Ok(result),
        _ = delay(timeout) => Err(TimeoutError),
    }
}
```

### Try Join - Short-Circuit on Error

```home
use async.try_join

async fn fetch_data() -> Result<(A, B, C), Error> {
    // If any fails, others are cancelled
    let (a, b, c) = try_join!(
        fetch_a(),
        fetch_b(),
        fetch_c(),
    )?

    Ok((a, b, c))
}
```

## Task Spawning

### Spawning Tasks

```home
use async.task

async fn main() {
    // Spawn a task that runs independently
    let handle = task.spawn(async {
        expensive_computation().await
    })

    // Do other work
    other_work().await

    // Wait for spawned task
    let result = handle.await
}
```

### Task Pools

```home
use async.task.{spawn, spawn_blocking}

async fn process_items(items: []Item) {
    let mut handles = vec![]

    for item in items {
        let handle = task.spawn(async move {
            process_item(item).await
        })
        handles.push(handle)
    }

    // Wait for all tasks
    for handle in handles {
        handle.await
    }
}

// CPU-bound work on blocking thread pool
async fn hash_file(path: string) -> Hash {
    spawn_blocking(move || {
        let data = std.fs.read(path).unwrap()
        compute_hash(&data)
    }).await
}
```

### Scoped Tasks

```home
use async.task.scope

async fn process_with_scope(data: &[u8]) {
    task.scope(|s| async {
        s.spawn(async { process_first_half(&data[..data.len()/2]).await })
        s.spawn(async { process_second_half(&data[data.len()/2..]).await })
    }).await
    // All spawned tasks complete before scope ends
    // Safe to reference local data
}
```

## Channels

### Async Channels

```home
use async.channel.{mpsc, oneshot}

async fn producer_consumer() {
    let (tx, rx) = mpsc.channel::<i32>(100)  // Bounded channel

    // Producer task
    let producer = task.spawn(async move {
        for i in 0..10 {
            tx.send(i).await.unwrap()
        }
    })

    // Consumer task
    let consumer = task.spawn(async move {
        while let Some(value) = rx.recv().await {
            print("Got: {value}")
        }
    })

    producer.await
    consumer.await
}
```

### Oneshot Channels

```home
use async.channel.oneshot

async fn request_response() {
    let (tx, rx) = oneshot.channel::<Response>()

    task.spawn(async move {
        let response = compute_response().await
        tx.send(response).unwrap()
    })

    let response = rx.await.unwrap()
}
```

### Broadcast Channels

```home
use async.channel.broadcast

async fn pub_sub() {
    let (tx, _) = broadcast.channel::<Event>(100)

    // Multiple subscribers
    for i in 0..3 {
        let mut rx = tx.subscribe()
        task.spawn(async move {
            while let Ok(event) = rx.recv().await {
                print("Subscriber {i} got: {event}")
            }
        })
    }

    // Publisher
    tx.send(Event.new("hello")).unwrap()
}
```

## Async Streams

### Creating Streams

```home
use async.stream.{Stream, StreamExt}

async fn generate_numbers() -> impl Stream<Item = i32> {
    async_stream! {
        for i in 0..10 {
            delay(Duration.from_millis(100)).await
            yield i
        }
    }
}

async fn consume_stream() {
    let stream = generate_numbers().await

    while let Some(n) = stream.next().await {
        print("Got: {n}")
    }
}
```

### Stream Combinators

```home
async fn process_stream() {
    let results = generate_items()
        .filter(|item| item.is_valid())
        .map(|item| async { transform(item).await })
        .buffer_unordered(10)  // Process up to 10 concurrently
        .collect::<Vec<_>>()
        .await
}
```

### Merging Streams

```home
use async.stream.{select, merge}

async fn combined_sources() {
    let stream1 = network_events()
    let stream2 = timer_events()
    let stream3 = user_events()

    let combined = merge!(stream1, stream2, stream3)

    while let Some(event) = combined.next().await {
        handle_event(event).await
    }
}
```

## Synchronization Primitives

### Async Mutex

```home
use async.sync.Mutex

struct SharedState {
    data: Mutex<HashMap<string, i32>>,
}

impl SharedState {
    async fn get(&self, key: &str) -> ?i32 {
        let guard = self.data.lock().await
        guard.get(key).copied()
    }

    async fn set(&self, key: string, value: i32) {
        let mut guard = self.data.lock().await
        guard.insert(key, value)
    }
}
```

### Async RwLock

```home
use async.sync.RwLock

struct Cache {
    data: RwLock<HashMap<string, Value>>,
}

impl Cache {
    async fn get(&self, key: &str) -> ?Value {
        // Multiple readers allowed
        let guard = self.data.read().await
        guard.get(key).cloned()
    }

    async fn set(&self, key: string, value: Value) {
        // Exclusive write access
        let mut guard = self.data.write().await
        guard.insert(key, value)
    }
}
```

### Semaphore

```home
use async.sync.Semaphore

struct RateLimiter {
    semaphore: Semaphore,
}

impl RateLimiter {
    fn new(max_concurrent: usize) -> Self {
        RateLimiter {
            semaphore: Semaphore.new(max_concurrent),
        }
    }

    async fn acquire(&self) -> SemaphoreGuard {
        self.semaphore.acquire().await.unwrap()
    }
}

async fn limited_operation(limiter: &RateLimiter) {
    let _guard = limiter.acquire().await
    // Only max_concurrent operations run simultaneously
    do_work().await
}  // Guard dropped, permit released
```

## Cancellation

### Cancellation Tokens

```home
use async.CancellationToken

async fn long_running_task(cancel: CancellationToken) -> Result<Data, Error> {
    loop {
        select! {
            _ = cancel.cancelled() => {
                return Err(Error.Cancelled)
            }
            result = do_work() => {
                if result.is_complete() {
                    return Ok(result)
                }
            }
        }
    }
}

async fn main() {
    let cancel = CancellationToken.new()
    let cancel_clone = cancel.clone()

    let task = task.spawn(async move {
        long_running_task(cancel_clone).await
    })

    // Cancel after timeout
    delay(Duration.from_secs(30)).await
    cancel.cancel()

    let result = task.await
}
```

### Graceful Shutdown

```home
async fn server_main() {
    let shutdown = CancellationToken.new()

    // Handle shutdown signal
    let shutdown_clone = shutdown.clone()
    task.spawn(async move {
        signal.ctrl_c().await.unwrap()
        print("Shutdown signal received")
        shutdown_clone.cancel()
    })

    // Run server until shutdown
    let server = Server.bind("0.0.0.0:8080")
        .serve(app)
        .with_graceful_shutdown(shutdown.cancelled())

    server.await.unwrap()
    print("Server shut down gracefully")
}
```

## Runtime Configuration

### Configuring the Runtime

```home
fn main() {
    let runtime = Runtime.builder()
        .worker_threads(4)
        .thread_name("my-worker")
        .enable_io()
        .enable_time()
        .build()
        .unwrap()

    runtime.block_on(async {
        async_main().await
    })
}
```

### Thread-Per-Core Model

```home
fn main() {
    let runtime = Runtime.builder()
        .flavor(RuntimeFlavor.CurrentThread)
        .enable_all()
        .build()
        .unwrap()

    // Run on single thread
    runtime.block_on(async_main())
}
```

## Best Practices

1. **Don't block in async code**:
   ```home
   // Bad: Blocks the async runtime
   async fn bad() {
       std.thread.sleep(Duration.from_secs(1))
   }

   // Good: Use async sleep
   async fn good() {
       async.sleep(Duration.from_secs(1)).await
   }

   // For CPU-bound work
   async fn compute() {
       spawn_blocking(|| heavy_computation()).await
   }
   ```

2. **Use structured concurrency**:
   ```home
   // Good: Clear task lifetime
   task.scope(|s| async {
       s.spawn(task_a())
       s.spawn(task_b())
   }).await

   // Avoid: Orphaned tasks
   task.spawn(background_task())  // Who waits for this?
   ```

3. **Handle cancellation properly**:
   ```home
   async fn with_cleanup(cancel: CancellationToken) {
       select! {
           _ = cancel.cancelled() => {
               cleanup().await  // Always cleanup
               return
           }
           result = operation() => {
               process(result).await
           }
       }
   }
   ```

4. **Bound channel sizes**:
   ```home
   // Good: Prevents unbounded memory growth
   let (tx, rx) = mpsc.channel::<Event>(100)

   // Risky: Can grow without limit
   let (tx, rx) = mpsc.unbounded_channel::<Event>()
   ```

5. **Use timeouts for external operations**:
   ```home
   async fn fetch_with_timeout(url: string) -> Result<Response, Error> {
       with_timeout(
           http.get(url),
           Duration.from_secs(30),
       ).await
   }
   ```
