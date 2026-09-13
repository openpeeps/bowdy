# A super fast stylesheet language for cool kids!
#
# (c) 2026 George Lemon | LGPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/bro

import std/[os, monotimes, times, options, strutils, algorithm]

import pkg/watchout
import pkg/openparser/[json, bson]
import pkg/kapsis/[cli, runtime, interactive/prompts]
import pkg/vancode/interpreter/[ast, codegen, chunk, sym, vm, value, resolver, manager]

import ../engine/parser
import ../engine/sourcemap
import ../engine/stdlib/[libsystem, libarrays, libcolors, libcss]
# JIT import sits after the engine imports on purpose: vancodegen's voodoo
# registrations must run before vancode's JIT compilers are compiled, so any
# future `extendCaseStmt` JIT blocks in vancodegen apply to this build.
from pkg/vancode/interpreter/jit/jit import installJit
from pkg/vancode/interpreter/jit/compiler_bridge import resetJitState
import ../engine/jitbridge

var codegenWarnings: seq[string] = @[]
  ## Non-fatal codegen warnings collected during a compile, flushed with
  ## displayWarning once the command finishes (success or failure).

proc flushCodegenWarnings() =
  for w in codegenWarnings:
    displayWarning(w)
  codegenWarnings.setLen(0)

proc parserCallback(astProgram: var Ast, path: string, resolver: FileResolver) =
  parser.parseScriptFile(astProgram, path)
  if codegen.strictCss:
    codegen.collectCustomProps(astProgram)

#
# Compile command
#
proc writeSourceMap(vm: Vm, srcPath, code: string, outputFilePath: string) =
  ## Build and write a v3 source map for the compiled CSS alongside the CSS file.
  var info = initSourceInfo()
  info.addContent(srcPath, code)
  # The VM accumulated segments as `genCol \x03 line \x03 col \x03 file` records,
  # separated by \x02. Each record's file is the chunk it was emitted from,
  # so imported modules are attributed to their own source files.
  let segs = vm.globals.getOrDefault("__bro_sourcemap_segments").stringVal[]
  var seenFiles: seq[string]
  for record in segs.split('\x02'):
    if record.len == 0:
      continue
    let parts = record.split('\x03')
    if parts.len >= 4:
      let genCol = parseInt(parts[0])
      let line = parseInt(parts[1]) - 1 # source lines are 0-based in the map
      let col = parseInt(parts[2])
      let segFile = parts[3]
      info.addSegment(0, genCol, segFile, line, col)
      # Embed the raw source of every contributing file (imported modules too)
      if segFile notin seenFiles:
        seenFiles.add(segFile)
        try:
          info.addContent(segFile, readFile(segFile))
        except CatchableError:
          discard # unreadable file — sourcesContent stays empty for it

  let sm = info.toSourceMap(outputFilePath.extractFilename)
  let mapNode = newJObject()
  mapNode["version"] = newJInt(sm.version)
  mapNode["file"] = newJString(sm.file)
  let sources = newJArray()
  for s in sm.sources:
    sources.add(newJString(s))
  mapNode["sources"] = sources
  let contents = newJArray()
  for c in sm.sourcesContent:
    contents.add(newJString(c))
  mapNode["sourcesContent"] = contents
  let names = newJArray()
  mapNode["names"] = names
  mapNode["mappings"] = newJString(sm.mappings)

  let mapPath = outputFilePath.changeFileExt(".css.map")
  writeFile(mapPath, toJson(mapNode))

