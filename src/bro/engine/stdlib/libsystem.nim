# A super fast template engine for cool kids
#
# (c) iLiquid, 2019-2020
#     https://github.com/liquidev/
#
# (c) 2025 George Lemon | LGPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/tim | https://openpeeps.dev/packages/tim

import std/[strutils, options, os, sequtils,
        httpclient, httpcore, tables, algorithm, random]

import pkg/openparser/json
import pkg/vancode/interpreter/[chunk, ast, sym, value]

import ../parser
import ./inliner

# import pkg/voodoo/parsers/voojson

type TimRuntime* = object of CatchableError

proc convertObjectToJson(arg: Value): string =
  case arg.objectVal.isForeign
  of false:
    result = "{"
    let obj = arg.objectVal
    for i in 0..<obj.keys.len:
      result.add("\"" & obj.keys[i] & "\": ")
      case obj.fields[i].typeId
      of 4: # string
        result.add("\"" & obj.fields[i].refVal.stringVal[] & "\"")
      of 15: # object
        result.add("[Object]")
      else: # other types
        result.add($obj.fields[i])
      if i < obj.keys.len - 1:
        result.add(", ")
    result.add("}")
  else:
    result = "{...}"

proc initSystemOps(script: Script, module: Module) =
  ## Add builtin operations into the module.
  ## This should only ever be called when creating the ``system`` module.

  # bool operators
  script.addProc(module, "not", @[p("x", ttyBool)], ttyBool)
  script.addProc(module, "==", @[p("a", ttyBool), p("b", ttyBool)], ttyBool)
  script.addProc(module, "!=", @[p("a", ttyBool), p("b", ttyBool)], ttyBool)

  # number type operators

  for T in [(ttyInt, ttyFloat), (ttyFloat, ttyInt)]:
    script.addProc(module, "+", @[p("a", T[0])], T[0])
    script.addProc(module, "-", @[p("a", T[0])], T[0])
    
    script.addProc(module, "+", @[p("a", T[0]), p("b", T[1])], ttyFloat)
    script.addProc(module, "-", @[p("a", T[0]), p("b", T[1])], ttyFloat)
    script.addProc(module, "*", @[p("X", T[0]), p("b", T[1])], ttyFloat)
    script.addProc(module, "/", @[p("a", T[0]), p("b", T[1])], ttyFloat)
  
    script.addProc(module, "==", @[p("a", T[0]), p("b", T[1])], ttyBool)
    script.addProc(module, "!=", @[p("a", T[0]), p("b", T[1])], ttyBool)
    script.addProc(module, "<", @[p("a", T[0]), p("b", T[1])], ttyBool)
    script.addProc(module, "<=", @[p("a", T[0]), p("b", T[1])], ttyBool)
    script.addProc(module, ">", @[p("a", T[0]), p("b", T[1])], ttyBool)
    script.addProc(module, ">=", @[p("a", T[0]), p("b", T[1])], ttyBool)

  for T in [(ttyInt, ttyInt), (ttyFloat, ttyFloat)]:
    script.addProc(module, "+=", @[p("a", T[0], mut = true), p("b", T[1])], ttyVoid)
    script.addProc(module, "-=", @[p("a", T[0], mut = true), p("b", T[1])], ttyVoid)
    script.addProc(module, "*=", @[p("a", T[0], mut = true), p("b", T[1])], ttyVoid)
    script.addProc(module, "/=", @[p("a", T[0], mut = true), p("b", T[1])], ttyVoid)

    script.addProc(module, ">=", @[p("a", T[0]), p("b", T[1])], ttyBool)
    script.addProc(module, "<=", @[p("a", T[0]), p("b", T[1])], ttyBool)
    script.addProc(module, ">",  @[p("a", T[0]), p("b", T[1])], ttyBool)
    script.addProc(module, "<",  @[p("a", T[0]), p("b", T[1])], ttyBool)

  # CSS unit arithmetic for custom length-type values will be added after system types are registered
  # (see loadLibrary below for ttyLength etc.)
  
  script.addProc(module, "==", @[p("a", ttyBool), p("b", ttyBool)], ttyBool)
  script.addProc(module, "!=", @[p("a", ttyBool), p("b", ttyBool)], ttyBool)

