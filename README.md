<p align="center">
  <img src="https://github.com/openpeeps/bowdy/blob/main/.github/bowdy.png" alt="bowdy" width="170px"><br>
  bowdy &bullet; A fast CSS Preprocessor<br>
  Typed &bullet; VM & JIT Compiler &bullet; Written in Nim language 
</p>

<p align="center">
  <code>nimble install bowdy</code> / <code>clue install bowdy --build</code>
</p>

<p align="center">
  <a href="https://openpeeps.github.io/bowdy/theindex.html">API Reference</a> |
  <a href="https://bowdy.openpeeps.dev/">Documentation</a> | 
  <a href="https://github.com/openpeeps/bowdy/releases/latest">Download binaries</a><br>
  <img src="https://github.com/openpeeps/bowdy/workflows/test/badge.svg" alt="Github Actions"> <img src="https://github.com/openpeeps/bowdy/workflows/docs/badge.svg" alt="Github Actions">
</p>

## Overview

bowdy transpiles BASS files to standard CSS. It is written in Nim and designed for fast compilation, a typed system that catches errors early, and syntax that stays close to CSS while adding variables, nesting, mixins, control flow, and modules.

BASS files use the `.bass` extension and compile to `.css`.

## Features

- Fast stack-based VM & JIT Compiler
- Typed system for CSS values (`color`, `length`, `number`, etc.) with compile-time checks
- Familiar CSS syntax with indentation or brace blocks
- Variables (`var`, `const`) with optional type annotations and export (`*`)
- Nesting with parent selector `&`, combinators, and comma-separated selectors
- Reusable mixins with typed parameters and named arguments
- Control flow (`if` / `elif` / `else`, `for`, `while`, `case` / `of`) and functions (`fn` / `func`)
- Module imports (`import "./vars.bass"`) and package imports (`pkg/`)
- Modern CSS passthrough: custom properties, `var()`, `calc()`, `color-mix()`, gradients, and at-rules
- Source maps, bundling, and pretty-printed output

## Quick Start

### Installation