proc compileCode(filePath: string,
          manager: ModuleManager, globalData: JsonNode, localData: JsonNode,
          output: bool = false, outputPath: string = "",
          sourceMap: bool = false, pretty: bool = false,
          strict: bool = false, watch: bool = false) =
  # Compile the BASS code at `filePath` and optionally save the output to `
  var program: Ast # the AST representation of the script
  try:
    parser.parseScriptFile(program, filePath)
  except BroParserError as e:
    displayError(e.msg)
    quit(1)

  var mainChunk = newChunk(filePath)
  var script = newScript(mainChunk)
  var module = newModule(filePath.extractFilename, some(filePath))

  # load standard library modules
  let systemModule = libsystem.loadLibrary(script, globalData, localData)
  module.load(systemModule)

  # auto-import all std libs
  let colorsModule = libcolors.initColors(script, systemModule)
  module.load(colorsModule)

  let arraysModule = libarrays.initArrays(script, systemModule)
  module.load(arraysModule)

  let cssModule = libcss.initCssTypes(script, systemModule)
  module.load(cssModule)

  script.stdpos = script.procs.high

  # compile the code and handle any errors
  codegen.strictCss = strict
  try:
    codegen.resetCustomProps()
    codegenWarnings.setLen(0)
    if strict:
      codegen.collectCustomProps(program)
    var compiler = initCodeGen(script, module, mainChunk,
                                  manager = manager, parserCallback = parserCallback)
    compiler.genScript(program, none(string))
    
    # initialize a Voodoo VM and execute the script
    # Hot detection and JIT live only in watch mode: each save rebuilds a
    # fresh script, so procIds are per-save. resetJitState frees the
    # previous save's native buffers (keeping one spare) and clears
    # per-save caches, while the process-wide hot counts in vancode
    # survive, letting main go native after hotChunkThreshold saves.
    # One-shot runs stay interpreted for minimal latency.
    let virtualMachine = newVirtualMachine(VMPreferences(
      enableHotCodeDetection: watch,
      hotProcThreshold: 10,
      hotChunkThreshold: 2
    ))
    if watch:
      resetJitState()
      virtualMachine.prewarmScriptOps(script)
      virtualMachine.installJit()
      initBroJit(virtualMachine)
    if pretty:
      virtualMachine.globals["__bro_pretty"] = initValue(true)
    if not output:
      echo(virtualMachine.interpret(script, mainChunk))
    else:
      let cssOutput = virtualMachine.interpret(script, mainChunk).stringVal[]
      let outputFilePath = outputPath.changeFileExt(".css")
      if sourceMap:
        if pretty:
          displayInfo("--pretty output keeps minified-layout source map mappings")
        writeSourceMap(virtualMachine, filePath, readFile(filePath), outputFilePath)
        let mapName = outputFilePath.extractFilename.changeFileExt(".css.map")
        writeFile(outputFilePath, cssOutput & "\n/*# sourceMappingURL=" & mapName & " */")
      else:
        # if fileExists(outputFilePath):
        writeFile(outputFilePath, cssOutput)
    flushCodegenWarnings()
  except CodeGenError as e:
    flushCodegenWarnings()
    displayError(parser.errorContextFor(filePath, e.ln, e.col) & e.msg)
    quit(1)
  except CatchableError as e:
    # Safety net: catch any unhandled validation errors from the codegen
    flushCodegenWarnings()
    displayError("internal error: " & e.msg)
    quit(1)

