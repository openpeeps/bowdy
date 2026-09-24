# bowdy JIT pioneer test: foreign fast-path round trip.
#
# Proves a host (bowdy) can extend vancode's DynASM JIT without forking it:
# a foreign proc registered via `registerJitForeignFast` is invoked through
# the registered bridge (not the generic `jitCallProcBridgeFlat` boxing),
# and `Value` payloads cross the native stack as GC-rooted ring indices.
#
# JIT is opt-in at runtime (watch mode / jit:true) but the DynASM backend
# is part of every build, so this suite always runs.
import unittest
import std/tables
import pkg/vancode/interpreter/[chunk, value, vm]
import pkg/vancode/interpreter/jit/compiler_dynasm as cdyn
import pkg/vancode/interpreter/jit/compiler_bridge as bridge

proc pioneerAddBridge(procId: int32, flatArgs: ptr int64, argc: int32,
    argTypes: ptr int32): int64 {.cdecl.} =
  ## Fast bridge for pioneerAdd(a, b): raw int64s in, int64 out.
  ## No allocation, so trivially GC-safe on the JIT thread.
  let arr = cast[ptr UncheckedArray[int64]](flatArgs)
  result = arr[0] + arr[1]

proc pioneerStrBridge(procId: int32, flatArgs: ptr int64, argc: int32,
    argTypes: ptr int32): int64 {.cdecl.} =
  ## Fast bridge returning a string Value: crosses the native stack as a
  ## GC-rooted ring index (raw pointers are invisible to the GC).
  let v = initValue("pioneer-ok")
  result = bridge.jitRootValue(v)

proc buildCaller(script: Script, file: string, callee: Proc,
    pushVals: openArray[int64]): Proc =
  ## Hand-built native proc: push consts, CallD callee, ReturnVal.
  var ch = newChunk(file)
  ch.file = file
  for v in pushVals:
    ch.emit(opcPushI)
    ch.emit(v)
  ch.emit(opcCallD)
  ch.emit(ch.getString(file))
  ch.emit(callee.procId.uint16)
  ch.emit(opcReturnVal)
  result = Proc(name: "caller", kind: pkNative, chunk: ch,
    paramCount: 0, hasResult: true)
  result.procId = script.procs.len
  script.procs.add(result)

proc newEnv(file: string): tuple[script: Script, vm: Vm] =
  bridge.resetJitState() # generation boundary: free code bufs, clear caches
  let main = newChunk(file)
  main.file = file
  let script = newScript(main)
  let vm = newVm()
  vm.importedModules[file] = script
  # Generic-bridge fallback resolves procs via the global VM handle
  # (normally installed by installJit in production).
  bridge.setJitVm(vm)
  (script, vm)

suite "bowdy jit: foreign fast paths":
  test "registered int fast path bypasses the generic bridge":
    let (script, vm) = newEnv("jit_pioneer")
    let callee = Proc(name: "pioneerAdd", kind: pkForeign,
      foreign: proc(a: StackView, c: int): Value = initValue(0i64),
      paramCount: 2, hasResult: true)
    callee.procId = script.procs.len
    script.procs.add(callee)
    bridge.registerJitForeignFast("pioneerAdd",
      JitForeignFast(arity: 2, bridgeFn: cast[pointer](pioneerAddBridge)))
    let caller = buildCaller(script, "jit_pioneer", callee, [40i64, 21i64])
    let fn = cdyn.compileProc(vm, caller)
    check fn != nil
    let res = fn(nil, 0)
    check res.typeId == tyInt
    check res.intVal == 61

  test "string Value crosses the native stack via the root ring":
    let (script, vm) = newEnv("jit_pioneer_str")
    let callee = Proc(name: "pioneerStr", kind: pkForeign,
      foreign: proc(a: StackView, c: int): Value = initValue(""),
      paramCount: 1, hasResult: true)
    callee.procId = script.procs.len
    script.procs.add(callee)
    bridge.registerJitForeignFast("pioneerStr",
      JitForeignFast(arity: 1, bridgeFn: cast[pointer](pioneerStrBridge)))
    let caller = buildCaller(script, "jit_pioneer_str", callee, [0i64])
    let fn = cdyn.compileProc(vm, caller)
    check fn != nil
    let res = fn(nil, 0)
    # closure sees the raw int64 (ring index); resolve it back to the Value
    let v = bridge.jitUnrootValue(res.intVal)
    check v != nil
    check v.typeId == tyString
    check v.stringVal[] == "pioneer-ok"

  test "exceptions raised in bridges propagate through JIT frames":
    let (script, vm) = newEnv("jit_pioneer_raise")
    let callee = Proc(name: "pioneerRaise", kind: pkForeign,
      foreign: proc(a: StackView, c: int): Value =
        raise newException(ValueError, "boom"),
      paramCount: 0, hasResult: true)
    callee.procId = script.procs.len
    script.procs.add(callee)
    let caller = buildCaller(script, "jit_pioneer_raise", callee, [])
    let fn = cdyn.compileProc(vm, caller)
    check fn != nil
    var raised = false
    try:
      discard fn(nil, 0)
    except ValueError:
      raised = true
    check raised

  test "unregistered foreign keeps the generic bridge":
    let (script, vm) = newEnv("jit_pioneer_slow")
    let callee = Proc(name: "pioneerSlow", kind: pkForeign,
      foreign: proc(a: StackView, c: int): Value = initValue(7i64),
      paramCount: 0, hasResult: true)
    callee.procId = script.procs.len
    script.procs.add(callee)
    # NOTE: no registerJitForeignFast — miss must stay correct via fallback
    let caller = buildCaller(script, "jit_pioneer_slow", callee, [])
    let fn = cdyn.compileProc(vm, caller)
    check fn != nil
    let res = fn(nil, 0)
    check res.typeId == tyInt
    check res.intVal == 7
