import bowdy
import unittest
import std/[os, strutils]

suite "embed bowdy as a library":
  test "compile string to css":
    let r = compileStylesheet(".a\n  color: red")
    check r.ok
    check r.css == ".a{color:#ff0000}"
    check r.warnings.len == 0
    check r.error.len == 0

  test "type mismatch returns error, never quits":
    let r = compileStylesheet(":root\n  --s: 1rem\n.a\n  color: var(--s)",
      strict = true)
    check not r.ok
    check "expected color, got length" in r.error
    check r.css.len == 0

  test "lenient default ignores type mismatch":
    let r = compileStylesheet(":root\n  --s: 1rem\n.a\n  color: var(--s)")
    check r.ok
    check r.css == ":root{--s:1rem}.a{color:var(--s)}"
    check r.warnings.len == 0

  test "parser error returns error":
    let r = compileStylesheet(".a { color: red;")
    check not r.ok
    check r.error.len > 0

  test "unknown var warns without failing":
    let r = compileStylesheet(".a\n  color: var(--nope)", strict = true)
    check r.ok
    check r.css == ".a{color:var(--nope)}"
    check r.warnings.len == 1
    check "var(--nope) is not declared" in r.warnings[0]

  test "lenient default stays silent on unknown var":
    let r = compileStylesheet(".a\n  color: var(--nope)")
    check r.ok
    check r.css == ".a{color:var(--nope)}"
    check r.warnings.len == 0

  test "pretty output":
    let r = compileStylesheet(".a { color: red; }", pretty = true)
    check r.ok
    check r.css == ".a{\n  color:#ff0000\n}\n"

  test "compile file resolves sibling imports":
    let dir = currentSourcePath().parentDir / "stylesheets"
    let r = compileStylesheetFile(dir / "import_main.bass")
    check r.ok
    check r.css == ".base{color:#808080}.a{color:#0d6efd;border-radius:4px}"

  test "missing file returns error":
    let r = compileStylesheetFile("does-not-exist.bass")
    check not r.ok
    check r.error.len > 0