var browserSyncWatcher: Watchout
proc cCommand*(v: Values) =
  ## Kapsis command for compiling BASS files to CSS
  var srcPath = $(v.get("bass").getPath)
  
  var hasOutput: bool
  var outputPath =
    if v.has("-o"):
      hasOutput = true
      v.get("-o").getFilename
    else: ""

  let enabledWatch = v.has("-w")
  let enabledSourceMap = v.has("--sourceMap")
  let enabledPretty = v.has("--pretty")
  let enabledStrict = v.has("--strict")
  let enabledWarnings =
    if v.has("--warnings"): v.get("--warnings").getBool()
    else: true

  if not srcPath.isAbsolute:
    srcPath = getCurrentDir() / srcPath
  
  if hasOutput and not outputPath.isAbsolute:
    outputPath = getCurrentDir() / outputPath

  if enabledSourceMap and not hasOutput:
    displayError("--sourceMap requires -o <output.css>")
    quit(1)

  # init module manager with persistent cache and pkg resolver
  let cacheRoot = getHomeDir() / ".bro" / "cache"
  let manager = newModuleManager(cacheRoot = some(cacheRoot))
  # pkg resolver for `pkg/` imports (Tim packages sharing ~/.tim)
  manager.pkgResolver = some(proc(pkgImport: string): Option[string] {.closure.} =
    if not pkgImport.startsWith("pkg/"):
      return none(string)
    let parts = pkgImport.split("/")
    if parts.len < 2:
      return none(string)
    let pkgName = parts[1]
    let subPath = if parts.len > 2: parts[2..^1].join("/") else: ""
    let pkgBase = getHomeDir() / ".tim" / "packages" / pkgName
    var version = "0.1.0"
    if dirExists(pkgBase):
      var versions: seq[string] = @[]
      for kind, path in walkDir(pkgBase):
        if kind == pcDir:
          versions.add(path.extractFilename)
      if versions.len > 0:
        versions.sort()
        version = versions[^1]
    let pkgSrc = pkgBase / version / "src"
    var candidates: seq[string] = @[]
    if subPath.len == 0:
      candidates.add(pkgSrc / "main.bass")
      candidates.add(pkgSrc / "index.bass")
      candidates.add(pkgSrc / pkgName & ".bass")
      candidates.add(pkgSrc / "main.timl")
    else:
      let base = pkgSrc / subPath
      candidates.add(base)
      if splitFile(subPath).ext.len == 0:
        candidates.add(base & ".bass")
        candidates.add(base & ".timl")
        candidates.add(base & ".css")
    for c in candidates:
      if fileExists(c):
        return some(c)
    return none(string)
  )

  let
    t = getMonotime()
    data =
      if v.has("--data"):
        v.get("--data").getJson
      else:
        newJObject()
    globalData =
      if data != nil:
        if data.hasKey"app":
          data["app"]
        else: newJObject()
      else: newJObject()
    localData =
      if data != nil:
        if data.hasKey"this":
          data["this"]
        else: newJObject()
      else: newJObject()

  # route non-fatal codegen warnings into the command-level collector,
  # or drop them entirely with --warnings:false
  if enabledWarnings:
    codegen.warnHandler = proc(msg: string) {.gcsafe.} =
      {.cast(gcsafe).}: # command runs single-threaded: safe to collect locally
        codegenWarnings.add(msg)
  else:
    codegen.warnHandler = proc(msg: string) {.gcsafe.} = discard

  # compile the code for the first time
  compileCode(srcPath, manager, globalData, localData, hasOutput, outputPath,
      enabledSourceMap, enabledPretty, enabledStrict, enabledWatch)

  # initialize the file watcher for browser sync if watch mode is enabled
  if enabledWatch:
    if hasOutput:
      displayInfo("Watching for file changes...")
    
    # Set up a file watcher to recompile on changes, filtered by the
    # entry file's extension (the input may be .bass or plain .css)
    browserSyncWatcher = newWatchout(@[srcPath.parentDir], some("*" & splitFile(srcPath).ext))

    proc onChange(file: watchout.File) =
      if not hasOutput:
        # If no output file is specified, just recompile and print
        # the resulted CSS in the console
        compileCode(file.getPath, manager, globalData, localData, false, "",
            false, false, enabledStrict, true)
      else:
        let t = cpuTime()
        compileCode(file.getPath, manager, globalData, localData, hasOutput,
            outputPath, enabledSourceMap, enabledPretty, enabledStrict, true)
        displayInfo("File changed: " & file.getPath)
        displaySuccess("Recompiled in " & $((cpuTime() - t)) & "s")

    proc onDelete(file: watchout.File) = discard

    # Set up file watcher callbacks and start watching for changes
    browserSyncWatcher.onChange = onChange
    browserSyncWatcher.onDelete = onDelete
    browserSyncWatcher.start()

    while true:
      sleep(1000) # keep the program running to watch for file changes


#
# AST command
#
proc astCommand*(v: Values) =
  ## Generate AST structure from BASS file
  var hasOutput: bool
  var program: Ast # the AST representation of the script
  var srcPath = $(v.get("bass").getPath)
  var outputPath =
    if v.has("-o"):
      hasOutput = true
      v.get("-o").getFilename
    else: ""
  try:
    parser.parseScriptFile(program, srcPath)
  except BroParserError as e:
    displayError(e.msg)
    quit(1)
  
  if not hasOutput:
    echo toJson(program)
  else:
    if fileExists(outputPath):
      if not promptConfirm("Confirm overwrite file `" & outputPath & "`"):
        displayInfo("Canceled")
        return
    writeFile(outputPath.changeFileExt(".ast"), toJson(program))
      

