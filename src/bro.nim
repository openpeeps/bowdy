# A super fast stylesheet language for cool kids!
#
# (c) 2026 George Lemon | LGPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/tim
import ./bro/engine/vancodegen

when isMainModule:
  # Building Bro as a CLI application
  import pkg/kapsis
  import pkg/kapsis/[runtime, cli]
  import ./bro/app/build

  initKapsis do:
    defaultCommand: "c"
    commands:
      c path(bass), ?filename("-o"), ?bool("-w"), ?bool("--sourceMap"),
        ?bool("--pretty"), ?bool("--strict"), ?bool("--warnings"):
          ## Compile BASS to CSS with optional source map
      ast path(bass), ?filename("-o"):
        ## Generate binary AST from BASS/CSS
else:
  # High-level API for embedding Bro in your Nim app:
  #
  #   import bro
  #   let r = compileBroString(".a\n  color: red")
  #   if r.ok: echo r.css
  #   else: echo "build failed: " & r.error
  import std/[options, os, tables]
  import pkg/openparser/json
  import pkg/vancode/interpreter/[ast, codegen, chunk, sym, vm, value, resolver]
  import ./bro/engine/parser
  import ./bro/engine/stdlib/[libsystem, libarrays, libcolors, libcss]
  import ./bro/engine/jitbridge
  # Same ordering rule as app/build: after the engine imports so voodoo
  # registrations precede the JIT compilers' compilation.
  from pkg/vancode/interpreter/jit/jit import installJit
  from pkg/vancode/interpreter/jit/compiler_bridge import resetJitState

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
      strict: bool = false, jit: bool = false): BroCompileResult =
    ## Shared backend: register custom props, generate bytecode, interpret.
    ## Never quits; all failures surface as `ok == false` with `error` set.
    ## `strict` enables the static CSS type system (off = VM/JIT types only).
    ## `jit` opts into native main execution (default off: the interpreter
    ## is faster for one-shot compiles; JIT pays off on repeated runs).
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
      let virtualMachine = newVirtualMachine(VMPreferences(
        enableHotCodeDetection: jit,
        hotProcThreshold: 10,
        hotChunkThreshold: 1
      ))
      if jit:
        # Register the main script (and its imports) for procId resolution:
        # the JIT resolves CallD targets and admits call arities through
        # `vm.importedModules`; without this every main-chunk CallD misses
        # (nArgs=0, silent dummy result, native stack desync).
        # Threshold 1: an explicit opt-in means native on this run.
        resetJitState()
        virtualMachine.prewarmScriptOps(script)
        virtualMachine.installJit()
        initBroJit(virtualMachine)
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
      pretty = false, strict = false, jit = false): BroCompileResult =
    ## Compile BASS `code` to CSS. Relative `import` statements resolve
    ## against the current working directory; use `compileStylesheetFile`
    ## when the entry lives on disk so sibling imports resolve next to it.
    ## `strict` enables the static CSS type system (off = VM/JIT types only).
    var program: Ast
    try:
      parser.parseScript(program, code, sourcePath)
    except BroParserError as e:
      return BroCompileResult(ok: false, error: e.msg)
    runBroProgram(program, sourcePath, nil, pretty, strict, jit)

  proc compileStylesheetFile*(path: string, pretty = false,
      strict = false, jit = false): BroCompileResult =
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
    runBroProgram(program, path, cb, pretty, strict, jit)
