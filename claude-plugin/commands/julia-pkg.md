---
name: julia-pkg
description: Manage Julia packages (add, remove, status, update, test, develop)
argument-hint: "<action> [packages]"
allowed-tools:
  - mcp__plugin_julia_julia-repl__pkg
---

# Julia Package Management Command

Manage Julia packages in the current environment.

## Arguments

- `action` - One of: add, rm, status, update, instantiate, resolve, test, develop, free
- `packages` - Package names or paths (required for add/rm/develop/free, optional for update/test)

## Instructions

Parse the user's arguments to determine the action and packages:

| User Input | Action | Packages |
|------------|--------|----------|
| `add JSON` | add | JSON |
| `add JSON DataFrames CSV` | add | JSON, DataFrames, CSV |
| `rm OldPackage` | rm | OldPackage |
| `status` | status | (none) |
| `update` | update | (none - updates all) |
| `update JSON` | update | JSON |
| `instantiate` | instantiate | (none) |
| `resolve` | resolve | (none) |
| `test` | test | (none - tests current project) |
| `test MyPackage` | test | MyPackage |
| `develop ./MyLocalPkg` | develop | ./MyLocalPkg |
| `free MyPackage` | free | MyPackage |

Call `pkg` with the appropriate action and packages parameters.

## Examples

```
/julia-pkg add Plots
/julia-pkg status
/julia-pkg update
/julia-pkg instantiate
/julia-pkg test
/julia-pkg develop ./path/to/MyPackage
/julia-pkg free MyPackage
```

## Notes

- After adding packages, remind the user to load them with `using PackageName`
- The `instantiate` action installs dependencies from Project.toml/Manifest.toml
- The `test` action runs Pkg.test() - can be slow for large test suites
- The `develop` action puts a package in development mode (uses local code)
- The `free` action exits development mode (returns to registry version)
