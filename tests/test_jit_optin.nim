import bowdy
import unittest

const sample = """:root
  --bg: #0d6efd
  --gap: 1rem
.a
  color: var(--bg)
  margin: var(--gap)
  display: flex
.b
  color: darken(#0d6efd, 10)
  width: 100px
"""

suite "jit opt-in parity":
  test "jit:true matches interpreter":
    let interp = compileStylesheet(sample)
    check interp.ok
    let native = compileStylesheet(sample, jit = true)
    check native.ok
    check native.css == interp.css

  test "jit:true twice in one process stays identical (table reset)":
    let a = compileStylesheet(sample, jit = true)
    let b = compileStylesheet(sample, jit = true)
    check a.ok and b.ok
    check a.css == b.css
