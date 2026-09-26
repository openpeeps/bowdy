<p align="center">
  <img src="https://github.com/openpeeps/bowdy/blob/main/.github/logo.png" alt="bowdy" width="170px"><br>
  bowdy &bullet; A fast CSS Preprocessor<br>
  Typed &bullet; VM & JIT Compiler &bullet; Written in Nim language 
</p>

<p align="center">
  <code>nimble install bowdy</code> / <code>clue install bowdy --build</code> / <code>npm install bowdy</code>
</p>

bowdy transpiles `BASS` files to standard `CSS`. It is written in Nim and designed for fast compilation, a typed system that catches errors early, and syntax that stays close to CSS while adding variables, nesting, mixins, control flow, and modules.

BASS files use the `.bass` extension and compile to `.css`.

## Features

- Fast stack-based VM & JIT Compiler
- Typed system for CSS values (`color`, `length`, `number`, etc.) with compile-time checks
- Familiar CSS syntax with indentation or brace blocks
- Variables (`var`, `const`) with optional type annotations and export (`*`)
- Nesting with parent selector `&`, combinators, and comma-separated selectors
- Reusable mixins with typed parameters and named arguments
- Control flow (`if` / `elif` / `else`, `for`, `while`, `case` / `of`) and functions (`fn` / `func`) =
- Module imports (`import "./vars.bass"`) and package imports (`pkg/`)
- Modern CSS passthrough: custom properties, `var()`, `calc()`, `color-mix()`, gradients, and at-rules
- Source maps, bundling, and pretty-printed output


## Syntax Showcase

All examples are minified by default. Add `--pretty` for formatted output.

### 1. Variables

```bass
var primary = #0d6efd
var radius = 4px

.card
  color: $primary
  border-radius: $radius
```
```css
.card{color:#0d6efd;border-radius:4px}
```

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

### 4. Control Flow and Code Generation

```bass
for i in range(1, 3):
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

`for` also iterates over arrays of objects (`for s in [{k:0,v:0}, {k:1,v:0.25rem}]`), `while`, and `case` / `of` are available.

### 5. Imports

```bass
// _vars.bass
var accent* = #0d6efd
var radius* = 4px

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
fn dbl(n: int): int =
  return $n * 2

var p = dbl(21)
.a { z-index: $p }
```
```css
.a{z-index:42}
```
`func` is an alias for `fn`. Functions support overloading and forward declarations.

### 7. Embed bowdy in your Nim app

`import bowdy` gives two high-level calls that never quit the process.
Both return a `bowdyCompileResult` (`ok`, `css`, `warnings`, `error`):

```nim
import bowdy

let r = compileStylesheet("var primary = #0d6efd\n.card\n  color: $primary")
if r.ok:
  echo r.css
  for w in r.warnings: echo w
else:
  echo "build failed: " & r.error

let f = compileStylesheetFile("styles/main.bass", pretty = true)
```


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
