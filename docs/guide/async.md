# Async Programming

Home provides zero-cost async/await for concurrent programming without blocking threads.

## Async Basics

### Async Functions

Declare async functions with the `async` keyword in the return type:

```home
fn fetch_user(id: int): async Result<User> {
  let response = await http.get("/api/users/{id}")
  return await response.json()
}
```

### Calling Async Functions

Use `await` to get the result of an async function:

```home
fn main(): async {
  let user = await fetch_user(1)
  print("User: {user.name}")
}
```

### Async Closures

```home
let fetch = async || {
  let data = await http.get("/api/data")
  data.json()
}

let result = await fetch()
```

## Concurrent Execution

### Sequential Execution

Awaiting in sequence:

```home
fn fetch_all_sequential(): async Result<Data> {
  let users = await fetch_users()    // Wait for this
  let posts = await fetch_posts()    // Then wait for this
  let comments = await fetch_comments()  // Then this

  return Ok(Data { users, posts, comments })
}
```

### Parallel Execution

Use `join` for concurrent execution:

```home
fn fetch_all_parallel(): async Result<Data> {
  // All three fetch concurrently
  let (users, posts, comments) = await join!(
    fetch_users(),
    fetch_posts(),
    fetch_comments()
  )

  return Ok(Data { users?, posts?, comments? })
}
```

### Racing Futures

Get the first result:

```home
fn fetch_with_timeout(): async Result<Data> {
  let result = await select! {
    data = fetch_data() => Ok(data),
    _ = sleep(Duration.seconds(5)) => Err(Error.Timeout)
  }
  result
}
```

## Error Handling

### Async with Result

```home
fn load_config(): async Result<Config, Error> {
  let content = await fs.read_file("config.json")?
  let config = json.parse(content)?
  return Ok(config)
}

fn main(): async {
  match await load_config() {
    Ok(config) => print("Loaded: {config.name}"),
    Err(e) => print("Error: {e}")
  }
}
```

### Try-Catch Style

```home
fn process_data(): async Result<Output, Error> {
  let data = await fetch_data()?
  let validated = validate(data)?
  let result = await transform(validated)?
  return Ok(result)
}
```

## Channels

Communicate between async tasks:

### Basic Channels

```home
use std::sync::channel

fn main(): async {
  let (tx, rx) = channel<int>()

  spawn(async || {
    for (i in 0..10) {
      await tx.send(i)
    }
  })

  while (let Some(value) = await rx.recv()) {
    print("Received: {value}")
  }
}
```

### Buffered Channels

```home
let (tx, rx) = channel<int>.bounded(100)  // Buffer size 100

// Producer can send up to 100 without blocking
for (i in 0..100) {
  await tx.send(i)
}
```

### Multiple Producers

```home
let (tx, rx) = channel<int>()

for (i in 0..4) {
  let tx = tx.clone()
  spawn(async move || {
    await tx.send(i * 10)
  })
}

drop(tx)  // Close original sender

while (let Some(value) = await rx.recv()) {
  print("Got: {value}")
}
```

## Spawning Tasks

### Basic Spawn

```home
fn main(): async {
  let handle = spawn(async || {
    await sleep(Duration.seconds(1))
    print("Task completed")
    42
  })

  // Do other work...

  let result = await handle
  print("Result: {result}")
}
```

### Fire and Forget

```home
spawn(async || {
  await log_analytics(event)
})

// Don't wait for the result
```

### Task Groups

```home
fn process_items(items: []Item): async []Result {
  let mut handles = []

  for (item in items) {
    let handle = spawn(async move || {
      await process_item(item)
    })
    handles.push(handle)
  }

  // Wait for all tasks
  let results = []
  for (handle in handles) {
    results.push(await handle)
  }

  results
}
```

## Timeouts and Cancellation

### Timeouts

```home
fn fetch_with_timeout(): async Result<Data, Error> {
  let result = await timeout(
    Duration.seconds(5),
    fetch_data()
  )

  match result {
    Ok(data) => Ok(data),
    Err(TimeoutError) => Err(Error.new("Request timed out"))
  }
}
```

### Cancellation

```home
fn main(): async {
  let (tx, rx) = channel<()>()

  let handle = spawn(async || {
    loop {
      select! {
        _ = rx.recv() => {
          print("Cancelled")
          break
        },
        _ = do_work() => {
          print("Working...")
        }
      }
    }
  })

  await sleep(Duration.seconds(5))
  await tx.send(())  // Cancel the task
  await handle
}
```

## Streams

Async iterators for data sequences:

```home
fn numbers(): async Stream<int> {
  for (i in 0..10) {
    yield i
    await sleep(Duration.millis(100))
  }
}

fn main(): async {
  await for (n in numbers()) {
    print("Got: {n}")
  }
}
```

### Stream Operators

```home
let evens = numbers()
  .filter(|n| n % 2 == 0)
  .map(|n| n * 2)

await for (n in evens) {
  print(n)  // 0, 4, 8, 12, 16
}
```

## HTTP Examples

### HTTP Client

```home
import http { get, post, Response }

fn fetch_user(id: int): async Result<User, Error> {
  let response = await http.get("/api/users/{id}")

  if (response.status != 200) {
    return Err(Error.new("HTTP {response.status}"))
  }

  return response.json()
}

fn create_user(user: User): async Result<User, Error> {
  let response = await http.post("/api/users")
    .json(user)
    .send()

  return response.json()
}
```

### HTTP Server

```home
import http { Server, Response }

fn main(): async {
  let server = Server.bind(":3000")

  server.get("/", async |req| {
    Response.text("Hello from Home!")
  })

  server.get("/users/:id", async |req| {
    let id = req.param("id").parse::<int>()?
    let user = await database.find_user(id)

    match user {
      Some(u) => Response.json(u),
      None => Response.status(404).text("Not found")
    }
  })

  server.post("/users", async |req| {
    let user: User = await req.json()?
    let created = await database.create_user(user)
    Response.status(201).json(created)
  })

  await server.listen()
}
```

## Best Practices

### 1. Prefer Parallel When Possible

```home
// Instead of sequential:
let a = await fetch_a()
let b = await fetch_b()

// Use parallel when independent:
let (a, b) = await join!(fetch_a(), fetch_b())
```

### 2. Handle Errors Properly

```home
fn safe_fetch(): async Result<Data, Error> {
  let result = await fetch_data()
    .timeout(Duration.seconds(10))
    .retry(3)

  result.map_err(|e| Error.new("Fetch failed: {e}"))
}
```

### 3. Avoid Blocking in Async

```home
// Bad: blocks the executor
fn bad(): async {
  std::thread::sleep(Duration.seconds(1))  // Blocks!
}

// Good: async-aware sleep
fn good(): async {
  await sleep(Duration.seconds(1))
}
```

### 4. Use Structured Concurrency

```home
fn process(): async Result<(), Error> {
  // All spawned tasks are tied to this scope
  async_scope(|scope| {
    scope.spawn(async || task1())
    scope.spawn(async || task2())
    scope.spawn(async || task3())
  })
  // All tasks complete before continuing
}
```

## Next Steps

- [Error Handling](/guide/error-handling) - Async error patterns
- [Standard Library](/reference/stdlib) - Async utilities
- [HomeOS Integration](https://github.com/home-lang/homeos) - Async I/O for HomeOS