Requires Nim >= 2.0.0 (https://nim-lang.org/install.html).

```sh
nimble install bowdy
```

Or use [clue](https://github.com/openpeeps/clue), an alternative package manager for Nim development:
```sh
clue install bowdy --build
```

### Compile

```sh
bowdy c style.bass -o style.css        # compile to CSS (minified by default)
bowdy c style.bass --pretty -o style.css  # pretty-printed output
bowdy c style.bass --watch             # recompile on change
bowdy -h                               # all options
```

Source maps are supported with `--sourceMap`.

By default `bowdy c` is lenient: only VM types apply (variables, function
signatures, stdlib constructors), so a mistyped `width: $colorVar` still
compiles. Pass `--strict` to enable the static CSS type system: property
values are checked against their CSS syntax, invalid colors are hard
errors, and undeclared `var(--x)` names warn. Output is identical either
way; only diagnostics change.

## Syntax Showcase

All examples are minified by default. Add `--pretty` for formatted output.

### 1. Variables

```bass
var $primary = #0d6efd
var $radius = 4px

.card
  color: $primary
  border-radius: $radius
```
```css
.card{color:#0d6efd;border-radius:4px}
```
Variables use `var` / `const`, support interpolation (`$primary`), and are checked against CSS property types — the compiler rejects mismatches such as `width: red`.
CSS custom properties take part in the same system: `var(--x)` parses as a real call returning a typed `cssvar` value, so custom-property names stay atomic (`var(--color-gray-100)` is never re-split) and use sites check structurally. Every `--x` declaration (entry file and imports, order-independent) registers its inferred type, so under `--strict` `color: var(--fs-medium)` is a hard error when `--fs-medium` holds a size. Undeclared names only warn (they may come from plain-CSS imports or JS), `var(--x, fallback)` validates the fallback too, and `env()` is left alone. The CLI collects warnings during a compile and prints them with `displayWarning` once the CSS is out.

### 2. Nesting

```bass
.card
  color: gray
  &:hover
    color: black
  .title
    font-weight: bold
```
```css
.card{color:gray}.card:hover{color:black}.card .title{font-weight:bold}
```
Supports `&` for pseudo-classes, combinators (`& > .item`, `& + .item`), and comma-separated parents. Brace syntax works as well: `.card { &:hover { color: black } }`.

### 3. Mixins

```bass
mixin btn(color: color) {
  color: $color
  border-radius: 4px
}

.a
  @btn(red)
```
```css
.a{color:red;border-radius:4px}
```
Mixins accept typed parameters, support named arguments (`@box($h = 5px, $w = 10px)`), and can contain nested selectors.

### 4. Control Flow and Code Generation

```bass
for $i in range(1, 3):
  .p-${$i}
    z-index: $i
```
```css
.p-1{z-index:1}.p-2{z-index:2}.p-3{z-index:3}
```
Other constructs:

```bass
var debug = true
.a
  if $debug:
    outline: 1px
  else:
    outline: none
```

`for` also iterates over arrays of objects (`for $s in [{k:0,v:0}, {k:1,v:0.25rem}]`), `while`, and `case` / `of` are available.

### 5. Imports

```bass
// _vars.bass
var $accent* = #0d6efd
var $radius* = 4px

// main.bass
import "./_vars.bass"
.a
  color: $accent
  border-radius: $radius
```
```css
.a{color:#0d6efd;border-radius:4px}
```
Export with `*`, import relative files or packages.

### 6. Functions

```bass
fn dbl($n: int): int
  return $n * 2

var $p = dbl(21)
.a { z-index: $p }
```
```css
.a{z-index:42}
```
`func` is an alias for `fn`. Functions support overloading and forward declarations.

### 7. Embed bowdy in your Nim app

`import bowdy` gives two high-level calls that never quit the process.
Both return a `BroCompileResult` (`ok`, `css`, `warnings`, `error`):

```nim
import bowdy

let r = compileStylesheet("var $primary = #0d6efd\n.card\n  color: $primary")
if r.ok:
  echo r.css
  for w in r.warnings: echo w
else:
  echo "build failed: " & r.error

let f = compileStylesheetFile("styles/main.bass", pretty = true)
```

`compileStylesheet` compiles a source string (relative imports resolve
against the working directory); `compileStylesheetFile` compiles a file
on disk and resolves sibling imports next to it. Both take an optional
`strict = false` parameter mirroring `bowdy c --strict`. Parse, type, and
codegen failures come back as `ok == false` with `error` set, so a host
app stays in control.

## Benchmarks

`benchmarks/bench.sh` times four CLI commands head-to-head with hyperfine:
`sassc`, `bowdy c`, `bowdy c --strict`, and dart-sass when the vendored
`benchmarks/dart-sass/sass` binary (gitignored) is present:

```sh
benchmarks/bench.sh
benchmarks/bench.sh --warmup=2 --runs=5
benchmarks/bench.sh --big-count=500   # smaller Suite C
```

Suites (reports land in `bin/bench-a.md`, `bin/bench-b.md`, `bin/bench-c.md`):

- A (throughput): the same `bin/bootstrap.css` (280KB) through every
  compiler, since plain CSS is valid input for all of them.
- B (features): the equivalent pair `benchmarks/vs_sassc/features.scss` /
  `features.bass` (variables, nesting, parent refs, mixins with args,
  loops, conditionals, color functions, media queries).
- C (scale): a generated pair, `big.scss` / `big.bass` (~300KB at the
  default 2000 rules), produced by `benchmarks/vs_sassc/gen_big.py`.

Re-run on your own machine before quoting numbers: absolute times depend
on hardware and build flags (release).

Known fixture constraints: `$vars` inside opaque raw CSS calls
(`linear-gradient(to right, $c, ...)`) stay verbatim, runtime `${$var}px`
interpolation needs a loop or literal base, and construct ordering in
`features.bass` is load-bearing in spots. `#` is not a comment in BASS (it
starts an ID selector); the `.bass` fixture uses `//` comments.
Typed `var()` approximations: the registry is file-global (selector and
media scoping ignored, last declaration wins), shorthand syntaxes stay
narrow (`border: var(--w)` with a length errors, same as `border: $w`
today), and `var()` text smuggled through `$var` strings (rather than a
real `var()` call) is unchecked. Uppercase `VAR()` stays opaque and
unvalidated.
Static color calls keep their source spelling: fully-static `rgb()` /
`rgba()` / `hsl()`-family calls render verbatim (`rgb(13 110 253)` stays
space-separated, `rgba(0,0,0,.3)` keeps `,` and `.3`), while dynamic
forms (any `$var` / `var()` / nested call) evaluate to typed colors and
render canonically. Static calls nested in `var()` fallbacks stringify
compactly (`translate3d(0.25em,0,0)`).

## Documentation

- [API Reference](https://openpeeps.github.io/bowdy/theindex.html)
- [Official Documentation](https://bowdy.openpeeps.dev/)

## Contributing

- Report a bug: [Create an issue](https://github.com/openpeeps/bowdy/issues)
- Contribute code: [Fork the repository](https://github.com/openpeeps/bowdy/fork)
- Questions or feedback: open an issue or discussion.

## License

bowdy is released under the `LGPL-3.0-or-later` license. Made by Humans from OpenPeeps.<br>
Copyright &copy; 2026 OpenPeeps & Contributors — All rights reserved.
