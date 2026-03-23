---
name: julia-language
description: This skill activates for Julia-specific programming questions about language features, type system, multiple dispatch, metaprogramming, performance optimization, common pitfalls, and idiomatic Julia patterns. Triggers when user asks about Julia types, dispatch, macros, broadcasting, parametric types, abstract types, type stability, or Julia-specific patterns like Holy traits, functor pattern, or generated functions.
version: 0.6.0
---

# Julia Language Expertise

Deep knowledge of Julia language features, idioms, and best practices for writing high-quality Julia code.

## Type System

### Abstract Types and Hierarchy
- Use abstract types to define interfaces and shared behavior
- Design type hierarchies for dispatch, not data inheritance
- Keep hierarchies shallow (2-3 levels)
- `abstract type Shape end` then `struct Circle <: Shape ... end`

### Parametric Types
- Use parametric types for generic containers and algorithms
- `struct Point{T<:Real} x::T; y::T end` — constrains T to Real subtypes
- Parametric types are invariant: `Vector{Int}` is NOT a subtype of `Vector{Real}`
- Use `where` clauses for method signatures: `f(x::Vector{T}) where {T<:Real}`

### Type Stability
- **Critical for performance**: a function is type-stable if the return type depends only on input types
- Use `@code_warntype` to check — red `Any` or `Union` types indicate instability
- Avoid containers with abstract element types in hot paths (`Vector{Any}` is slow)
- Use `isbitstype(T)` to check if a type can be stored inline (no heap allocation)
- Common pitfall: `x = condition ? 1 : 1.0` returns `Union{Int,Float64}`

### Type Unions and Small Unions
- `Union{Int,Float64}` is efficient (compiler generates specialized code for small unions)
- `Union{Nothing, T}` is idiomatic for optional values (equivalent to `Optional<T>`)
- Use `something(x, default)` to unwrap `Union{Nothing,T}`

## Multiple Dispatch

### Method Specialization
- Define methods that specialize on argument types, not single-dispatch OOP
- `area(s::Circle) = pi * s.r^2` and `area(s::Square) = s.side^2`
- Julia selects the most specific method at runtime based on ALL argument types
- Avoid method ambiguity — if `f(::A, ::B)` and `f(::C, ::D)` exist, ensure `f(::A∩C, ::B∩D)` is defined

### Trait Patterns (Holy Traits)
```julia
# Define trait types
struct HasLength end
struct NoLength end

# Trait function
HasLength(::Type{<:AbstractArray}) = HasLength()
HasLength(::Type) = NoLength()

# Dispatch on trait
length_or_nothing(x) = _length(HasLength(typeof(x)), x)
_length(::HasLength, x) = length(x)
_length(::NoLength, x) = nothing
```

### Functor Pattern
- Make types callable by defining `(obj::MyType)(args...)` methods
- Useful for function-like objects with state (e.g., neural network layers)

## Metaprogramming

### Macros
- Macros transform code at parse time (before compilation)
- Use `@macroexpand` to see what a macro generates
- Write macros only when functions won't work (code generation, DSLs)
- Macros receive `Expr` objects and return `Expr` objects

### Generated Functions
- `@generated function f(x::T)` generates specialized code per type
- The function body runs at compile time, returns an `Expr` for runtime
- Useful for type-dependent loop unrolling and optimizations

### Expressions
- `:(x + 1)` creates an `Expr` object
- `quote ... end` for multi-line expressions
- `eval(expr)` evaluates at global scope (avoid in performance-critical code)
- `$` for interpolation into expressions

## Performance Patterns

### Avoid Global State
- Global variables are type-unstable by default
- Use `const` for global constants
- Pass values as function arguments instead of accessing globals
- If you must use globals, type-annotate access: `x::Int`

### Column-Major Iteration
- Julia arrays are column-major (like Fortran, unlike C/Python)
- Iterate inner index first: `for j in 1:n, i in 1:m; A[i,j]; end`
- This gives sequential memory access and cache efficiency

### Broadcasting
- `f.(x)` applies `f` element-wise without allocating intermediate arrays
- Chain broadcasts with `@.`: `@. y = sin(x) + cos(x)` fuses into one loop
- Define `Base.broadcastable(x::MyType)` to make custom types broadcastable

### Pre-allocation
- Avoid growing arrays in loops; pre-allocate with `Vector{T}(undef, n)`
- Use `similar(A)` to create same-shaped uninitialized arrays
- Use `resize!`, `push!`, `append!` for dynamic arrays

### Views vs Copies
- `A[1:10, :]` creates a copy (allocates memory)
- `@view A[1:10, :]` or `view(A, 1:10, :)` creates a reference (no allocation)
- Use `@views` macro to make all slicing in a block use views

## Common Pitfalls

### String Handling
- `String` is immutable and UTF-8 encoded
- Indexing by byte position: `s[1]` may fail on multi-byte characters
- Use `eachindex(s)`, `nextind(s, i)`, or `collect(s)` for safe iteration
- `SubString` avoids copying; returned by `match`, `split`, etc.

### Closures and Performance
- Closures can capture variables by reference, causing type instability
- Use `let` blocks to capture by value: `let x=x; () -> x end`
- Barrier functions help: define an inner function that takes captured vars as args

### Container Types
- `Dict{Symbol, Any}` is slow for hot paths — use structs instead
- `Tuple` is immutable and type-stable; `NamedTuple` adds field names
- Prefer `Tuple` over `Vector` for small, fixed-size collections

## Standard Library Tips

### Comprehensions and Generators
- `[f(x) for x in xs if cond(x)]` — allocates array
- `(f(x) for x in xs if cond(x))` — lazy generator (no allocation)
- Use generators with `sum`, `maximum`, `any`, `all` for memory efficiency

### Useful Base Functions
- `zip(a, b)` — iterate pairs
- `enumerate(x)` — iterate with index
- `eachslice(A; dims=1)` — iterate matrix rows/columns
- `Iterators.flatten`, `Iterators.product` — combine iterators
- `something(a, b, c)` — first non-nothing value
- `coalesce(a, b, c)` — first non-missing value
