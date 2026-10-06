# A super fast stylesheet language for cool kids!
#
# (c) 2026 George Lemon | LGPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/tim
import ./bowdy/engine/vancodegen

when isMainModule:
  # Building bowdy as a CLI application
  import pkg/kapsis
  import pkg/kapsis/[runtime, cli]
  import ./bowdy/app/build

  initKapsis do:
    defaultCommand: "c"
    commands:
      c path(bass), ?filename("-o"), ?bool("-w"), ?bool("--sourceMap"),
        ?bool("--pretty"), ?bool("--strict"), ?bool("--warnings"):
          ## Compile BASS to CSS with optional source map
      ast path(bass), ?filename("-o"):
        ## Generate binary AST from BASS/CSS
else:
  # High-level API for embedding bowdy in your Nim app:
  #
  #   import bowdy
  #   let r = compileBroString(".a\n  color: red")
  #   if r.ok: echo r.css
  #   else: echo "build failed: " & r.error
  import std/[options, os, tables]
  import pkg/openparser/json
  import pkg/vancode/interpreter/[ast, codegen, chunk, sym, vm, value, resolver]
  import ./bowdy/engine/parser
  import ./bowdy/engine/stdlib/[libsystem, libarrays, libcolors, libcss]

  type BroCompileResult* = object
    ## Outcome of a library compile: `css` on success, `error` otherwise.
    ## Non-fatal diagnostics (unknown `var(--x)`, unknown mixins) land in
    ## `warnings` without failing the build.
    ok*: bool
    css*: string
    warnings*: seq[string]
    error*: string

  proc loadBroStdlib(script: Script, module: Module) =
    ## Mirror the production CLI: system + colors + arrays + cssTypes.
    let systemModule = libsystem.loadLibrary(script, newJObject(), newJObject())
    module.load(systemModule)
    module.load(libcolors.initColors(script, systemModule))
    module.load(libarrays.initArrays(script, systemModule))
    module.load(libcss.initCssTypes(script, systemModule))

  proc runBroProgram(program: Ast, chunkName: string,
      parserCallback: ParserCallback, pretty: bool,
      strict: bool = false): BroCompileResult =
    ## Shared backend: register custom props, generate bytecode, interpret.
    ## Never quits; all failures surface as `ok == false` with `error` set.
    ## `strict` enables the static CSS type system (off = VM types only).
    let prevHandler = codegen.warnHandler
    let prevStrict = codegen.strictCss
    var collected: seq[string] = @[]
    codegen.warnHandler = proc(msg: string) {.gcsafe.} =
      {.cast(gcsafe).}: # embedder runs single-threaded: safe to collect locally
        collected.add(msg)
    codegen.strictCss = strict
    try:
      codegen.resetCustomProps()
      if strict:
        codegen.collectCustomProps(program)
      let mainChunk = newChunk(chunkName)
      var script = newScript(mainChunk)
      var module = newModule(chunkName.extractFilename, some(chunkName))
      loadBroStdlib(script, module)
      script.stdpos = script.procs.high
      var gen = initCodeGen(script, module, mainChunk,
        manager = nil, parserCallback = parserCallback)
      gen.genScript(program, none(string))
      let virtualMachine = newVirtualMachine(VMPreferences())
      if pretty:
        virtualMachine.globals["__bro_pretty"] = initValue(true)
      result = BroCompileResult(ok: true,
        css: virtualMachine.interpret(script, mainChunk).stringVal[],
        warnings: collected)
    except BroParserError as e:
      result = BroCompileResult(ok: false, error: e.msg, warnings: collected)
    except CodeGenError as e:
      result = BroCompileResult(ok: false, error: e.msg, warnings: collected)
    except CatchableError as e:
      result = BroCompileResult(ok: false, error: "internal error: " & e.msg,
        warnings: collected)
    finally:
      codegen.warnHandler = prevHandler
      codegen.strictCss = prevStrict

  proc compileStylesheet*(code: string, sourcePath = "input.bass",
      pretty = false, strict = false): BroCompileResult =
    ## Compile BASS `code` to CSS. Relative `import` statements resolve
    ## against the current working directory; use `compileStylesheetFile`
    ## when the entry lives on disk so sibling imports resolve next to it.
    ## `strict` enables the static CSS type system (off = VM types only).
    var program: Ast
    try:
      parser.parseScript(program, code, sourcePath)
    except BroParserError as e:
      return BroCompileResult(ok: false, error: e.msg)
    runBroProgram(program, sourcePath, nil, pretty, strict)

  proc compileStylesheetFile*(path: string, pretty = false,
      strict = false): BroCompileResult =
    ## Compile the `.bass` file at `path` to CSS, resolving sibling imports.
    proc cb(astProgram: var Ast, p: string, resolver: FileResolver) =
      parser.parseScriptFile(astProgram, p)
      if codegen.strictCss:
        codegen.collectCustomProps(astProgram)
    var program: Ast
    try:
      parser.parseScriptFile(program, path)
    except BroParserError as e:
      return BroCompileResult(ok: false, error: e.msg)
    except IOError, OSError:
      return BroCompileResult(ok: false, error: getCurrentExceptionMsg())
    runBroProgram(program, path, cb, pretty, strict)
