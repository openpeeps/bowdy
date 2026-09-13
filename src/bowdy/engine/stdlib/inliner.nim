import std/options
import pkg/vancode/interpreter/[chunk, codegen, ast, sym, value]
import ../parser

type
  TempParamDef* = tuple
    pName: string
    pKind: TypeKind
    pKindIdent: string
    pImplSym: Sym
    isMut, isOpt: bool

proc addProc*(script: Script, module: Module, name: string,
              params: seq[TempParamDef] = @[], returnTy: TypeKind,
              impl: ForeignProc = nil, exportSym = true) =
  ## Add a foreign procedure to the given module,
  ## belonging to the given script.
  var nodeParams: seq[ProcParam]
  for param in params:
    case param.pKind
    of ttyHtmlElement:
      add nodeParams, (
        newIdent(param.pName),
        module.sym(param.pKindIdent),
        param.pImplSym,
        param.isMut,
        param.isOpt
      )
    else:
      let paramSym = 
        if param.pImplSym != nil:
          # if the parameter has an implementation value, use its type
          param.pImplSym
        else:
          module.sym($param.pKind)
      add nodeParams, (
        newIdent(param.pName),
        paramSym,
        param.pImplSym,
        param.isMut,
        param.isOpt
      )
  let (sym, theProc) =
    script.newProc(newIdent(name), impl = nil,
        nodeParams, module.sym($(returnTy)), pkForeign, exportSym)
  theProc.foreign = impl
  discard module.addCallable(sym, sym.name)
  # let procIdentifier: Hash = hashIdentity(name)
  # if module.functions.hasKey(procIdentifier):
  #   module.functions[procIdentifier].add(sym)
  # else:
  #   module.functions[procIdentifier] = @[sym]
  if impl != nil:
    script.procs.add(theProc)

proc paramDef*(name: string, kind: TypeKind, val: Value = nil,
                sym: Sym = nil, mut, isOpt: bool = false, kindStr = ""
          ): TempParamDef {.inline.} =
  ## Create a new parameter definition.
  result = (name, kind, kindStr, sym, mut, isOpt)

proc p*(name: string, kind: TypeKind, mut = false, isOpt = false): TempParamDef {.inline.} =
  result = (name, kind, "", nil, mut, isOpt)


proc compileCode*(script: Script, module: Module, filename, code: string) =
  ## Compile some hayago code to the given script and module.
  ## Any generated toplevel code is discarded. This should only be used for
  ## declarations of hayago-side things, eg. iterators.
  var astProgram: Ast
  try:
    parser.parseScript(astProgram, code, "std/system/inline")
  except BroParserError as e:
    echo e.msg
    quit(1)
  try:
    # var codeChunk = newChunk()
    var gen = initCodeGen(script, module, script.mainChunk)
    gen.genScript(astProgram, none(string), emitHalt = false)
  except CodeGenError as e:
    echo e.msg
    quit(1)

