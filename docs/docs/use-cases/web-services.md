# Web Services

A service written in Home is a single native binary. There is no interpreter to
install in the image, no collector deciding when to pause a request, and no
start-up cost beyond loading the executable. HTTP, JSON and database access
are in the standard library.

## A service, end to end

```home
import std::http::{Server, Response}

struct User {
  id: i64,
  name: string,
  email: string,
}

fn main(): async {
  let server = Server.bind(":3000")

  server.get("/health", |req| {
    Response.text("ok")
  })

  server.get("/users/:id", async |req| {
    let id = req.param("id").parse::<int>()?

    match await database.find_user(id) {
      Some(user) => Response.json(user),
      None => Response.status(404).text("Not found"),
    }
  })

  server.post("/users", async |req| {
    let user: User = await req.json()?
    let created = await database.create_user(user)
    Response.status(201).json(created)
  })

  print("Server running on http://localhost:3000")
  await server.listen()
}
```

Two things worth noticing. The 404 is a branch of a `match`, not a null check
someone might forget, and `?` on the parse propagates the error into the
response rather than throwing past the handler.

## Requests that can fail

Every fallible step in a handler returns a `Result`, so the error path is
written once and reads in order:

```home
fn load_profile(id: int): Result<Profile, ApiError> {
  let user = database.find_user(id)?
  let prefs = database.find_preferences(user.id)?
  let avatar = storage.signed_url(user.avatar_key)?

  Ok(Profile { user, prefs, avatar })
}
```

No exception unwinds through the connection handler, and no failure is
silently swallowed. See [error handling](/docs/advanced/error-handling).

## Making outbound calls

```home
import std::http

let response = await http.get("https://api.example.com/users")?
let users: []User = response.json()?
```

Timeouts, retries and POST bodies are covered in the
[standard library reference](/docs/reference/stdlib).

## Concurrency

Handlers are `async`, and awaiting one request does not block the others. See
[async](/docs/advanced/async) for tasks, channels and the structure of the
scheduler.

## The TypeScript side

If your service is TypeScript today, the same binary type-checks it, so you can
adopt Home for one hot endpoint without moving the rest:

```bash
home tsc --noEmit
home build src/hot-path.home -o hot-path
```

See [TypeScript migration](/docs/use-cases/typescript-migration) for the staged
version of that, and [the TypeScript compiler](/docs/features/typescript) for what
`home tsc` covers.

## Status

`std::http` and `std::json` are documented and usable through the interpreter.
The Bun-compatible runtime, which is what makes the JavaScript side of a mixed
service run on Home's own JavaScriptCore realm, is maturing: 24 `node:*`
modules are callable so far and the default `home run` still delegates to
Pantry's `bun`. See [Bun parity](/docs/PARITY-BUN) and
[Node parity](/docs/PARITY-NODE) for the module-by-module picture.

## Related

- [Standard library](/docs/reference/stdlib)
- [Async](/docs/advanced/async)
- [TypeScript migration](/docs/use-cases/typescript-migration)
- [CLI tools](/docs/use-cases/cli-tools)