proc loadLibrary*(script: Script, globalData, localData: JsonNode): Module =
  ## Create and initialize the ``system`` module.

  # foreign stuff
  result = newModule("system", some"system.timl")
  result.initSystemTypes()
  script.initSystemOps(result)

  # range(lo, hi) — iterable for `for x in range(a, b)` loops.
  # vancode's genFor inlines known-constant int bounds into pure bytecode,
  # so this stub is never invoked at runtime; it only satisfies symbol
  # resolution during codegen (splitCall → lookup).
  script.addProc(result, "range", @[p("lo", ttyInt), p("hi", ttyInt)], ttyInt,
    proc (args: StackView, argc: int): Value =
      result = initValue(args[0].intVal))

  # string operators
  script.addProc(result, "==", @[p("a", ttyString), p("b", ttyString)], ttyBool,
    proc (args: StackView, argc: int): Value =
      result = initValue(args[0].stringVal[] == args[1].stringVal[]))

  script.addProc(result, "!=", @[p("a", ttyString), p("b", ttyString)], ttyBool,
    proc (args: StackView, argc: int): Value =
      result = initValue(args[0].stringVal[] != args[1].stringVal[]))

  script.addProc(result, "is", @[p("a", ttyString), p("b", ttyString)], ttyBool,
    proc (args: StackView, argc: int): Value =
      result = initValue(args[0].stringVal[] == args[1].stringVal[]))
  
  script.addProc(result, "isnot", @[p("a", ttyString), p("b", ttyString)], ttyBool,
    proc (args: StackView, argc: int): Value =
      result = initValue(args[0].stringVal[] != args[1].stringVal[]))

  script.addProc(result, "is", @[p("a", ttyBool), p("b", ttyBool)], ttyBool,
    proc (args: StackView, argc: int): Value =
      result = initValue(args[0].stringVal[] == args[1].stringVal[]))
  
  script.addProc(result, "isnot", @[p("a", ttyBool), p("b", ttyBool)], ttyBool,
    proc (args: StackView, argc: int): Value =
      result = initValue(args[0].stringVal[] != args[1].stringVal[]))

  #
  # JSON operators between JSON and other types
  #
  script.addProc(result, "==", @[p("a", ttyJson), p("b", ttyBool)], ttyBool,
    proc (args: StackView, argc: int): Value =
      assert args[0].jsonVal.kind == JBool
      result = initValue(args[0].jsonVal.getBool == args[1].boolVal))

  script.addProc(result, "==", @[p("a", ttyJson), p("b", ttyString)], ttyBool,
    proc (args: StackView, argc: int): Value =
      assert args[0].jsonVal.kind == JString
      result = initValue(args[0].jsonVal.getStr() == args[1].stringVal[]))

  script.addProc(result, "==", @[p("a", ttyJson), p("b", ttyInt)], ttyBool,
    proc (args: StackView, argc: int): Value =
      assert args[0].jsonVal.kind == JInt
      result = initValue(args[0].jsonVal.getInt() == args[1].intVal))

  script.addProc(result, "==", @[p("a", ttyJson), p("b", ttyFloat)], ttyBool,
    proc (args: StackView, argc: int): Value =
      assert args[0].jsonVal.kind == JFloat
      result = initValue(args[0].jsonVal.getFloat() == args[1].floatVal))

  script.addProc(result, "type", @[p("x", ttyAny)], ttyString,
    proc (args: StackView, argc: int): Value =
      let valueType =
        case args[0].typeId:
        of tyBool: "bool"
        of tyInt: "int"
        of tyFloat: "float"
        of tyString: "string"
        of tyJsonStorage: "json"
        of tyArrayObject: "array"
        else: "object"
      result = initValue(valueType))

  script.addProc(result, "jsonType", @[p("x", ttyJson)], ttyString,
    proc (args: StackView, argc: int): Value =
      let valueType =
        case args[0].jsonVal.kind:
        of JBool: "bool"
        of JInt: "int"
        of JFloat: "float"
        of JString: "string"
        of JArray: "array"
        of JObject: "object"
        else: "nil"
      result = initValue(valueType))

  # converters
  script.addProc(result, "toInt", @[p("f", ttyFloat)], ttyInt,
    proc (args: StackView, argc: int): Value =
      result = initValue(toInt(args[0].floatVal)))

  script.addProc(result, "parseInt", @[p("i", ttyString)], ttyInt,
    proc (args: StackView, argc: int): Value =
      ## Convert a string to an int.
      result = initValue(parseInt(args[0].stringVal[])))

  script.addProc(result, "toFloat", @[p("i", ttyInt)], ttyFloat,
    proc (args: StackView, argc: int): Value =
      ## Convert an int to a float
      result = initValue(toFloat(args[0].intVal)))

  script.addProc(result, "assert", @[p("condition", ttyBool)], ttyVoid,
    proc (args: StackView, argc: int): Value =
      ## Assert that the given condition is true.
      if not args[0].boolVal:
        raise newException(TimRuntime, "Assertion failed: " & $args[0].boolVal))

  #
  # String conversion
  #
  script.addProc(result, "toString", @[p("x", ttyInt)], ttyString,
    proc (args: StackView, argc: int): Value =
      ## Convert an int to a string
      result = initValue($(args[0].intVal))
    )

  script.addProc(result, "toString", @[p("x", ttyFloat)], ttyString,
    proc (args: StackView, argc: int): Value =
      ## Convert a float to a string
      result = initValue($(args[0].floatVal))
    )

  script.addProc(result, "toString", @[p("x", ttyBool)], ttyString,
    proc (args: StackView, argc: int): Value =
      ## Convert bool to string
      result = initValue($(args[0].boolVal))
    )

  script.addProc(result, "toString", @[p("x", ttyJson)], ttyString,
    proc (args: StackView, argc: int): Value =
      ## Convert JSON to string
      case args[0].jsonVal.kind
      of JObject, JArray:
        return initValue(toJson(args[0].jsonVal))
      of JInt:
        return initValue($(args[0].jsonVal.getInt()))
      of JFloat:
        return initValue($(args[0].jsonVal.getFloat()))
      of JBool:
        return initValue($(args[0].jsonVal.getBool()))
      of JString:
        return initValue(args[0].jsonVal.getStr())
      else: discard # todo handle nil
  )

  script.addProc(result, "toString", @[p("x", ttyObject)], ttyString,
    proc (args: StackView, argc: int): Value =
      ## Convert Object to JSON string
      result = initValue(convertObjectToJson(args[0]))
    )

  script.addProc(result, "toKeys", @[p("obj", ttyJson)], ttyJson,
    proc (args: StackView, argc: int): Value =
      ## Get the keys of a JSON object as an array.
      result = initValue(%*(args[0].jsonVal.keys().toSeq()))
    )

  script.addProc(result, "echo", @[p("x", ttyString)], ttyVoid,
    proc (args: StackView, argc: int): Value =
      echo args[0].stringVal[])

  script.addProc(result, "echo", @[p("x", ttyInt)], ttyVoid,
    proc (args: StackView, argc: int): Value =
      echo args[0].intVal)

  script.addProc(result, "echo", @[p("x", ttyFloat)], ttyVoid,
    proc (args: StackView, argc: int): Value =
      echo args[0].floatVal)

  script.addProc(result, "echo", @[p("x", ttyBool)], ttyVoid,
    proc (args: StackView, argc: int): Value =
      echo args[0].boolVal)

  script.addProc(result, "echo", @[p("x", ttyJson)], ttyVoid,
    proc (args: StackView, argc: int): Value =
      case args[0].jsonVal.kind
      of JInt, JFloat, JBool:
        echo $(args[0].jsonVal)
      of JString:
        echo args[0].jsonVal.getStr()
      else:
        echo toJson(args[0].jsonVal)
    )

  script.addProc(result, "echo", @[p("x", ttyNil)], ttyVoid,
    proc (args: StackView, argc: int): Value =
      echo "nil")

  script.addProc(result, "echo", @[p("x", ttyObject)], ttyVoid,
    proc (args: StackView, argc: int): Value =
      echo convertObjectToJson(args[0])
    )

  script.addProc(result, "echo", @[p("x", ttyArray)], ttyVoid,
    proc (args: StackView, argc: int): Value =
      debugEcho args[0]
    )

  script.addProc(result, "echo", @[p("x", ttyPointer)], ttyVoid,
    proc (args: StackView, argc: int): Value =
      if args[0].objectVal == nil or args[0].objectVal.foreign.data == nil:
        echo "pointer(nil)"
      else:
        echo "pointer(", $(cast[int64](args[0].objectVal.foreign.data)), ")"
    )

  script.addProc(result, "toString", @[p("x", ttyInt)], ttyString,
    proc (args: StackView, argc: int): Value =
      result = initValue($args[0].intVal))

  script.addProc(result, "toString", @[p("x", ttyFloat)], ttyString,
    proc (args: StackView, argc: int): Value =
      result = initValue($args[0].floatVal))

  script.addProc(result, "toString", @[p("x", ttyBool)], ttyString,
    proc (args: StackView, argc: int): Value =
      result = initValue($args[0].boolVal))

  script.addProc(result, "cssJoin", @[p("parts", ttyArray)], ttyString,
    proc (args: StackView, argc: int): Value =
      ## Join CSS value parts (plus literal separator strings) into one
      ## string. Target of the parser's desugar for dynamic multi-value
      ## properties (`margin: $a $b`): dynamics arrive pre-stringified via
      ## cssStr so the array stays homogeneous. Non-string elements render
      ## like cssStr, so direct calls stay total too.
      var buf = ""
      for f in args[0].objectVal.fields:
        let vv = f.toValue()
        case vv.typeId
        of tyString: buf.add(vv.stringVal[])
        of tyInt: buf.add($vv.intVal)
        of tyFloat:
          var fs = $vv.floatVal
          if fs.len > 2 and fs[fs.len - 2] == '.' and fs[fs.len - 1] == '0':
            fs.setLen(fs.len - 2)
          buf.add(fs)
        of tyBool: buf.add($vv.boolVal)
        else:
          if vv.objectVal != nil and vv.objectVal.isForeign and
              vv.objectVal.foreign.tag.len > 0:
            buf.add(vv.objectVal.foreign.tag)
      result = initValue(buf))

  script.addProc(result, "cssStr", @[p("x", ttyAny)], ttyString,
    proc (args: StackView, argc: int): Value =
      ## Render one runtime value to its CSS display string: primitives
      ## stringify, strictly typed values use their cached display spelling
      ## (foreign tag). Mirrors the VM's raw-emission pop. Used by the
      ## parser's desugar so `$vars`/calls inside multi-values evaluate.
      let vv = args[0]
      case vv.typeId
      of tyString: result = initValue(vv.stringVal[])
      of tyInt: result = initValue($vv.intVal)
      of tyFloat:
        var fs = $vv.floatVal
        if fs.len > 2 and fs[fs.len - 2] == '.' and fs[fs.len - 1] == '0':
          fs.setLen(fs.len - 2)
        result = initValue(fs)
      of tyBool: result = initValue($vv.boolVal)
      else:
        if vv.objectVal != nil and vv.objectVal.isForeign and
            vv.objectVal.foreign.tag.len > 0:
          result = initValue(vv.objectVal.foreign.tag)
        else:
          result = initValue(""))

  let genT = ast.newIdent("T")
  let genArrayType = newSym(skGenericParam, genT, impl = genT)
  genArrayType.constraint = result.sym"any"

  # script.addProc(result, "len", @[p("x", ttyArray, sym = genArrayType)], ttyInt,
  #   proc (args: StackView, argc: int): Value =
  #     result = initValue(len(args[0].objectVal.fields)))

  # script.addProc(result, "high", @[p("x", ttyArray, sym = genArrayType)], ttyInt,
  #   proc (args: StackView, argc: int): Value =
  #     result = initValue(high(args[0].objectVal.fields)))

  script.addProc(result, "high", @[p("x", ttyJson)], ttyInt,
    proc (args: StackView, argc: int): Value =
      let len =
        if args[0].jsonVal.len > 0:
          len(args[0].jsonVal) - 1
        else: 0
      result = initValue(len)
    )

  script.addProc(result, "high", @[p("x", ttyArray)], ttyInt,
    proc (args: StackView, argc: int): Value =
      let len =
        if args[0].objectVal.fields.len > 0:
          len(args[0].objectVal.fields) - 1
        else: 0
      result = initValue(len)
    )

  # script.addProc(result, "len", @[p("x", ttyObject)], ttyInt,
  #   proc (args: StackView, argc: int): Value =
  #     result = initValue(len(args[0].objectVal.fields)))

  #
  # Mutable number operations
  #
  script.addProc(result, "inc", @[p("i", ttyInt, mut = true)], ttyVoid,
    proc (args: StackView, argc: int): Value =
      inc(args[0].intVal))

  script.addProc(result, "dec", @[p("i", ttyInt, mut = true)], ttyVoid,
    proc (args: StackView, argc: int): Value =
      dec(args[0].intVal))

  #
  # String concatenation
  #
  script.addProc(result, "&", @[p("x", ttyString), p("y", ttyString)], ttyString,
    proc (args: StackView, argc: int): Value =
      result = initValue(args[0].stringVal[] & args[1].stringVal[]))

  script.addProc(result, "&", @[p("x", ttyString), p("y", ttyInt)], ttyString,
    proc (args: StackView, argc: int): Value =
      result = initValue(args[0].stringVal[] & $(args[1].intVal)))

  script.addProc(result, "&", @[p("x", ttyInt), p("y", ttyString)], ttyString,
    proc (args: StackView, argc: int): Value =
      result = initValue($(args[0].intVal) & args[1].stringVal[]))

  script.addProc(result, "&", @[p("x", ttyString), p("y", ttyFloat)], ttyString,
    proc (args: StackView, argc: int): Value =
      result = initValue(args[0].stringVal[] & $(args[1].floatVal)))

  script.addProc(result, "&", @[p("x", ttyFloat), p("y", ttyString)], ttyString,
    proc (args: StackView, argc: int): Value =
      result = initValue($(args[1].floatVal) & args[0].stringVal[]))

  script.addProc(result, "&", @[p("x", ttyString), p("y", ttyBool)], ttyString,
    proc (args: StackView, argc: int): Value =
      result = initValue(args[0].stringVal[] & $(args[1].boolVal)))

  script.addProc(result, "&", @[p("x", ttyBool), p("y", ttyString)], ttyString,
    proc (args: StackView, argc: int): Value =
      result = initValue($(args[0].boolVal) & args[1].stringVal[]))

  #
  # String concatenation with JSON
  #
  script.addProc(result, "&", @[p("x", ttyJson), p("y", ttyString)], ttyString,
    proc (args: StackView, argc: int): Value =
      case args[0].jsonVal.kind
      of JString:
        result = initValue(args[0].jsonVal.getStr() & args[1].stringVal[])
      of JInt:
        result = initValue($(args[0].jsonVal.getInt()) & args[1].stringVal[])
      else: discard # todo error?
    )

  script.addProc(result, "&", @[p("x", ttyString), p("y", ttyJson)], ttyString,
    proc (args: StackView, argc: int): Value =
      case args[1].jsonVal.kind
      of JString:
        result = initValue(args[0].stringVal[] & args[1].jsonVal.getStr())
      else: discard # todo error?
    )

  script.addProc(result, "hasKey", @[p("obj", ttyJson), p("key", ttyString)], ttyBool,
    proc (args: StackView, argc: int): Value =
      result = initvalue(false)
      if args[0].jsonVal.hasKey(args[1].stringVal[]):
        result.boolVal = true
    )

  #
  # Random Utils
  #
  randomize()
  script.addProc(result, "shuffle", @[p("arr", ttyArray)], ttyArray,
    proc (args: StackView, argc: int): Value =
      var arr = initArray(args[0].objectVal.fields.len)
      for i in 0..<args[0].objectVal.fields.len:
        arr.objectVal.fields[i] = args[0].objectVal.fields[i]
      arr.objectVal.fields.shuffle()
      result = arr
    )

  #
  # Echo `$` operator
  #
  # script.addProc(result, "$", @[p("x", ttyBool)], ttyString,
  #   proc (args: StackView, argc: int): Value =
  #     result = initValue($args[0].boolVal))

  # script.addProc(result, "$", @[p("x", ttyInt)], ttyString,
  #   proc (args: StackView, argc: int): Value =
  #     result = initValue($args[0].intVal))

  # script.addProc(result, "$", @[p("x", ttyFloat)], ttyString,
  #   proc (args: StackView, argc: int): Value =
  #     result = initValue($args[0].floatVal))

  # script.addProc(result, "$", @[p("x", ttyString)], ttyString,
  #   proc (args: StackView, argc: int): Value =
  #     result = initValue(args[0].stringVal[]))

  # script.addProc(result, "$", @[p("x", ttyJson)], ttyString,
  #   proc (args: StackView, argc: int): Value =
  #     result = initValue(toJson(args[0].jsonVal)))

  #
  # Content Length
  #
  script.addProc(result, "len", @[p("x", ttyString)], ttyInt,
    proc (args: StackView, argc: int): Value =
      result = initValue(len(args[0].stringVal[])))

  script.addProc(result, "len", @[p("x", ttyJson)], ttyInt,
    proc (args: StackView, argc: int): Value =
      result = initValue(len(args[0].jsonVal)))

  script.addProc(result, "len", @[p("x", ttyArray)], ttyInt,
    proc (args: StackView, argc: int): Value =
      result = initValue(len(args[0].objectVal.fields)))


  #
  # Built-in OS Operations
  # std/os
  #
  script.addProc(result, "readFile", @[p("path", ttyString)], ttyString,
    proc (args: StackView, argc: int): Value =
      initValue(readFile(args[0].stringVal[])))

  script.addProc(result, "writeFile",
    @[p("path", ttyString), p("content", ttyString)], ttyVoid,
    proc (args: StackView, argc: int): Value =
      writeFile(args[0].stringVal[], args[0].stringVal[]))

  script.addProc(result, "sleep", @[p("ms", ttyInt)], ttyVoid,
    proc (args: StackView, argc: int): Value =
      sleep(args[0].intVal))

  #
  # Builtin JSON/YAML support
  #
  script.addProc(result, "parseJSON", @[p("content", ttyString)], ttyJson,
    proc (args: StackView, argc: int): Value =
      result = initValue(fromJson(args[0].stringVal[]))
    )

  script.addProc(result, "loadJSON", @[p("path", ttyString)], ttyJson,
    proc (args: StackView, argc: int): Value =
      let jsonContent = readFile(args[0].stringVal[])
      result = initValue(fromJson(jsonContent))
    )
  
  script.addProc(result, "remoteJSON", @[p("url", ttyString)], ttyJson,
    proc (args: StackView, argc: int): Value =
      ## Fetch a remote JSON file from the given URL.
      var client = newHttpClient()
      try:
        let res = client.get(args[0].stringVal[])
        var resp = %*{
          "status": res.status,
          "headers": toJson(res.headers.table).fromJson(),
          "content": fromJson(res.body)
        }
        result = initValue(resp)
      except:
        let err = getCurrentExceptionMsg()
        var resp = %*{
          "status": 0,
          "headers": %*{},
          "content": %*{"error": err}
        }
        result = initValue(resp)
      finally:
        client.close()
    )

  for someTy in [ttyBool, ttyInt, ttyFloat, ttyString, ttyJson, ttyNil]:
    script.addProc(result, "==", @[p("a", ttyJson), p("b", someTy)], ttyBool,
      proc (args: StackView, argc: int): Value =
        case args[1].typeId
        of tyBool:
          result = initValue(args[0].jsonVal.getBool() == args[1].boolVal)
        of tyInt:
          result = initValue(args[0].jsonVal.getInt() == args[1].intVal)
        of tyFloat:
          result = initValue(args[0].jsonVal.getFloat() == args[1].floatVal)
        of tyString:
          result = initValue(args[0].jsonVal.getStr() == args[1].stringVal[])
        of tyJsonStorage:
          result = initValue(args[0].jsonVal == args[1].jsonVal)
        of tyNil:
          result = initValue(args[0].jsonVal.kind == JNull)
        else:
          raise newException(TimRuntime, "Invalid type for comparison with JSON.")
      )

    script.addProc(result, "==", @[p("a", someTy), p("b", ttyJson)], ttyBool,
      proc (args: StackView, argc: int): Value =
        case args[0].typeId
        of tyBool:
          result = initValue(args[0].boolVal == args[1].jsonVal.getBool())
        of tyInt:
          result = initValue(args[0].intVal == args[1].jsonVal.getInt())
        of tyFloat:
          result = initValue(args[0].floatVal == args[1].jsonVal.getFloat())
        of tyString:
          result = initValue(args[0].stringVal[] == args[1].jsonVal.getStr())
        of tyJsonStorage:
          result = initValue(args[0].jsonVal == args[1].jsonVal)
        of tyNil:
          result = initValue(args[1].jsonVal.kind == JNull)
        else:
          raise newException(TimRuntime, "Invalid type for comparison with JSON.")
      )

    script.addProc(result, "!=", @[p("a", ttyJson), p("b", someTy)], ttyBool,
      proc (args: StackView, argc: int): Value =
        case args[1].typeId
        of tyBool:
          result = initValue(args[0].jsonVal.getBool() != args[1].boolVal)
        of tyInt:
          result = initValue(args[0].jsonVal.getInt() != args[1].intVal)
        of tyFloat:
          result = initValue(args[0].jsonVal.getFloat() != args[1].floatVal)
        of tyString:
          result = initValue(args[0].jsonVal.getStr() != args[1].stringVal[])
        of tyJsonStorage:
          result = initValue(args[0].jsonVal != args[1].jsonVal)
        of tyNil:
          result = initValue(args[0].jsonVal.kind != JNull)
        else:
          raise newException(TimRuntime, "Invalid type for comparison with JSON.")
    )

    script.addProc(result, "!=", @[p("a", someTy), p("b", ttyJson)], ttyBool,
      proc (args: StackView, argc: int): Value =
        case args[0].typeId
        of tyBool:
          result = initValue(args[0].boolVal != args[1].jsonVal.getBool())
        of tyInt:
          result = initValue(args[0].intVal != args[1].jsonVal.getInt())
        of tyFloat:
          result = initValue(args[0].floatVal != args[1].jsonVal.getFloat())
        of tyString:
          result = initValue(args[0].stringVal[] != args[1].jsonVal.getStr())
        of tyJsonStorage:
          result = initValue(args[0].jsonVal != args[1].jsonVal)
        of tyNil:
          result = initValue(args[0].jsonVal.kind != JNull)
        else:
          raise newException(TimRuntime, "Invalid type for comparison with JSON.")
    )

  var inlineCode: string
  inlineCode.add(InlineCode)
  script.compileCode(result, "system", inlineCode)