const
  InlineCode* = """
const
  aliceblue* = "#F0F8FF",
  antiquewhite* = "#FAEBD7",
  aqua* = "#00FFFF",
  aquamarine* = "#7FFFD4",
  azure* = "#F0FFFF",
  beige* = "#F5F5DC",
  bisque* = "#FFE4C4",
  black* = "#000000",
  blanchedalmond* = "#FFEBCD",
  blue* = "#0000FF",
  blueviolet* = "#8A2BE2",
  brown* = "#A52A2A",
  burlywood* = "#DEB887",
  cadetblue* = "#5F9EA0",
  chartreuse* = "#7FFF00",
  chocolate* = "#D2691E",
  coral* = "#FF7F50",
  cornflowerblue* = "#6495ED",
  cornsilk* = "#FFF8DC",
  crimson* = "#DC143C",
  cyan* = "#00FFFF",
  darkblue* = "#00008B",
  darkcyan* = "#008B8B",
  darkgoldenrod* = "#B8860B",
  darkgray* = "#A9A9A9",
  darkgreen* = "#006400",
  darkkhaki* = "#BDB76B",
  darkmagenta* = "#8B008B",
  darkolivegreen* = "#556B2F",
  darkorange* = "#FF8C00",
  darkorchid* = "#9932CC",
  darkred* = "#8B0000",
  darksalmon* = "#E9967A",
  darkseagreen* = "#8FBC8F",
  darkslateblue* = "#483D8B",
  darkslategray* = "#2F4F4F",
  darkturquoise* = "#00CED1",
  darkviolet* = "#9400D3",
  deeppink* = "#FF1493",
  deepskyblue* = "#00BFFF",
  dimgray* = "#696969",
  dodgerblue* = "#1E90FF",
  firebrick* = "#B22222",
  floralwhite* = "#FFFAF0",
  forestgreen* = "#228B22",
  fuchsia* = "#FF00FF",
  gainsboro* = "#DCDCDC",
  ghostwhite* = "#F8F8FF",
  gold* = "#FFD700",
  goldenrod* = "#DAA520",
  gray* = "#808080",
  green* = "#008000",
  greenyellow* = "#ADFF2F",
  honeydew* = "#F0FFF0",
  hotpink* = "#FF69B4",
  indianred* = "#CD5C5C",
  indigo* = "#4B0082",
  ivory* = "#FFFFF0",
  khaki* = "#F0E68C",
  lavender* = "#E6E6FA",
  lavenderblush* = "#FFF0F5",
  lawngreen* = "#7CFC00",
  lemonchiffon* = "#FFFACD",
  lightblue* = "#ADD8E6",
  lightcoral* = "#F08080",
  lightcyan* = "#E0FFFF",
  lightgoldenrodyellow* = "#FAFAD2",
  lightgray* = "#D3D3D3",
  lightgreen* = "#90EE90",
  lightpink* = "#FFB6C1",
  lightsalmon* = "#FFA07A",
  lightseagreen* = "#20B2AA",
  lightskyblue* = "#87CEFA",
  lightslategray* = "#778899",
  lightsteelblue* = "#B0C4DE",
  lightyellow* = "#FFFFE0",
  lime* = "#00FF00",
  limegreen* = "#32CD32",
  linen* = "#FAF0E6",
  magenta* = "#FF00FF",
  maroon* = "#800000",
  mediumaquamarine* = "#66CDAA",
  mediumblue* = "#0000CD",
  mediumorchid* = "#BA55D3",
  mediumpurple* = "#9370DB",
  mediumseagreen* = "#3CB371",
  mediumslateblue* = "#7B68EE",
  mediumspringgreen* = "#00FA9A",
  mediumturquoise* = "#48D1CC",
  mediumvioletred* = "#C71585",
  midnightblue* = "#191970",
  mintcream* = "#F5FFFA",
  mistyrose* = "#FFE4E1",
  moccasin* = "#FFE4B5",
  navajowhite* = "#FFDEAD",
  navy* = "#000080",
  oldlace* = "#FDF5E6",
  olive* = "#808000",
  olivedrab* = "#6B8E23",
  orange* = "#FFA500",
  orangered* = "#FF4500",
  orchid* = "#DA70D6",
  palegoldenrod* = "#EEE8AA",
  palegreen* = "#98FB98",
  paleturquoise* = "#AFEEEE",
  palevioletred* = "#DB7093",
  papayawhip* = "#FFEFD5",
  peachpuff* = "#FFDAB9",
  peru* = "#CD853F",
  pink* = "#FFC0CB",
  plum* = "#DDA0DD",
  powderblue* = "#B0E0E6",
  purple* = "#800080",
  rebeccapurple* = "#663399",
  red* = "#FF0000",
  rosybrown* = "#BC8F8F",
  royalblue* = "#4169E1",
  saddlebrown* = "#8B4513",
  salmon* = "#FA8072",
  sandybrown* = "#F4A460",
  seagreen* = "#2E8B57",
  seashell* = "#FFF5EE",
  sienna* = "#A0522D",
  silver* = "#C0C0C0",
  skyblue* = "#87CEEB",
  slateblue* = "#6A5ACD",
  slategray* = "#708090",
  snow* = "#FFFAFA",
  springgreen* = "#00FF7F",
  steelblue* = "#4682B4",
  tan* = "#D2B48C",
  teal* = "#008080",
  thistle* = "#D8BFD8",
  tomato* = "#FF6347",
  turquoise* = "#40E0D0",
  violet* = "#EE82EE",
  wheat* = "#F5DEB3",
  white* = "#FFFFFF",
  whitesmoke* = "#F5F5F5",
  yellow* = "#FFFF00",
  yellowgreen* = "#9ACD32"
"""