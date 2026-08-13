# Game Development

A game at 60 frames per second has 16 milliseconds to do everything. The
problem with a garbage collector in that loop is not its average cost, it is
that the cost arrives when the collector decides rather than when you do. One
20ms pause is a visible stutter no matter how good the average was.

Home has no collector. Memory is settled at compile time, so a frame costs
what the frame does and nothing else.

## Why the language fits

**Deterministic memory.** Ownership decides when things are freed. Allocation
happens where you write it, and you can pre-allocate a pool at load time and
never touch the allocator during play. See [the memory model](/advanced/memory).

**Data-oriented layout.** Structs have predictable layout, so a component array
is a real contiguous array and iterating it is a linear scan rather than a
pointer chase.

**Zero-cost generics.** Generics are monomorphized, so a `Pool<Particle>` is
the same machine code you would have written by hand for particles. See
[generics](/features/generics).

**Comptime specialisation.** Shader permutations, component IDs and dispatch
tables can be resolved during compilation. See [comptime](/advanced/comptime).

## A frame, in outline

```home
struct World {
  positions: [Vec2],
  velocities: [Vec2],
  alive: [bool],
}

fn integrate(mut world: World, dt: float) {
  for (i in 0..world.positions.len()) {
    if (!world.alive[i]) {
      continue
    }

    world.positions[i].x += world.velocities[i].x * dt
    world.positions[i].y += world.velocities[i].y * dt
  }
}
```

Three parallel arrays, one linear pass, no allocation, no indirection. The
same loop written against an array of heap-allocated entities would spend most
of its time waiting on cache misses.

## State machines that cannot drop a case

Game state is where missing branches hide. Exhaustive
[pattern matching](/features/pattern-matching) turns that into a compile
error:

```home
enum Phase {
  Loading(float),
  Playing,
  Paused,
  GameOver(int),
}

fn update(phase: Phase, dt: float) -> Phase {
  match phase {
    Phase.Loading(progress) => {
      let next = progress + dt
      if (next >= 1.0) { Phase.Playing } else { Phase.Loading(next) }
    },
    Phase.Playing => step_simulation(dt),
    Phase.Paused => Phase.Paused,
    Phase.GameOver(score) => Phase.GameOver(score),
  }
}
```

Add a `Phase.Cutscene` variant later and every match on `Phase` fails to
compile until it is handled. That is the property you want when the state
machine grows for two years.

## Talking to engines and drivers

Graphics, audio and input APIs are C. Home calls them directly through
[FFI](/features/ffi), with struct layout and callback signatures expressed in
the language rather than in a generated binding layer.

## Status

Home is not a game engine and does not ship one. What it offers is a language
with the memory behaviour and the code generation that engine and tools work
needs. The front end and interpreter are usable today; native code generation
handles single-entrypoint builds and is still maturing. Read the
[capability matrix](/CAPABILITY_MATRIX) before planning around a specific
feature.

## Related

- [Memory model](/advanced/memory)
- [Performance](/advanced/performance)
- [Pattern matching](/features/pattern-matching)
- [Systems programming](/use-cases/systems)
