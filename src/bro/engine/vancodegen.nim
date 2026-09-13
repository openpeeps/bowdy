# A super fast stylesheet language for cool kids!
#
# (c) 2026 George Lemon | LGPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/bowdy

import std/os
import pkg/voodoo/extensibles

block extendAST:
  extendEnum NodeKind:
    nkClassSelector
    nkIdSelector
    nkPseudoSelector
    nkElementSelector
    nkUnit
    nkColor
    nkExprList
    nkProperty  # Represents a CSS property (e.g., color: red)
    nkValue     # Represents a CSS value (e.g., 16px, red)
    nkAtRule    # Represents a CSS at-rule (e.g., @media, @supports)
    nkCommaList # Represents comma-separated CSS values (e.g., 13, 110, 253)
    nkMixinDef  # Represents a mixin definition (reusable declaration block)
    nkCssComment # Preserved doc-block comment (/*! ... */ or /** ... */)
    nkCase
    nkOfBranch

block extendSym:
  extendEnum TypeKind:
    ttyColor
    ttyLength
    ttyNumber
    ttyKeyword
    ttyAngle
    ttyTime
    ttyUrl
    ttyCssString
    ttyResolution
    ttyFlex
    ttyCssVar
    ttyTransform
    ttyFilter
    ttyImage
    ttyShape
    ttyEasing
block extendCodeGen:
  extendModule "vancode" / "interpreter" / "codegen.nim":
    import std/strutils
    import pkg/openparser/css as cssmod
    import pkg/openparser/colors as colormod

    var nestingParent: string = "" ## Sass-style nesting: parent selector context for & substitution
    var mixinTable = initTable[string, Node]() ## registered mixin definitions (name -> nkMixinDef)
    type CustomPropEntry = object
      ## Registered type info for a `--x` custom property declaration.
      ## Concrete kinds enable use-site checking of `var(--x)`; aliases
      ## resolve lazily (bowdy `$var` via scope lookup, chained `var(--y)`
      ## recursively); unjudgeable shapes stay silent-but-declared.
      case hasKind: bool
      of true:
        kind: TypeKind
      of false:
        alias: string # "$var", "var(--other)", or "" (unjudgeable)
    var customPropTable = initTable[string, CustomPropEntry]()
    proc resetCustomProps*() =
      ## Clear the custom-property registry (fresh compile / test isolation).
      customPropTable.clear()
    proc unitSuffixKind(suffix: string): tuple[ok: bool, kind: TypeKind] =
      ## Mirror genUnit's suffix mapping so declarations infer the same type
      ## the value would inhabit at runtime.
      case suffix
      of "px", "em", "rem", "%", "vh", "vw", "vmin", "vmax",
         "ch", "ex", "cm", "mm", "in", "pt", "pc":
        (true, ttyLength)
      of "deg", "rad", "grad", "turn":
        (true, ttyAngle)
      of "s", "ms":
        (true, ttyTime)
      of "dpi", "dpcm", "dppx":
        (true, ttyResolution)
      of "fr":
        (true, ttyFlex)
      else:
        (false, ttyKeyword)
    proc broCallReturnKind(name: string): tuple[ok: bool, kind: TypeKind] =
      ## Statically known return kinds of stdlib value functions.
      case name
      of "lighten", "darken", "saturate", "desaturate", "spin", "mix",
         "mixCMYK", "parseHex", "parseHexAlpha", "parseHtmlHex",
         "parseColor", "parseHtmlName", "parseHtmlColor":
        (true, ttyColor)
      of "parseLength":
        (true, ttyLength)
      of "parseAngle":
        (true, ttyAngle)
      of "parseTime":
        (true, ttyTime)
      of "parseResolution":
        (true, ttyResolution)
      of "parseFlex":
        (true, ttyFlex)
      of "translate3d", "translate", "translateX", "translateY",
         "translateZ", "scale", "scaleX", "scaleY", "scaleZ", "scale3d",
         "rotate", "rotateX", "rotateY", "rotateZ", "rotate3d", "skew",
         "skewX", "skewY", "matrix", "matrix3d", "perspective":
        (true, ttyTransform)
      # NOTE: no "saturate" here: that label is taken by libcolors'
      # saturate(color, amount) -> ttyColor above. The CSS filter
      # saturate(amount) coexists at runtime as a 1-arg overload
      # (arity-disjoint); static inference keeps the color kind.
      of "blur", "brightness", "contrast", "grayscale", "invert", "opacity",
         "sepia", "hue-rotate", "drop-shadow":
        (true, ttyFilter)
      of "linear-gradient", "repeating-linear-gradient",
         "radial-gradient", "repeating-radial-gradient", "conic-gradient",
         "repeating-conic-gradient":
        (true, ttyImage)
      of "circle", "ellipse", "inset", "polygon", "path", "xywh", "ray":
        (true, ttyShape)
      of "cubic-bezier", "steps", "linear":
        (true, ttyEasing)
      of "rgb", "rgba", "hsl", "hsla", "hwb", "lab", "lch", "oklab",
         "oklch", "color", "light-dark", "color-mix":
        (true, ttyColor)
      of "image", "image-set":
        (true, ttyImage)
      else:
        (false, ttyKeyword)
    proc inferCustomPropType(v: Node): CustomPropEntry =
      ## Infer a declaration value's type from its AST shape (no codegen).
      case v.kind
      of nkUnit:
        if v.len > 1 and v[1].kind == nkIdent:
          let sk = unitSuffixKind(v[1].ident)
          if sk.ok: return CustomPropEntry(hasKind: true, kind: sk.kind)
        CustomPropEntry(hasKind: false, alias: "")
      of nkColor:
        CustomPropEntry(hasKind: true, kind: ttyColor)
      of nkInt, nkFloat:
        CustomPropEntry(hasKind: true, kind: ttyNumber)
      of nkString:
        CustomPropEntry(hasKind: true, kind: ttyCssString)
      of nkIdent:
        if v.ident.len > 0 and v.ident[0] == '$':
          CustomPropEntry(hasKind: false, alias: v.ident)
        elif v.ident.startsWith("var("):
          CustomPropEntry(hasKind: false, alias: v.ident)
        else:
          # Keywords (auto, inherit, transparent, ...) are property-specific;
          # judging them needs cascade context, so they stay unjudgeable.
          CustomPropEntry(hasKind: false, alias: "")
      of nkCall:
        if v.len > 0 and v[0].kind == nkIdent:
          # var(--other) declarations chain through the registry
          if v[0].ident == "var" and v.len > 1 and v[1].kind == nkString:
            return CustomPropEntry(hasKind: false,
              alias: "var(" & v[1].stringVal & ")")
          let rk = broCallReturnKind(v[0].ident)
          if rk.ok: return CustomPropEntry(hasKind: true, kind: rk.kind)
        CustomPropEntry(hasKind: false, alias: "")
      else: # compounds, nil, postfix: unjudgeable
        CustomPropEntry(hasKind: false, alias: "")
    proc collectCustomProps*(program: Ast) =
      ## Pre-pass: register every `--x: value` declaration in a module AST
      ## (entry file and each import). Order-independent, last wins; selector
      ## and media scoping is intentionally ignored (global approximation).
      proc walk(n: Node) =
        if n.kind == nkColon and n.len > 1:
          let k = n[0]
          let name =
            if k.kind == nkIdent: k.ident
            elif k.kind == nkString: k.stringVal
            else: ""
          if name.len > 2 and name[0] == '-' and name[1] == '-':
            customPropTable[name] = inferCustomPropType(n[1])
        # Leaf nodes (nkEmpty..nkIdent) carry no children field.
        if n.kind notin {nkEmpty .. nkIdent}:
          for c in n.children:
            walk(c)
      for n in program.nodes:
        walk(n)
    var strictCss* = false
    ## When true, the static CSS type system runs: use-site checks of
    ## dynamic values against property syntax (checkPropValueType, incl.
    ## var() registry checks and unknown-var warnings), static literal
    ## validation (cssValidateProp), and invalid-color errors. When false
    ## only VM/JIT types apply (vancode vars, fn params, stdlib signatures);
    ## rendering (incl. named-color normalization) is identical either way.
    ## Set per compile by the CLI (`--strict`) or embed API.
    var rawPropMode = false ## when true, properties emit as raw text (for if/for inside rules)
    ## Optional hook for reporting non-fatal codegen warnings; when unset,
    ## warnings go to stderr with a `[warn]` prefix. The CLI layer installs
    ## a handler that collects messages and flushes them via kapsis
    ## `displayWarning` once the command finishes.
    var warnHandler*: proc(msg: string) {.gcsafe.}

    proc codegenWarn(file: string, ln, col: int, msg: string) =
      let full = file & ":" & $ln & ":" & $col & " " & msg
      if warnHandler != nil:
        warnHandler(full)
      else:
        stderr.write("[warn] " & full & "\n")

    let cssData = cssmod.loadCssData()

    proc parseCssValues(raw: string): seq[cssmod.CssValue] =
      let fakeCss = "*{x:" & raw & "}"
      let style = cssmod.parseCss(fakeCss)
      if style.nodes.len > 0 and style.nodes[0].kind == cssmod.cssRuleSet:
        if style.nodes[0].declarations.len > 0:
          result = style.nodes[0].declarations[0].valueComponents

    proc cssValidateProp(propName: string, rawValue: var string): string =
      let vals = parseCssValues(rawValue)
      var res = cssmod.validate(cssData, propName, vals)
      if not res.valid:
        # Try auto-appending px for bare numbers like "100" -> "100px"
        if rawValue.len > 0 and rawValue[0] in {'0'..'9', '-'} and not rawValue.contains({'a'..'z', 'A'..'Z', '%'}):
          let pxValue = rawValue & "px"
          let pxVals = parseCssValues(pxValue)
          let pxRes = cssmod.validate(cssData, propName, pxVals)
          if pxRes.valid:
            rawValue = pxValue
            res = pxRes
          else:
            res = pxRes
        if not res.valid:
          var expected = ""
          if cssData.properties.hasKey(propName):
            expected = cssData.properties[propName].syntax
          var msg = propName & ": got '" & rawValue & "'"
          if expected.len > 0:
            msg &= ", expected " & expected
          raise newException(ValueError, msg)
      let syn = cssmod.getPropertySyntax(cssData, propName)
      if syn == nil: return "keyword"
      case syn.kind
      of skType: result = syn.cssType
      else: result = "keyword"

    proc cssGetPropertySyntax(propName: string): cssmod.SyntaxNode =
      cssmod.getPropertySyntax(cssData, propName)

    const colorPassthroughWords = ["transparent", "currentcolor",
      "inherit", "initial", "unset", "revert", "revert-layer"]

    proc isColorPassthroughWord(s: string): bool {.inline.} =
      s.toLowerAscii() in colorPassthroughWords

    proc tryNamedToHex(name: string): string =
      ## Lowercase hex (`#ff0000`) for a named color, "" when not a named
      ## color or when the word must stay verbatim (passthrough keywords,
      ## CSS vars, hex literals, functions are handled by callers).
      if name.len == 0: return ""
      if name[0] in {'#', '$', '-', '"', '\''}: return ""
      let lower = name.toLowerAscii()
      if lower in colorPassthroughWords: return ""
      for ch in name:
        if ch in {'(', ')', ',', '/', ' ', '\t', '"', '\''}:
          return ""
      try:
        let c = colormod.parseColor(name)
        # Only named colors convert; bare hex fragments (efd), functions
        # and other parseable forms must stay verbatim.
        if c.format != colormod.cfNamed:
          return ""
        result = c.toHex().toLowerAscii()
      except CatchableError:
        result = ""

    proc normalizeRawCssColors(raw: string): string =
      ## Replace whole-word named colors with lowercase hex in a rendered
      ## property value. Skips quoted strings ("red"), hex literals, var()/
      ## custom-prop names and passthrough keywords. Converts inside raw
      ## CSS functions too (linear-gradient(red, blue)).
      if raw.len == 0: return raw
      result = newStringOfCap(raw.len + 16)
      var i = 0
      while i < raw.len:
        let ch = raw[i]
        if ch == '#':
          # Hex literal: copy verbatim so inner fragments (efd in #0d6efd)
          # are never treated as named-color words.
          result.add(ch)
          inc i
          while i < raw.len and raw[i] in {'0'..'9', 'a'..'f', 'A'..'F'}:
            result.add(raw[i])
            inc i
          continue
        if ch == '"' or ch == '\'':
          let q = ch
          result.add(q)
          inc i
          while i < raw.len:
            result.add(raw[i])
            if raw[i] == q:
              inc i
              break
            inc i
          continue
        elif ch in {'A'..'Z', 'a'..'z'}:
          var j = i
          while j < raw.len and raw[j] in {'A'..'Z', 'a'..'z'}:
            inc j
          let word = raw[i ..< j]
          let hex = tryNamedToHex(word)
          # Convert only standalone words: a run touching identifier chars,
          # hyphens, hashes or `$` is part of a larger ident (custom property
          # names like --color-gray, dimensions like gray100, hashes like
          # #red) and must stay verbatim. A real named color is always
          # delimited by whitespace, comma, paren, slash or string bounds.
          let beforeIdent = i > 0 and raw[i - 1] in {'A'..'Z', 'a'..'z',
            '0'..'9', '-', '_', '#', '$'}
          let afterIdent = j < raw.len and raw[j] in {'A'..'Z', 'a'..'z',
            '0'..'9', '-', '_'}
          # Avoid converting function names (followed by '(') — e.g. `red`
          # is never a function name, but guard for future color functions.
          if hex.len > 0 and not beforeIdent and not afterIdent and
              not (j < raw.len and raw[j] == '('):
            result.add(hex)
          else:
            result.add(word)
          i = j
          continue
        else:
          result.add(ch)
          inc i

    proc cssTypeToKind(cssType: string): TypeKind =
      case cssType
      of "color": ttyColor
      of "length": ttyLength
      of "number", "integer": ttyNumber
      of "angle": ttyAngle
      of "time": ttyTime
      of "url": ttyUrl
      of "resolution": ttyResolution
      of "flex": ttyFlex
      of "string": ttyCssString
      of "transform-list": ttyTransform
      of "filter-value-list": ttyFilter
      of "image", "bg-image", "gradient": ttyImage
      of "basic-shape", "offset-path": ttyShape
      of "easing-function": ttyEasing
      else: ttyKeyword

    proc cssKindName(k: TypeKind): string =
      case k
      of ttyColor: "color"
      of ttyLength: "length"
      of ttyAngle: "angle"
      of ttyTime: "time"
      of ttyNumber: "number"
      of ttyUrl: "url"
      of ttyResolution: "resolution"
      of ttyFlex: "flex"
      of ttyCssString: "string"
      of ttyCssVar: "css-var"
      of ttyTransform: "transform"
      of ttyFilter: "filter"
      of ttyImage: "image"
      of ttyShape: "shape"
      of ttyEasing: "easing"
      else: "keyword"

    proc isBroCall(node: Node): bool {.codegen.} =
      ## True when node calls a known bowdy foreign proc (lighten, mix,
      ## parseLength, parseColor, var, ...) rather than a raw CSS function
      ## (linear-gradient, rgb, calc). bowdy calls evaluate to strictly
      ## typed runtime values; raw CSS calls stay verbatim text.
      if node.kind != nkCall or node.len == 0 or node[0].kind != nkIdent:
        return false
      let s = gen.lookup(node[0], quiet = true)
      result = s != nil and s.kind in {skProc, skChoice}

    proc collectAcceptedKinds(node: cssmod.SyntaxNode,
        acc: var seq[TypeKind], unknown: var bool,
        visited: var seq[string]) =
      ## Walk a CSS syntax tree collecting the value kinds a property accepts.
      ## unknown=true means the syntax has parts we cannot judge (functions,
      ## token refs, exotic component types) — the check then accepts everything.
      ## Data refs (`<font-weight-absolute>`, `<'foo'>`) resolve through the
      ## syntax table with a cycle guard, so real alternatives count instead
      ## of silently narrowing the accepted set (e.g. font-weight numbers).
      if node == nil:
        unknown = true
        return
      case node.kind
      of skType:
        case node.cssType
        of "color", "color-base", "hex-color", "named-color",
           "system-color", "deprecated-system-color": acc.add(ttyColor)
        of "length", "length-percentage", "percentage": acc.add(ttyLength)
        of "number", "number-percentage", "integer",
           "signed-integer", "signless-integer": acc.add(ttyNumber)
        of "angle", "angle-percentage": acc.add(ttyAngle)
        of "time": acc.add(ttyTime)
        of "resolution": acc.add(ttyResolution)
        of "flex": acc.add(ttyFlex)
        of "url": acc.add(ttyUrl)
        of "string": acc.add(ttyCssString)
        of "transform-list": acc.add(ttyTransform)
        of "filter-value-list": acc.add(ttyFilter)
        of "image", "bg-image", "gradient": acc.add(ttyImage)
        of "basic-shape", "offset-path": acc.add(ttyShape)
        of "easing-function": acc.add(ttyEasing)
        else:
          if node.cssType notin visited:
            visited.add(node.cssType)
            let sub = cssmod.resolveType(cssData, node.cssType)
            if sub != nil:
              collectAcceptedKinds(sub, acc, unknown, visited)
            else:
              unknown = true
      of skPropertyRef:
        # `<'prop'>` means "same syntax as that property": resolve through
        # the syntax table first, then the property table (background-color
        # lives only there). Unresolvable refs stay unknown.
        if node.propRef notin visited:
          visited.add(node.propRef)
          var sub = cssmod.resolveType(cssData, node.propRef)
          if sub == nil:
            sub = cssGetPropertySyntax(node.propRef)
          if sub != nil:
            collectAcceptedKinds(sub, acc, unknown, visited)
          else:
            unknown = true
      of skKeyword: acc.add(ttyKeyword)
      of skNumeric: acc.add(ttyNumber)
      of skString: acc.add(ttyCssString)
      of skAlternatives: (for c in node.alternatives: collectAcceptedKinds(c, acc, unknown, visited))
      of skAtLeastOne: (for c in node.options: collectAcceptedKinds(c, acc, unknown, visited))
      of skAll: (for c in node.required: collectAcceptedKinds(c, acc, unknown, visited))
      of skJuxtapose: (for c in node.sequence: collectAcceptedKinds(c, acc, unknown, visited))
      of skGroup: collectAcceptedKinds(node.group, acc, unknown, visited)
      of skOptional: collectAcceptedKinds(node.optionalInner, acc, unknown, visited)
      of skZeroOrMore: collectAcceptedKinds(node.starInner, acc, unknown, visited)
      of skOneOrMore: collectAcceptedKinds(node.plusInner, acc, unknown, visited)
      of skCommaSep: collectAcceptedKinds(node.hashInner, acc, unknown, visited)
      of skRequired: collectAcceptedKinds(node.bangInner, acc, unknown, visited)
      of skMulti: collectAcceptedKinds(node.multiInner, acc, unknown, visited)
      else: unknown = true # functions, token refs, delims: cannot judge statically

    proc checkKindAgainst(key: string, actual: TypeKind, kinds: seq[TypeKind],
        errNode: Node, origin = "") =
      ## Shared kinds-membership check with bare-number coercion (mirrors the
      ## auto-px validation philosophy). `origin` names the value source,
      ## e.g. " (from --size)" for var() references.
      var names = ""
      var seen: set[TypeKind] = {}
      for k in kinds:
        if k in seen: continue
        seen.incl(k)
        if names.len > 0: names.add("|")
        names.add(cssKindName(k))
      case actual
      of ttyColor, ttyLength, ttyAngle, ttyTime, ttyResolution, ttyFlex,
         ttyUrl, ttyCssString, ttyTransform, ttyFilter, ttyImage, ttyShape,
         ttyEasing:
        # NOTE: ttyCssVar stays out (legacy-lenient): var() references
        # check structurally via checkVarRefs first, and undeclared names
        # must only warn, never hard-error here.
        if actual notin kinds:
          errNode.error(key & ": expected " & names & ", got " &
            cssKindName(actual) & origin)
      of ttyInt, ttyFloat, ttyNumber:
        var numericOk = false
        for k in kinds:
          if k in {ttyLength, ttyAngle, ttyTime, ttyNumber, ttyResolution,
              ttyFlex}:
            numericOk = true
            break
        if not numericOk:
          errNode.error(key & ": expected " & names & ", got number" & origin)
      else: discard # strings and the rest stay legacy-lenient

    proc varRefKind(gen: CodeGen, name: string,
        visited: var seq[string]): tuple[declared, ok: bool, kind: TypeKind] =
      ## Resolve a custom-property name to a concrete kind via the registry:
      ## concrete entries, `$var` aliases via scope lookup, chained
      ## `var(--other)` declarations recursively with a cycle guard.
      ## Undeclared names report declared=false (use sites warn); cycles and
      ## unjudgeable shapes report ok=false (use sites stay silent).
      if not customPropTable.hasKey(name): return (false, false, ttyKeyword)
      let e = customPropTable[name]
      if e.hasKind: return (true, true, e.kind)
      if e.alias.len == 0: return (true, false, ttyKeyword)
      if e.alias[0] == '$':
        let s = gen.lookup(ast.newIdent(e.alias), quiet = true)
        if s != nil and s.kind in {skVar, skLet, skConst} and s.varTy != nil:
          return (true, true, s.varTy.tyKind)
        return (true, false, ttyKeyword)
      if e.alias.startsWith("var(") and e.alias.endsWith(")"):
        var inner = e.alias[4 ..< e.alias.len - 1]
        let ci = inner.find(',')
        let other = (if ci == -1: inner else: inner[0 ..< ci]).strip()
        if other in visited: return (true, false, ttyKeyword)
        visited.add(other)
        return varRefKind(gen, other, visited)
      (true, false, ttyKeyword)

    proc fallbackKind(gen: CodeGen, fb: Node): tuple[ok: bool, kind: TypeKind] =
      ## Static kind of a var() fallback node without codegen emission.
      ## Strings, keywords and unknown shapes stay legacy-lenient (not ok).
      case fb.kind
      of nkColor: (true, ttyColor)
      of nkInt, nkFloat: (true, ttyNumber)
      of nkUnit:
        if fb.len > 1 and fb[1].kind == nkIdent:
          let sk = unitSuffixKind(fb[1].ident)
          if sk.ok: return (true, sk.kind)
        (false, ttyKeyword)
      of nkIdent:
        if fb.ident.len > 0 and fb.ident[0] == '$':
          let s = gen.lookup(fb, quiet = true)
          if s != nil and s.kind in {skVar, skLet, skConst} and s.varTy != nil:
            return (true, s.varTy.tyKind)
        (false, ttyKeyword)
      of nkCall:
        if fb.len > 0 and fb[0].kind == nkIdent:
          let rk = broCallReturnKind(fb[0].ident)
          if rk.ok: return (true, rk.kind)
        (false, ttyKeyword)
      else: (false, ttyKeyword)

    proc isVarCall(n: Node): bool =
      n != nil and n.kind == nkCall and n.len > 0 and
        n[0].kind == nkIdent and n[0].ident == "var"

    proc checkVarCall(gen: CodeGen, key: string, call: Node,
        inCall = false) =
      ## Structural check for one var(--name[, fallback]) call: declared-type
      ## mismatches are hard errors, undeclared names warn, fallbacks check
      ## as standalone values. Non-string names cannot resolve statically.
      ## Reports on the call node, which carries the var token coordinates.
      ## inCall skips the kind checks (but never the undeclared warning):
      ## nested in another call's args (`rgba(t, var(--a))`), the var sits
      ## in a positional slot (alpha, stop, ...) whose type differs from
      ## the property's, so property-kind checking is unsound there. The
      ## runtime impls validate what they statically can.
      if call.len < 2 or call[1].kind != nkString: return
      let name = call[1].stringVal
      var kinds: seq[TypeKind]
      var unknown = false
      var refVisited: seq[string] = @[]
      collectAcceptedKinds(cssGetPropertySyntax(key), kinds, unknown, refVisited)
      if kinds.len > 0:
        var visited = @[name]
        let r = varRefKind(gen, name, visited)
        if not r.declared:
          codegenWarn(gen.chunk.file, call.ln, call.col,
            "var(" & name & ") is not declared (unknown custom property)")
        elif r.ok and not inCall:
          checkKindAgainst(key, r.kind, kinds, call, " (from " & name & ")")
      if call.len > 2:
        if isVarCall(call[2]):
          checkVarCall(gen, key, call[2], inCall)
        elif not inCall:
          let fk = fallbackKind(gen, call[2])
          if fk.ok and kinds.len > 0:
            checkKindAgainst(key, fk.kind, kinds, call,
              " (var(" & name & ") fallback)")

    proc checkVarRefs(gen: CodeGen, key: string, v: Node,
        inCall = false) =
      ## Find var() calls in a (possibly compound) dynamic value and check
      ## each structurally: cssJoin desugar arrays, lists, call args.
      ## Descending into a non-var call's args sets inCall (positional
      ## slots); compounds keep direct-position checking.
      if isVarCall(v):
        checkVarCall(gen, key, v, inCall)
        return
      if v != nil:
        case v.kind
        of nkCall, nkColon, nkExprList, nkCommaList, nkArray, nkInfix,
           nkPostfix, nkBracket, nkUnit:
          # cssJoin/cssStr are parser-synthesized wrappers around direct
          # value positions, not real calls: they must not flip positional
          # checking (their parts check as direct values).
          let inner = inCall or (v.kind == nkCall and
            not (v.len > 0 and v[0].kind == nkIdent and
              v[0].ident in ["cssJoin", "cssStr"]))
          for c in v.children:
            checkVarRefs(gen, key, c, inner)
        else: discard

    proc checkPropValueType(gen: CodeGen, key: string, valTy: Sym, errNode: Node) =
      ## Static type check for dynamic property values (vars, bowdy calls,
      ## infix). Literals are validated as text elsewhere; strings and other
      ## shapes stay legacy-lenient. Mismatched CSS value types are hard errors
      ## (e.g. `width: $colorVar` or `color: $lengthVar`). var() references
      ## check structurally against the custom-property registry first.
      ## Runs only under `--strict`; otherwise VM/JIT types alone apply.
      if not strictCss: return
      if valTy == nil: return
      checkVarRefs(gen, key, errNode)
      var kinds: seq[TypeKind]
      var unknown = false
      var refVisited: seq[string] = @[]
      collectAcceptedKinds(cssGetPropertySyntax(key), kinds, unknown, refVisited)
      # Empty sets (margin via property refs, unknown shorthands) accept all.
      # Otherwise a typed value outside the known members is a hard error even
      # when exotic alternatives exist — no bowdy runtime value inhabits those.
      if kinds.len == 0: return
      var actual = valTy.tyKind
      if valTy.kind in {skVar, skLet, skConst} and valTy.varTy != nil:
        actual = valTy.varTy.tyKind
      checkKindAgainst(key, actual, kinds, errNode)

    proc propAcceptsColor(propName: string): bool =
      ## True when the property syntax accepts a color value (used to scope
      ## strict invalid-color checks without false positives on shorthands).
      if propName.len > 2 and propName[0] == '-' and propName[1] == '-':
        return false # custom properties accept anything
      var kinds: seq[TypeKind]
      var unknown = false
      var refVisited: seq[string] = @[]
      collectAcceptedKinds(cssGetPropertySyntax(propName), kinds, unknown, refVisited)
      result = ttyColor in kinds

    proc isSingleColorProp(propName: string): bool =
      ## True only when the property syntax is exactly a single <color>
      ## (color, background-color, ...). Shorthands like border/background
      ## also accept colors but a lone word there may be width/style/keyword
      ## (border: 1px), so strict bare-word checks must not apply to them.
      let syn = cssGetPropertySyntax(propName)
      if syn == nil: return false
      if syn.kind != skType: return false
      result = syn.cssType in ["color", "color-base", "hex-color",
        "named-color", "system-color", "deprecated-system-color"]

    proc strictValidateColorValue(propName, rawValue: string, errNode: Node) =
      ## Raise on invalid colors. Called after normalization, so remaining
      ## single-word idents in single-color positions must parse.
      ## Runs only under `--strict`; normalization itself always applies.
      if not strictCss: return
      if propName.len > 2 and propName[0] == '-' and propName[1] == '-':
        return
      var i = 0
      while i < rawValue.len:
        if rawValue[i] == '#':
          var j = i + 1
          while j < rawValue.len and rawValue[j] in {'0'..'9', 'a'..'z', 'A'..'Z'}:
            inc j
          let token = rawValue[i ..< j]
          if token.len > 1 and token.len <= 9:
            try:
              discard colormod.parseColor(token)
            except CatchableError as e:
              errNode.error(propName & ": invalid color '" & token & "': " & e.msg)
          i = j
          continue
        inc i
      let stripped = rawValue.strip()
      if stripped.len == 0 or stripped.contains({' ', '\t', ',', '(', ')', '/', '"', '\''}):
        return
      if stripped.len > 0 and stripped[0] in {'#', '$', '"', '\''}: return
      if stripped.startsWith("--"): return
      if stripped.startsWith("var(") or stripped.startsWith("env("): return
      if isColorPassthroughWord(stripped): return
      if not isSingleColorProp(propName): return
      try:
        discard colormod.parseColor(stripped)
      except CatchableError as e:
        errNode.error(propName & ": invalid color '" & stripped & "': " & e.msg)

    proc resolvePropValue(propName: string, rawCss: string, valNode, errNode: Node): string =
      ## Normalize named colors to lowercase hex + strictly validate.
      if propName.len > 2 and propName[0] == '-' and propName[1] == '-':
        return rawCss
      result = normalizeRawCssColors(rawCss)
      if result.len > 1 and result[0] == '#' and not result.contains({' ', '\t', ',', '(', ')'}):
        result = result.toLowerAscii()
      strictValidateColorValue(propName, result, errNode)

    proc cssFloatStr(f: float): string =
      ## Render a float for CSS output — strips a trailing ".0" so integral
      ## values emit as "1000" instead of "1000.0" (e.g. scientific notation).
      result = $f
      if result.endsWith(".0"):
        result.setLen(result.len - 2)

    proc nodeToCssString(node: Node): string

    proc nodeToCssString(node: Node): string =
      case node.kind
      of nkIdent: result = node.ident
      of nkInt: result = $node.intVal
      of nkFloat: result = cssFloatStr(node.floatVal)
      of nkString:
        if node.stringVal.len > 0 and node.stringVal[0] == '#':
          result = node.stringVal # hex color literal, no quotes
        else:
          # Re-escape double quotes for valid CSS string output
          result = "\"" & node.stringVal.replace("\"", "\\\"") & "\""
      of nkUnit:
        result = if node[0].kind == nkInt: $node[0].intVal else: cssFloatStr(node[0].floatVal)
        result &= node[1].ident
      of nkColor:
        result = node[0].stringVal # raw spelling: #fff, red, transparent
      of nkExprList:
        var parts: seq[string]
        for child in node.children:
          parts.add(nodeToCssString(child))
        result = parts.join(" ")
      of nkCommaList:
        var cparts: seq[string]
        for child in node.children:
          cparts.add(nodeToCssString(child))
        result = cparts.join(", ")
      of nkCall:
        if node.children.len > 0 and node[0].kind == nkIdent:
          result = node[0].ident & "("
          var args: seq[string]
          for i in 1..<node.children.len:
            args.add(nodeToCssString(node[i]))
          result &= args.join(",") & ")"
      of nkInfix:
        if node.children.len >= 3:
          result = nodeToCssString(node[1]) & " " & nodeToCssString(node[0]) & " " & nodeToCssString(node[2])
      of nkPostfix:
        if node.children.len >= 2:
          result = nodeToCssString(node[1]) & " !" & node[0].ident
      else: result = ""

    proc valueNeedsVm(gen: CodeGen, v: Node): bool =
      ## True when a property value cannot be rendered statically: a `$var`
      ## reference, a bowdy value-function call, or a compound containing one.
      ## Static rendering would leak `$name` or call source text into the CSS.
      case v.kind
      of nkIdent:
        v.ident.len > 0 and v.ident[0] == '$'
      of nkCall:
        gen.isBroCall(v)
      of nkExprList, nkCommaList, nkInfix, nkPostfix, nkBracket:
        for c in v.children:
          if valueNeedsVm(gen, c): return true
        false
      else: false

    proc emitVmPropValue(gen: CodeGen, key: string, v, errNode: Node, isLast: bool) =
      ## Emit `key:<evaluated>[;]` as raw text for dynamic values: `$var`
      ## references resolve against runtime scope (globals included), bowdy
      ## calls evaluate to strictly typed values rendered via their tag.
      gen.chunk.emit(opcPushS)
      gen.chunk.emit(gen.chunk.getString(key & ":"))
      gen.chunk.emit(opcEmitRaw)
      gen.chunk.emit(uint16(errNode.ln))
      gen.chunk.emit(uint16(errNode.col))
      checkPropValueType(gen, key, gen.genExpr(v), v)
      gen.chunk.emit(opcEmitRaw)
      gen.chunk.emit(uint16(0xFFFF))
      gen.chunk.emit(uint16(0))
      if not isLast:
        gen.chunk.emit(opcPushS)
        gen.chunk.emit(gen.chunk.getString(";"))
        gen.chunk.emit(opcEmitRaw)
        gen.chunk.emit(uint16(0xFFFF))
        gen.chunk.emit(uint16(0))

    proc splitSelector(text: string): seq[string] =
      ## Split a comma-separated selector text into individual selectors.
      for part in text.split(','):
        let s = part.strip()
        if s.len > 0:
          result.add(s)

    proc selectorText(node: Node): string =
      ## Extract the raw selector text from a selector node.
      case node[0].kind
      of nkIdent: result = node[0].ident
      of nkBracket:
        var parts: seq[string]
        for id in node[0].children:
          if id.kind == nkIdent:
            parts.add(id.ident)
        result = parts.join(",")
      else: result = ""

    proc applyParent(childText, parentText: string): seq[string] =
      ## Sass-style selector combination.
      ## If child contains `&`, replace `&` with parent (compound, no space).
      ## If child doesn't contain `&`, prepend parent with space (descendant).
      var childParts = splitSelector(childText)
      var parentParts = splitSelector(parentText)
      result = @[]
      for parent in parentParts:
        for child in childParts:
          if '&' in child:
            result.add(child.replace("&", parent))
          else:
            result.add(parent & " " & child)

    proc expandValue(n: Node, pm: Table[string, Node]): Node =
      ## Recursively substitute mixin parameters (`$name`) in an expression tree.
      case n.kind
      of nkIdent:
        if n.ident in pm: pm[n.ident] else: n
      of nkExprList, nkCommaList, nkInfix, nkPostfix, nkCall, nkBracket:
        let r = ast.newNode(n.kind)
        for c in n.children:
          r.add(expandValue(c, pm))
        r.ln = n.ln; r.col = n.col
        r
      else: n # leaves (nkInt, nkFloat, nkString, nkUnit...) pass through

    proc substStmt(n: Node, pm: Table[string, Node]): Node =
      ## Recursively substitute mixin parameters within a statement node.
      case n.kind
      of nkColon:
        # property: key stays, value substitutes. Keep source position so
        # sourcemaps point at the mixin definition (Sass behavior).
        let r = ast.newTree(nkColon, n[0], expandValue(n[1], pm))
        r.ln = n.ln; r.col = n.col
        r
      of nkClassSelector, nkIdSelector, nkPseudoSelector, nkElementSelector:
        var blk = ast.newNode(nkBlock)
        for c in n[3].children:
          blk.add(substStmt(c, pm))
        let r = ast.newTree(n.kind, n[0], n[1], n[2], blk)
        r.ln = n.ln; r.col = n.col
        r
      of nkAtRule:
        var blk = ast.newNode(nkBlock)
        for c in n[2].children:
          blk.add(substStmt(c, pm))
        let r = ast.newTree(nkAtRule, n[0], n[1], blk)
        r.ln = n.ln; r.col = n.col
        r
      of nkIf:
        let r = ast.newNode(nkIf)
        var i = 0
        while i < n.len:
          if i mod 2 == 0 and (i + 1 < n.len or n.len mod 2 == 0):
            r.add(expandValue(n[i], pm)) # condition
          else:
            var blk = ast.newNode(nkBlock)
            for c in n[i].children:
              blk.add(substStmt(c, pm))
            r.add(blk)
          inc i
        r.ln = n.ln; r.col = n.col
        r
      of nkWhile:
        var blk = ast.newNode(nkBlock)
        for c in n[1].children:
          blk.add(substStmt(c, pm))
        let r = ast.newTree(nkWhile, expandValue(n[0], pm), blk)
        r.ln = n.ln; r.col = n.col
        r
      of nkFor:
        var blk = ast.newNode(nkBlock)
        for c in n[2].children:
          blk.add(substStmt(c, pm))
        let r = ast.newTree(nkFor, n[0], expandValue(n[1], pm), blk)
        r.ln = n.ln; r.col = n.col
        r
      else: n

    proc paramNames(m: Node): seq[string] =
      ## Extract parameter names from a mixin's nkFormalParams node.
      ## Note: parseIdentDefs merges comma-separated params into a single
      ## nkIdentDefs whose leading children are the identifiers.
      let fp = m[1]
      for i in 1 ..< fp.len:
        let pd = fp[i]
        if pd.kind == nkIdentDefs and pd.len >= 3:
          for j in 0 ..< pd.len - 2:
            if pd[j].kind == nkIdent:
              result.add(pd[j].ident)
        elif pd.kind == nkIdent:
          result.add(pd.ident)

    proc paramDefault(m: Node, name: string): Node =
      ## Return the default value node for a parameter, or nil.
      let fp = m[1]
      for i in 1 ..< fp.len:
        let pd = fp[i]
        if pd.kind == nkIdentDefs and pd.len >= 3:
          var inGroup = false
          for j in 0 ..< pd.len - 2:
            if pd[j].kind == nkIdent and pd[j].ident == name:
              inGroup = true
          if inGroup:
            let dv = pd[pd.len - 1]
            if dv.kind != nkEmpty:
              return dv
      return nil

    proc paramKey(name: string): string =
      ## Body references use the `$name` form; signature params are bare
      ## (`mixin btn(color: color)`). Normalize either spelling to `$name`.
      if name.len > 0 and name[0] == '$': name else: "$" & name

    proc expandMixin(call: Node): seq[Node] =
      ## Expand a mixin call into spliced body statements with args substituted.
      let callee = call[0].ident
      if not mixinTable.hasKey(callee):
        call.error("unknown mixin '" & callee & "'")
      let m = mixinTable[callee]
      let pnames = paramNames(m)
      var pm = initTable[string, Node]()
      # set of normalized parameter keys for membership checks
      var pkeys: seq[string]
      for pn in pnames:
        pkeys.add(paramKey(pn))
      var posIdx = 0
      for i in 1 ..< call.len:
        let a = call[i]
        if a.kind == nkColon and a[0].kind == nkIdent and paramKey(a[0].ident) in pkeys:
          pm[paramKey(a[0].ident)] = a[1] # named argument ($h = 5px or h = 5px)
        else:
          if posIdx >= pnames.len:
            call.error("too many arguments for mixin '" & callee & "'")
          pm[paramKey(pnames[posIdx])] = a
          inc posIdx
      for pn in pnames:
        if paramKey(pn) notin pm:
          let dv = paramDefault(m, pn)
          if dv != nil:
            pm[paramKey(pn)] = dv
          else:
            call.error("missing argument '" & pn & "' for mixin '" & callee & "'")
      for child in m[2].children:
        result.add(substStmt(child, pm))

    proc genSelector*(node: Node): Sym {.codegen, discardable.} =
      ## Generate bytecode for a CSS selector (class, id, or pseudo)
      assert node.kind in {nkClassSelector, nkIdSelector, nkPseudoSelector, nkElementSelector}, "Expected selector node"

      let selectorType =
        case node.kind
        of nkClassSelector: 0'u16
        of nkIdSelector: 1'u16
        of nkPseudoSelector: 2'u16
        of nkElementSelector: 3'u16
        else: 0'u16

      # Extract selector name from AST
      var selectorName: string
      case node[0].kind
      of nkIdent:
        selectorName = node[0].ident
      of nkBracket:
        for i, id in node[0].children:
          if id.kind == nkIdent:
            if i > 0: selectorName.add(",")
            selectorName.add(id.ident)
      else: node[0].error("Invalid selector name")

      # Compute full selector text (with parent nesting context via & substitution)
      let prefix =
        case selectorType
        of 0: "."
        of 1: "#"
        of 2: ":"
        else: ""
      let fullText = if nestingParent.len > 0:
        # include the kind prefix (.foo / #foo / :foo) so spliced mixin
        # selectors (nkClassSelector etc.) keep their sigil when combined
        applyParent(prefix & selectorName, nestingParent).join(", ")
      else:
        prefix & selectorName
      let hasParent = nestingParent.len > 0

      # Phase 0: expand mixin calls among body children
      var bodyChildren: seq[Node]
      for child in node[3].children:
        if child.kind == nkCall and child.len > 0 and child[0].kind == nkIdent:
          if mixinTable.hasKey(child[0].ident):
            for spilled in expandMixin(child):
              bodyChildren.add(spilled)
          else:
            # Not a known mixin — keep as-is (may be handled elsewhere);
            # warn so silent drops are visible.
            codegenWarn(gen.chunk.file, child.ln, child.col,
              "unknown mixin '" & child[0].ident & "' (mixin must be defined before use)")
            bodyChildren.add(child)
        else:
          bodyChildren.add(child)

      # Phase 0b: desugar nkCase → nkIf chains for VM codegen
      proc desugarCase(n: Node): Node =
        ## case X of 1: a of 2: b else: c → if X == 1: a elif X == 2: b else: c
        if n.kind != nkCase: return n
        let subject = n[0]
        var ifChildren: seq[Node]
        var i = 1
        while i < n.len:
          let branch = n[i]
          if branch.kind == nkBlock:
            # else branch
            ifChildren.add(branch)
            break
          elif branch.kind == nkOfBranch:
            let cond = ast.newInfix(ast.newIdent("=="),
              subject, branch[0])
            let blk = branch[1]
            ifChildren.add(cond)
            ifChildren.add(blk)
          inc i
        result = ast.newTree(nkIf, ifChildren)
        result.ln = n.ln; result.col = n.col
      for idx in 0 ..< bodyChildren.len:
        bodyChildren[idx] = desugarCase(bodyChildren[idx])

      # Phase 1: scan body to separate properties from nested children
      var
        nestedStmts: seq[Node]
        pendingComments: seq[Node]
        propCount = 0
      for child in bodyChildren:
        case child.kind
        of nkCssComment:
          pendingComments.add(child) # emitted before this rule's block
        of nkColon:
          inc propCount
        else:
          nestedStmts.add(child)

      # Detect nested selectors (Sass-style nesting)
      var hasNestedSelectors = false
      var hasNestedAtRule = false
      var hasControlFlow = false
      var hasDuplicate = false
      for s in nestedStmts:
        case s.kind
        of nkClassSelector, nkIdSelector, nkPseudoSelector, nkElementSelector:
          hasNestedSelectors = true
        of nkAtRule:
          hasNestedAtRule = true
        of nkIf, nkWhile, nkFor, nkCase:
          hasControlFlow = true
        else: discard
      # Check for duplicate property keys in this block
      var seenKeys: seq[string]
      for child in bodyChildren:
        if child.kind == nkColon:
          let k = if child[0].kind == nkIdent: child[0].ident
                  elif child[0].kind == nkString: child[0].stringVal
                  else: ""
          if k.len > 0 and k in seenKeys:
            hasDuplicate = true
          seenKeys.add(k)

      result = newType(ttyObject, name = node[0], impl = node)

      # Doc-block banners precede this rule in every emission path
      for cnode in pendingComments:
        gen.genStmt(cnode)

      # ── NESTING PATH: Sass-style ──────────────────────────────
      if hasNestedSelectors:
        # Emit parent properties as raw text (no stack pollution)
        if propCount > 0:
          gen.chunk.emit(opcPushS)
          gen.chunk.emit(gen.chunk.getString(fullText & "{"))
          gen.chunk.emit(opcEmitRaw)
          gen.chunk.emit(uint16(node.ln))
          gen.chunk.emit(uint16(node.col))
          # find last text-emitting child: a property keeps its trailing `;`
          # whenever declarations from following control flow can glue onto
          # it at runtime (the branch is VM-evaluated, so assume it emits).
          var lastEmitterIdx = -1
          for ci, child in bodyChildren:
            if child.kind == nkColon or child.kind in {nkIf, nkWhile, nkFor, nkCase}:
              lastEmitterIdx = ci
          for ci, child in bodyChildren:
            case child.kind
            of nkIf, nkWhile, nkFor, nkCase:
              # control flow inside the still-open block, in source order
              # (previously these fell through to the post-`}` loop and
              # dangled outside the rule)
              rawPropMode = true
              gen.genStmt(child)
              rawPropMode = false
            of nkColon:
              let key = child[0].ident
              let isLast = ci == lastEmitterIdx
              if valueNeedsVm(gen, child[1]):
                emitVmPropValue(gen, key, child[1], child, isLast)
                continue
              var val = nodeToCssString(child[1])
              val = resolvePropValue(key, val, child[1], child)
              if val.len > 0:
                let isVarRef = child[1].kind == nkIdent and child[1].ident.len > 0 and child[1].ident[0] == '$'
                if not isVarRef and child[1].kind in {nkIdent, nkInt, nkFloat, nkString, nkUnit, nkColor, nkExprList, nkCommaList, nkCall, nkPostfix}:
                  var validateCss = if child[1].kind == nkPostfix: resolvePropValue(key, nodeToCssString(child[1][1]), child[1][1], child) else: val
                  if strictCss:
                    try:
                      discard cssValidateProp(key, validateCss)
                    except CatchableError as e:
                      if key in ["box-shadow", "grid-template-columns", "content", "margin", "inherits"]:
                        discard
                      else:
                        child.error(e.msg)
                gen.chunk.emit(opcPushS)
                let css = if isLast: key & ":" & val
                          else: key & ":" & val & ";"
                gen.chunk.emit(gen.chunk.getString(css))
                gen.chunk.emit(opcEmitRaw)
                gen.chunk.emit(uint16(child.ln))
                gen.chunk.emit(uint16(child.col))
            else: discard # selectors, at-rules, comments: handled below
          gen.chunk.emit(opcPushS)
          gen.chunk.emit(gen.chunk.getString("}"))
          gen.chunk.emit(opcEmitRaw)
          gen.chunk.emit(uint16(0xFFFF))
          gen.chunk.emit(uint16(0))
        # Flatten nested selectors with this selector as parent context
        let savedParent = nestingParent
        nestingParent = fullText
        for stmt in nestedStmts:
          case stmt.kind
          of nkIf, nkWhile, nkFor, nkCase:
            discard # already emitted in place above, in source order
          else:
            gen.genStmt(stmt)
        nestingParent = savedParent
        return

      # ── RAW MODE: at-rules, duplicates, or control flow ───────
      # Control flow needs raw emission so VM-time conditions can decide
      # which declarations appear inside the rule block.
      if hasNestedAtRule or hasDuplicate or hasControlFlow:
        gen.chunk.emit(opcPushS)
        gen.chunk.emit(gen.chunk.getString(fullText & "{"))
        gen.chunk.emit(opcEmitRaw)
        gen.chunk.emit(uint16(node.ln))
        gen.chunk.emit(uint16(node.col))
        # Declarations & control flow in source order. A property keeps its
        # trailing `;` whenever following control flow (or a nested at-rule,
        # emitted inside the block below) can glue onto it at runtime.
        var lastEmitterIdx = -1
        for ci, child in bodyChildren:
          if child.kind == nkColon or child.kind in {nkIf, nkWhile, nkFor, nkCase}:
            lastEmitterIdx = ci
        for ci, child in bodyChildren:
          case child.kind
          of nkColon:
            let key = child[0].ident
            let isLast = ci == lastEmitterIdx and not hasNestedAtRule
            if valueNeedsVm(gen, child[1]):
              emitVmPropValue(gen, key, child[1], child, isLast)
              continue
            var val = nodeToCssString(child[1])
            val = resolvePropValue(key, val, child[1], child)
            if val.len > 0:
              let isVarRef = child[1].kind == nkIdent and child[1].ident.len > 0 and child[1].ident[0] == '$'
              if not isVarRef and child[1].kind in {nkIdent, nkInt, nkFloat, nkString, nkUnit, nkColor, nkExprList, nkCommaList, nkCall, nkPostfix}:
                var validateCss = if child[1].kind == nkPostfix: resolvePropValue(key, nodeToCssString(child[1][1]), child[1][1], child) else: val
                try:
                  discard cssValidateProp(key, validateCss)
                except CatchableError as e:
                  if key in ["box-shadow", "grid-template-columns", "content", "margin", "inherits"]:
                    discard
                  else:
                    child.error(e.msg)
              gen.chunk.emit(opcPushS)
              let css = if isLast: key & ":" & val
                        else: key & ":" & val & ";"
              gen.chunk.emit(gen.chunk.getString(css))
              gen.chunk.emit(opcEmitRaw)
              gen.chunk.emit(uint16(child.ln))
              gen.chunk.emit(uint16(child.col))
          of nkIf, nkWhile, nkFor, nkCase:
            rawPropMode = true
            gen.genStmt(child)
            rawPropMode = false
          else: discard
        # At-rules nest INSIDE the rule block
        for stmt in nestedStmts:
          if stmt.kind == nkAtRule:
            gen.genStmt(stmt)
        gen.chunk.emit(opcPushS)
        gen.chunk.emit(gen.chunk.getString("}"))
        gen.chunk.emit(opcEmitRaw)
        gen.chunk.emit(uint16(0xFFFF))
        gen.chunk.emit(uint16(0))
        # Spliced nested selectors flatten with this rule as parent
        let savedParent = nestingParent
        nestingParent = fullText
        for stmt in nestedStmts:
          if stmt.kind != nkAtRule:
            gen.genStmt(stmt)
        nestingParent = savedParent
        return

      # ── NORMAL PATH: flat selector ────────────────────────────
      gen.chunk.emit(opcPushSelector)
      if hasParent:
        # Nested child: fullText includes parent context, use element type (no VM prefix)
        gen.chunk.emit(gen.chunk.getString(fullText))
        gen.chunk.emit(3'u16)
      else:
        gen.chunk.emit(gen.chunk.getString(selectorName))
        gen.chunk.emit(selectorType)

      var keyIdxes: seq[uint16]
      for child in bodyChildren:
        if child.kind != nkColon:
          continue
        let prop = child
        let key =
          if prop[0].kind == nkIdent: prop[0].ident
          elif prop[0].kind == nkString: prop[0].stringVal
          else: prop[0].error("Invalid property key: " & $prop[0].kind); ""

        if result.objectFields.hasKey(key):
          hasDuplicate = true
        let isVarRef = prop[1].kind == nkIdent and prop[1].ident.len > 0 and prop[1].ident[0] == '$'

        # Validate CSS property value for literal values. bowdy calls evaluate
        # to typed values at runtime, so they take the dynamic path instead.
        if not isVarRef and not gen.isBroCall(prop[1]) and prop[1].kind in {nkIdent, nkInt, nkFloat, nkString, nkUnit, nkColor, nkExprList, nkCommaList, nkCall, nkPostfix}:
          var rawCss = nodeToCssString(prop[1])
          rawCss = resolvePropValue(key, rawCss, prop[1], prop)
          if rawCss.len > 0:
            var validateCss =
              if prop[1].kind == nkPostfix: resolvePropValue(key, nodeToCssString(prop[1][1]), prop[1][1], prop)
              else: rawCss
            if strictCss:
              try:
                discard cssValidateProp(key, validateCss)
              except CatchableError as e:
                if key in ["box-shadow", "grid-template-columns", "content", "margin", "inherits"]:
                  discard
                else:
                  prop.error(e.msg)
            let cssType = cssGetPropertySyntax(key)
            let expectedKind =
              if cssType != nil and cssType.kind == skType:
                cssTypeToKind(cssType.cssType)
              else:
                ttyKeyword
            keyIdxes.add(gen.chunk.getString(key))
            gen.chunk.emit(opcPushS)
            gen.chunk.emit(gen.chunk.getString(rawCss))
            let valTy = newType(expectedKind, name = prop[1])
            result.objectFields[key] = (
              id: result.objectFields.len,
              name: prop[0],
              ty: valTy,
              implVal: valTy
            )
            continue

        keyIdxes.add(gen.chunk.getString(key))
        let valTy =
          if isVarRef:
            let vt = gen.genExpr(prop[1])
            checkPropValueType(gen, key, vt, prop[1])
            vt
          else:
            case prop[1].kind
            of nkIdent:
              gen.chunk.emit(opcPushS)
              gen.chunk.emit(gen.chunk.getString(prop[1].ident))
              newType(ttyString, name = prop[1])
            of nkInt:
              gen.chunk.emit(opcPushS)
              gen.chunk.emit(gen.chunk.getString($prop[1].intVal))
              newType(ttyString, name = prop[1])
            of nkFloat:
              gen.chunk.emit(opcPushS)
              gen.chunk.emit(gen.chunk.getString(cssFloatStr(prop[1].floatVal)))
              newType(ttyString, name = prop[1])
            of nkString:
              gen.chunk.emit(opcPushS)
              gen.chunk.emit(gen.chunk.getString(prop[1].stringVal))
              newType(ttyString, name = prop[1])
            of nkCommaList, nkExprList:
              # multi-segment CSS values (`a, b, c`) render as verbatim text
              gen.chunk.emit(opcPushS)
              gen.chunk.emit(gen.chunk.getString(resolvePropValue(key, nodeToCssString(prop[1]), prop[1], prop)))
              newType(ttyString, name = prop[1])
            else:
              # bowdy calls (lighten, parseLength, ...), infix and other dynamic
              # expressions evaluate to strictly typed runtime values.
              let vt = gen.genExpr(prop[1])
              checkPropValueType(gen, key, vt, prop[1])
              vt
        result.objectFields[key] = (
          id: result.objectFields.len,
          name: prop[0],
          ty: valTy,
          implVal: valTy
        )

      gen.chunk.emit(opcConstrObj)
      gen.chunk.emit(uint16(result.objectFields.len))
      for kix in keyIdxes:
        gen.chunk.emit(kix)
      gen.chunk.emit(opcEmitCSS)
      gen.chunk.emit(uint16(propCount + 1))
      gen.chunk.emit(uint16(node.ln))
      gen.chunk.emit(uint16(node.col))
      for child in bodyChildren:
        if child.kind == nkColon:
          gen.chunk.emit(uint16(child.ln))
          gen.chunk.emit(uint16(child.col))

    proc genCssClass*(node: Node): Sym {.codegen.} =
      ## Generate bytecode for a CSS class selector
      result = gen.genSelector(node)

    proc genPseudoSelector*(node: Node): Sym {.codegen.} =
      ## Generate bytecode for a CSS pseudo-selector
      result = gen.genSelector(node)

    proc genCssProperty*(node: Node): Sym {.codegen.} =
      ## Generate bytecode for a CSS property
      assert node.kind == nkColon, "Expected nkColon node"

      if rawPropMode:
        # Inside control flow (if/for/while) within a rule body: emit the
        # declaration as raw text so VM-time conditions can include it.
        let key = node[0].ident
        let v = node[1]
        let isVarRef = v.kind == nkIdent and v.ident.len > 0 and v.ident[0] == '$'
        if isVarRef or gen.isBroCall(v) or v.kind notin {nkIdent, nkInt, nkFloat, nkString, nkUnit, nkColor, nkExprList, nkCommaList, nkCall, nkPostfix}:
          # VM-evaluated value: `key:` + value + `;` as three raw emissions
          gen.chunk.emit(opcPushS)
          gen.chunk.emit(gen.chunk.getString(key & ":"))
          gen.chunk.emit(opcEmitRaw)
          gen.chunk.emit(uint16(node.ln))
          gen.chunk.emit(uint16(node.col))
          checkPropValueType(gen, key, gen.genExpr(v), v)
          gen.chunk.emit(opcEmitRaw)
          gen.chunk.emit(uint16(0xFFFF))
          gen.chunk.emit(uint16(0))
          gen.chunk.emit(opcPushS)
          gen.chunk.emit(gen.chunk.getString(";"))
          gen.chunk.emit(opcEmitRaw)
          gen.chunk.emit(uint16(0xFFFF))
          gen.chunk.emit(uint16(0))
        else:
          var val = nodeToCssString(v)
          val = resolvePropValue(key, val, v, node)
          if key in ["box-shadow", "grid-template-columns", "content"]:
            # Warn-only props still get strict color validation via resolve
            # (invalid colors are hard errors); skip the generic validator.
            discard
          else:
            var validateCss = if v.kind == nkPostfix: resolvePropValue(key, nodeToCssString(v[1]), v[1], node) else: val
            if strictCss:
              try:
                discard cssValidateProp(key, validateCss)
              except CatchableError as e:
                if key in ["margin", "inherits"]:
                  discard
                else:
                  node.error(e.msg)
          gen.chunk.emit(opcPushS)
          gen.chunk.emit(gen.chunk.getString(key & ":" & val & ";"))
          gen.chunk.emit(opcEmitRaw)
          gen.chunk.emit(uint16(node.ln))
          gen.chunk.emit(uint16(node.col))
        return nil

      # Push the property name
      gen.chunk.emit(opcPushProperty)
      gen.chunk.emit(gen.chunk.getString(node[0].ident))

      # Push the property value
      discard gen.genExpr(node[1])

    proc genUnit*(node: Node): Sym {.codegen.} =
      ## Generate bytecode for a CSS unit (e.g., 16px) as a strictly typed
      ## runtime value. Known suffixes synthesize a call to the matching
      ## `parseLength/parseAngle/...` constructor so `4px` is a length, not
      ## a string. Unknown suffixes keep the legacy plain-string push.
      assert node.kind == nkUnit, "Expected nkUnit node"

      var size: string
      case node[0].kind
        of nkInt:
          size = $(node[0].intVal)
        of nkFloat:
          size = cssFloatStr(node[0].floatVal)
        else: node[0].error("Invalid unit value")

      let suffix = node[1].ident
      let unitStr = size & suffix
      let parseProc =
        case suffix
        of "px", "em", "rem", "%", "vh", "vw", "vmin", "vmax",
           "ch", "ex", "cm", "mm", "in", "pt", "pc":
          "parseLength"
        of "deg", "rad", "grad", "turn":
          "parseAngle"
        of "s", "ms":
          "parseTime"
        of "dpi", "dpcm", "dppx":
          "parseResolution"
        of "fr":
          "parseFlex"
        else:
          ""
      if parseProc.len == 0:
        gen.chunk.emit(opcPushValue)
        gen.chunk.emit(gen.chunk.getString(unitStr))
        result = gen.typeLookup("string")
        return
      if gen.lookup(ast.newIdent(parseProc), quiet = true) == nil:
        # Constructor not in scope (file imports only inherit system):
        # legacy plain-string push, output-identical.
        gen.chunk.emit(opcPushValue)
        gen.chunk.emit(gen.chunk.getString(unitStr))
        result = gen.typeLookup("string")
        return
      let callNode = ast.newCall(ast.newIdent(parseProc), ast.newStringLit(unitStr))
      callNode.ln = node.ln; callNode.col = node.col
      result = gen.genExpr(callNode)

    proc genColor*(node: Node): Sym {.codegen.} =
      ## Generate bytecode for a CSS color literal (nkColor holding the raw
      ## spelling) as a strictly typed color value via the `parseColor`
      ## constructor. Validated at compile time so typos fail fast.
      assert node.kind == nkColor, "Expected nkColor node"
      let raw = node[0].stringVal
      try:
        discard colormod.parseColor(raw)
      except CatchableError as e:
        node.error("Invalid color '" & raw & "': " & e.msg)
      if gen.lookup(ast.newIdent("parseColor"), quiet = true) == nil:
        # Constructor not in scope (file imports only inherit system):
        # legacy plain-string push, still normalized to hex for named colors.
        gen.chunk.emit(opcPushS)
        gen.chunk.emit(gen.chunk.getString(normalizeRawCssColors(raw)))
        result = gen.typeLookup("string")
        return
      let callNode = ast.newCall(ast.newIdent("parseColor"), ast.newStringLit(raw))
      callNode.ln = node.ln; callNode.col = node.col
      result = gen.genExpr(callNode)

    proc genExprList*(node: Node): Sym {.codegen.} =
      ## Generate bytecode for a list of expressions (e.g., multiple properties)
      assert node.kind == nkExprList, "Expected nkExprList node"
      var parts: seq[string]
      for child in node.children:
        case child.kind
        of nkIdent:
          let hx = tryNamedToHex(child.ident)
          parts.add(if hx.len > 0: hx else: child.ident)
        of nkInt: parts.add($child.intVal)
        of nkFloat: parts.add(cssFloatStr(child.floatVal))
        of nkString: parts.add(child.stringVal)
        of nkUnit:
          var v = if child[0].kind == nkInt: $child[0].intVal else: cssFloatStr(child[0].floatVal)
          parts.add(v & child[1].ident)
        of nkColor:
          let hx = tryNamedToHex(child[0].stringVal)
          parts.add(if hx.len > 0: hx else: child[0].stringVal.toLowerAscii())
        else: parts.add("<value>")
      let combined = parts.join(" ")
      gen.chunk.emit(opcPushS)
      gen.chunk.emit(gen.chunk.getString(combined))
      result = newType(ttyString, name = node)

    proc genAtRule*(node: Node): Sym {.codegen.} =
      assert node.kind == nkAtRule, "Expected nkAtRule node"
      let name = node[0].ident
      var prelude = ""
      if node[1].kind == nkString and node[1].stringVal.len > 0:
        prelude = " " & node[1].stringVal
      if node[2].children.len > 0:
        gen.chunk.emit(opcPushS)
        gen.chunk.emit(gen.chunk.getString("@" & name & prelude & "{"))
        gen.chunk.emit(opcEmitRaw)
        gen.chunk.emit(uint16(node.ln))
        gen.chunk.emit(uint16(node.col))
        # A property keeps its trailing `;` whenever a following sibling
        # (nested rule, control flow, ...) emits text into the same block.
        var lastEmitterIdx = -1
        for ci, child in node[2].children:
          if child.kind == nkColon or child.kind in {nkIf, nkWhile, nkFor, nkCase,
              nkClassSelector, nkIdSelector, nkPseudoSelector, nkElementSelector, nkAtRule}:
            lastEmitterIdx = ci
        for ci, child in node[2].children:
          if child.kind == nkColon:
            let key = child[0].ident
            let isLast = ci == lastEmitterIdx
            if valueNeedsVm(gen, child[1]):
              emitVmPropValue(gen, key, child[1], child, isLast)
              continue
            var val = nodeToCssString(child[1])
            val = resolvePropValue(key, val, child[1], child)
            let isVarRef = child[1].kind == nkIdent and child[1].ident.len > 0 and child[1].ident[0] == '$'
            if not isVarRef and child[1].kind in {nkIdent, nkInt, nkFloat, nkString, nkUnit, nkColor, nkExprList, nkCommaList, nkCall, nkPostfix}:
              var validateCss = if child[1].kind == nkPostfix: resolvePropValue(key, nodeToCssString(child[1][1]), child[1][1], child) else: val
              if strictCss:
                try:
                  discard cssValidateProp(key, validateCss)
                except CatchableError as e:
                  if key in ["box-shadow", "grid-template-columns", "content", "margin", "inherits"]:
                    discard
                  else:
                    child.error(e.msg)
            gen.chunk.emit(opcPushS)
            let css = if isLast: key & ":" & val
                      else: key & ":" & val & ";"
            gen.chunk.emit(gen.chunk.getString(css))
            gen.chunk.emit(opcEmitRaw)
            gen.chunk.emit(uint16(child.ln))
            gen.chunk.emit(uint16(child.col))
          else:
            gen.genStmt(child)
        gen.chunk.emit(opcPushS)
        gen.chunk.emit(gen.chunk.getString("}"))
        gen.chunk.emit(opcEmitRaw)
        gen.chunk.emit(uint16(0xFFFF)) # no source mapping for closing brace
        gen.chunk.emit(uint16(0))
      else:
        gen.chunk.emit(opcPushS)
        gen.chunk.emit(gen.chunk.getString("@" & name & prelude & ";"))
        gen.chunk.emit(opcEmitRaw)
        gen.chunk.emit(uint16(node.ln))
        gen.chunk.emit(uint16(node.col))

  extendCaseStmt "codeGenExpr":
    case node.kind
    of nkUnit: result = gen.genUnit(node)
    of nkColor: result = gen.genColor(node)
    of nkExprList: discard gen.genExprList(node)

  extendCaseStmt "codeGenStmt":
    case node.kind
    of nkClassSelector:
      discard gen.genCssClass(node)
    of nkPseudoSelector:
      discard gen.genPseudoSelector(node)
    of nkIdSelector:
      gen.genSelector(node)
    of nkElementSelector:
      gen.genSelector(node)
    of nkUnit:
      discard gen.genUnit(node)
    of nkColor:
      discard gen.genColor(node)
    of nkExprList:
      discard
    of nkColon:
      discard gen.genCssProperty(node)
    of nkAtRule:
      discard gen.genAtRule(node)
    of nkMixinDef:
      # Register the mixin for later expansion; definitions emit no CSS.
      if node[0].kind == nkIdent:
        mixinTable[node[0].ident] = node
    of nkCssComment:
      # Preserve doc-block banners (/*! */ and /** */) — the parser stores
      # the fully-wrapped CSS text, so emission is a verbatim raw chunk.
      # A trailing newline keeps the following rule readable in minified mode.
      if node.len > 0 and node[0].kind == nkString:
        gen.chunk.emit(opcPushS)
        gen.chunk.emit(gen.chunk.getString(node[0].stringVal & "\n"))
        gen.chunk.emit(opcEmitRaw)
        gen.chunk.emit(uint16(0xFFFF))
        gen.chunk.emit(uint16(0))
    of nkCase:
      # Desugar case/of → if/elif/else and re-dispatch
      let subject = node[0]
      var ifChildren: seq[Node]
      var i = 1
      while i < node.len:
        let branch = node[i]
        if branch.kind == nkBlock:
          ifChildren.add(branch)
          break
        elif branch.kind == nkOfBranch:
          let cond = ast.newInfix(ast.newIdent("=="), subject, branch[0])
          ifChildren.add(cond)
          ifChildren.add(branch[1])
        inc i
      gen.genStmt(ast.newTree(nkIf, ifChildren))

block extendVM:
  extendEnum Opcode:
    opcPushSelector  # Push a class selector onto the stack
    opcPushProperty       # Push a CSS property
    opcPushValue          # Push a CSS value
    opcEmitCSS            # Emit the final CSS
    opcEmitRaw            # Emit a raw string directly to the output

  injectSnippet "VanCodeVMBeforeMainLoop":
    # a Voodoo injected snippet to initialize the `result` variable and the
    # source map segment accumulator (read back by the CLI after interpret)
    result = initValue("")
    # JIT alias: native-compiled emit bridges append to the same output
    # buffer via this globals ref (the JIT cannot see `result` itself).
    vm.globals["__bro_output"] = result
    vm.globals["__bro_sourcemap_segments"] = initValue("")
    # pretty-printing state lives in vm.globals because extended case
    # branches cannot capture snippet locals. Depth tracks rule nesting so
    # raw and structured emissions interleave correctly.
    if not vm.globals.hasKey("__bro_pretty"):
      vm.globals["__bro_pretty"] = initValue(false)
    vm.globals["__bro_depth"] = initValue(0'i64)
    # Pretty-layout cursor state (avoids scanning the output buffer):
    # __bro_atline — cursor sits at a logical line start (a '\n' is already
    #                in place, possibly followed by pending auto-indent);
    # __bro_indw   — width of the pending auto-indent written on this line,
    #                so closing braces can truncate it without inspection.
    vm.globals["__bro_atline"] = initValue(true)
    vm.globals["__bro_indw"] = initValue(0'i64)

  extendCaseStmt "vmParseChunkCase":
    case oc:
    of opcPushSelector:
      # selector op has two args: string id, kind (uint16)
      let sid = readArg[uint16](pc)
      let kind = readArg[uint16](pc)
      addOp(oc, sid.int64, kind.int64, akString)
    of opcPushProperty, opcPushValue:
      let sid = readArg[uint16](pc)
      addOp(oc, sid.int64, 0, akString)
    of opcEmitRaw:
      # carries a source position (line, col) for source maps; 0xFFFF = no mapping
      let line = readArg[uint16](pc)
      let col = readArg[uint16](pc)
      addOp(oc, line.int64, col.int64, akInt)
    of opcEmitCSS:
      # carries a count followed by that many (line, col) position pairs,
      # stored in strKeys. First pair is the selector, rest are its properties.
      let cnt = readArg[uint16](pc).int
      addOp(oc, cnt.int64, 0, akInt)
      var poses: seq[uint16]
      for i in 0 ..< cnt:
        poses.add(readArg[uint16](pc))
        poses.add(readArg[uint16](pc))
      strKeys[^1] = poses

  extendCaseStmt "vmInterpretCase":
    case oc:
    of opcPushSelector:
      let className = co.getArg1Str(pcIdx, currentChunk)
      let kind = co.arg2[pcIdx].int
      stack.push(initValue(kind))
      stack.push(initValue(className))
    of opcPushValue:
      let valueStr = co.getArg1Str(pcIdx, currentChunk)
      stack.push(initValue(valueStr))
    of opcEmitRaw:
      # Shared implementation (also used by the JIT broEmitRaw bridge).
      broEmitRawImpl(vm, result, stack.pop(), co.getArg1Int(pcIdx),
        co.arg2[pcIdx].int, currentChunk.file)
    of opcEmitCSS:
      # Shared implementation (also used by the JIT broEmitCSS bridge).
      # Stack (bottom..top): kind int, selector string, props object.
      let cssProps = stack.pop()
      let cssSel = stack.pop()
      let cssKind = stack.pop()
      broEmitCSSImpl(vm, result, cssKind, cssSel, cssProps,
        co.strKeys[pcIdx], currentChunk.file)

block extendJitProcs:
  # Shared emit implementations: the interpreter branches below call them,
  # and the JIT emit bridges (bowdy/engine/jitbridge.nim) call the same
  # procs, so native and interpreted emission cannot drift apart.

  extendModule "vancode" / "interpreter" / "jit" / "host_emit.nim":
    proc emitCssMeta*(cached: CachedOps, pc: int, ch: Chunk): int32 =
      ## Pack an EmitCSS site: position pairs plus chunk file.
      var poses: seq[int64] = @[]
      for p in cached.strKeys[pc]:
        poses.add(p.int64)
      registerJitHostMeta(JitHostMeta(ints: poses, strs: @[ch.file]))

  extendProc "interpreter/vm.nim":
    proc broEmitRawImpl*(vm: Vm, outBuf: Value, sv: Value, sl, sc: int, file: string) =
      if sl != 0xFFFF: # not a "no mapping" sentinel
        vm.globals["__bro_sourcemap_segments"].stringVal[].add(
          $outBuf.stringVal[].len & "\x03" & $sl & "\x03" & $sc & "\x03" & file & "\x02")
      # Type-tolerant pop: raw emissions may carry VM-evaluated values
      # (ints, floats, bools) from control-flow property values.
      let rawStr =
        case sv.typeId
        of tyString: sv.stringVal[]
        of tyInt: $sv.intVal
        of tyFloat:
          var fs = $sv.floatVal
          let fn = fs.len
          if fn > 2 and fs[fn - 2] == '.' and fs[fn - 1] == '0':
            fs.setLen(fn - 2)
          fs
        of tyBool: $sv.boolVal
        else:
          # Strict CSS values (length/angle/time/color/...) are foreign
          # Objects whose display spelling is cached on the foreign tag
          # at construction (see stdlib/cssvalues.initCssPayload).
          if sv.objectVal != nil and sv.objectVal.isForeign and
              sv.objectVal.foreign.tag.len > 0:
            sv.objectVal.foreign.tag
          else: ""
      let prettyNow = vm.globals["__bro_pretty"].boolVal
      let depthNow = vm.globals["__bro_depth"].intVal.int
      # Strip trailing ';' before '}' — O(1) single-char check
      if rawStr == "}" and outBuf.stringVal[].len > 0 and outBuf.stringVal[^1] == ';':
        outBuf.stringVal[].setLen(outBuf.stringVal[].len - 1)
      if not prettyNow or rawStr.len == 0:
        outBuf.stringVal[].add(rawStr)
      elif rawStr == "}":
        # closing brace: drop pending auto-indent (its leading '\n' survives),
        # or open a fresh line when the previous chunk left none
        let indW = vm.globals["__bro_indw"].intVal.int
        if indW > 0:
          outBuf.stringVal[].setLen(outBuf.stringVal[].len - indW)
        else:
          outBuf.stringVal[].add('\n')
        vm.globals["__bro_depth"] = initValue((depthNow - 1).int64)
        for _ in 1 .. (depthNow - 1) * 2:
          outBuf.stringVal[].add(' ')
        outBuf.stringVal[].add(rawStr)
        outBuf.stringVal[].add('\n')
        for _ in 1 .. (depthNow - 1) * 2:
          outBuf.stringVal[].add(' ')
        vm.globals["__bro_indw"] = initValue(((depthNow - 1) * 2).int64)
        vm.globals["__bro_atline"] = initValue(true)
      elif rawStr[^1] == '{':
        # opener: header line, then descend
        if not vm.globals["__bro_atline"].boolVal:
          outBuf.stringVal[].add('\n')
          for _ in 1 .. depthNow * 2:
            outBuf.stringVal[].add(' ')
          vm.globals["__bro_indw"] = initValue((depthNow * 2).int64)
        outBuf.stringVal[].add(rawStr)
        vm.globals["__bro_indw"] = initValue(0'i64) # header content landed
        vm.globals["__bro_depth"] = initValue((depthNow + 1).int64)
        outBuf.stringVal[].add('\n')
        for _ in 1 .. (depthNow + 1) * 2:
          outBuf.stringVal[].add(' ')
        vm.globals["__bro_indw"] = initValue(((depthNow + 1) * 2).int64)
        vm.globals["__bro_atline"] = initValue(true)
      else:
        # declaration / statement chunk — own line at current depth
        if not vm.globals["__bro_atline"].boolVal:
          outBuf.stringVal[].add('\n')
          for _ in 1 .. depthNow * 2:
            outBuf.stringVal[].add(' ')
        outBuf.stringVal[].add(rawStr)
        vm.globals["__bro_indw"] = initValue(0'i64) # content landed
        if rawStr[^1] != '\n':
          # self-terminated chunks (doc-block banners) keep their own newline
          outBuf.stringVal[].add('\n')
        for _ in 1 .. depthNow * 2:
          outBuf.stringVal[].add(' ')
        vm.globals["__bro_indw"] = initValue((depthNow * 2).int64)
        vm.globals["__bro_atline"] = initValue(true)

    proc broEmitCSSImpl*(vm: Vm, outBuf: Value, kindV, selV, propsV: Value,
        poses: seq[uint16], file: string) =
      var pi = 0
      # selector mapping (first position pair)
      if poses.len >= 2:
        vm.globals["__bro_sourcemap_segments"].stringVal[].add(
          $outBuf.stringVal[].len & "\x03" & $poses[pi] & "\x03" & $poses[pi + 1] & "\x03" & file & "\x02")
        pi += 2
      let props = propsV.objectVal
      let keys = props.keys
      let selectorName = selV.stringVal[]
      let kind = kindV.intVal
      let prefix =
        case kind
        of 0: "." # class selector
        of 1: "#" # id selector
        of 2: ":" # pseudo-selector
        else: ""
      outBuf.stringVal[].add(prefix & selectorName & "{")
      let prettyNow = vm.globals["__bro_pretty"].boolVal
      if prettyNow:
        # header content landed — clear pending indent before descending
        vm.globals["__bro_indw"] = initValue(0'i64)
        # structured rule: descend for declarations, matching raw-path layout
        vm.globals["__bro_depth"] = initValue((vm.globals["__bro_depth"].intVal + 1).int64)
        outBuf.stringVal[].add('\n')
        for _ in 1 .. vm.globals["__bro_depth"].intVal.int * 2:
          outBuf.stringVal[].add(' ')
        vm.globals["__bro_indw"] = initValue((vm.globals["__bro_depth"].intVal.int * 2).int64)
        vm.globals["__bro_atline"] = initValue(true)
      for i, key in keys:
        # per-property mapping
        if pi + 1 < poses.len:
          vm.globals["__bro_sourcemap_segments"].stringVal[].add(
            $outBuf.stringVal[].len & "\x03" & $poses[pi] & "\x03" & $poses[pi + 1] & "\x03" & file & "\x02")
          pi += 2
        let val =
          case props.fields[i].typeId
          of tyString: props.fields[i].refVal.stringVal[]
          of tyInt:
            $(props.fields[i].intVal)
          of tyFloat:
            var fs = $(props.fields[i].floatVal)
            let fn = fs.len
            if fn > 2 and fs[fn - 2] == '.' and fs[fn - 1] == '0':
              fs.setLen(fn - 2) # integral float: "1000.0" → "1000"
            fs
          of tyBool:
            $(props.fields[i].boolVal)
          else:
            # Strict CSS values render via the display spelling cached on
            # the foreign tag at construction time.
            let rv = props.fields[i].refVal
            if rv != nil and rv.objectVal != nil and rv.objectVal.isForeign and
                rv.objectVal.foreign.tag.len > 0:
              rv.objectVal.foreign.tag
            else: "<value>"

        if prettyNow and i > 0:
          # first declaration sits on the opener's fresh line; rest get their own
          outBuf.stringVal[].add('\n')
          for _ in 1 .. vm.globals["__bro_depth"].intVal.int * 2:
            outBuf.stringVal[].add(' ')
        outBuf.stringVal[].add(key & ":" & val)
        if i < keys.len - 1:
          outBuf.stringVal[].add(";")
        if prettyNow:
          vm.globals["__bro_atline"] = initValue(false)
          vm.globals["__bro_indw"] = initValue(0'i64) # declaration content landed
      if prettyNow:
        # drop pending auto-indent, dedent, place closing brace at parent level
        let indW = vm.globals["__bro_indw"].intVal.int
        if indW > 0:
          outBuf.stringVal[].setLen(outBuf.stringVal[].len - indW)
        if not vm.globals["__bro_atline"].boolVal:
          outBuf.stringVal[].add('\n')
        elif indW > 0:
          discard # truncated indent left the '\n' from the opener in place
        vm.globals["__bro_depth"] = initValue((vm.globals["__bro_depth"].intVal - 1).int64)
        for _ in 1 .. vm.globals["__bro_depth"].intVal.int * 2:
          outBuf.stringVal[].add(' ')
      outBuf.stringVal[].add("}")
      if prettyNow:
        # leave the cursor at a fresh line for the next sibling rule
        outBuf.stringVal[].add('\n')
        for _ in 1 .. vm.globals["__bro_depth"].intVal.int * 2:
          outBuf.stringVal[].add(' ')
        vm.globals["__bro_indw"] = initValue((vm.globals["__bro_depth"].intVal.int * 2).int64)
        vm.globals["__bro_atline"] = initValue(true)

block extendJit:
  # JIT admission + emission for bowdy's opcodes and the string/object
  # plumbing its chunks use. Injected branches resolve names at the vancode
  # expansion site, so emission goes through vancode-owned host_emit
  # one-liners; bowdy behavior arrives as registered host bridges.
  extendCaseStmt "vmJitDynasmAllowCase":
    case oc:
    of opcPushS, opcPushF, opcPushG, opcPopG, opcConcatStr,
       opcConstrArray, opcConstrObj,
       opcPushSelector, opcPushProperty, opcPushValue, opcEmitCSS, opcEmitRaw:
      result = true

  extendCaseStmt "vmJitDynasmEmitCase":
    case oc:
    of opcPushS, opcPushValue:
      if not emitConstPush(addr d, cached, pc, theProc.chunk, "broPushConst"):
        return nil
    of opcPushF:
      if not emitFloatPush(addr d, cached, pc, theProc.chunk, "broPushFloat"):
        return nil
    of opcPushG:
      if not emitGlobalPush(addr d, cached, pc, theProc.chunk, "broPushG"):
        return nil
    of opcPopG:
      if not emitGlobalPop(addr d, cached, pc, theProc.chunk, "broPopG"):
        return nil
    of opcConcatStr:
      let concatFn = findJitHostBridge("broConcatStr")
      if concatFn == nil: return nil
      vancode_bridge_2(addr d, concatFn)
    of opcConstrArray:
      if not emitHostCallValue(addr d, cached.getArg1Int(pc), "broConstrArray", 0):
        return nil
    of opcConstrObj:
      if not emitHostCallValue(addr d, cached.getArg1Int(pc), "broConstrObj",
          constrKeysMeta(cached, pc, theProc.chunk)):
        return nil
    of opcPushSelector:
      # interpreter pushes kind first, name on top — same order here
      vancode_push_i(addr d, cached.arg2[pc].cint)
      if not emitConstPush(addr d, cached, pc, theProc.chunk, "broPushConst"):
        return nil
    of opcPushProperty:
      discard # runtime no-op, mirrors the interpreter fallthrough
    of opcEmitRaw:
      if not emitHostCallVoid(addr d, 1, "broEmitRaw",
          emitRawMeta(cached, pc, theProc.chunk)):
        return nil
    of opcEmitCSS:
      if not emitHostCallVoid(addr d, 3, "broEmitCSS",
          emitCssMeta(cached, pc, theProc.chunk)):
        return nil

  extendCaseStmt "vmJitTraceEmitCase":
    # Dormant until the trace recorder admits host ops (it aborts on
    # anything outside arithmetic/locals/jumps, so no trace can contain
    # these yet). `opcPushG/PopG` are deliberately absent: the backend's
    # own `discard` branches claim those labels.
    case oc:
    of opcPushS, opcPushValue:
      if not emitConstPush(addr d, cached, pc, cast[Chunk](trace.chunk), "broPushConst"):
        return nil
    of opcPushF:
      if not emitFloatPush(addr d, cached, pc, cast[Chunk](trace.chunk), "broPushFloat"):
        return nil
    of opcConcatStr:
      let concatFn = findJitHostBridge("broConcatStr")
      if concatFn == nil: return nil
      vancode_bridge_2(addr d, concatFn)
    of opcConstrArray:
      if not emitHostCallValue(addr d, cached.getArg1Int(pc), "broConstrArray", 0):
        return nil
    of opcConstrObj:
      if not emitHostCallValue(addr d, cached.getArg1Int(pc), "broConstrObj",
          constrKeysMeta(cached, pc, cast[Chunk](trace.chunk))):
        return nil
    of opcPushSelector:
      vancode_push_i(addr d, cached.arg2[pc].cint)
      if not emitConstPush(addr d, cached, pc, cast[Chunk](trace.chunk), "broPushConst"):
        return nil
    of opcPushProperty:
      discard
    of opcEmitRaw:
      if not emitHostCallVoid(addr d, 1, "broEmitRaw",
          emitRawMeta(cached, pc, cast[Chunk](trace.chunk))):
        return nil
    of opcEmitCSS:
      if not emitHostCallVoid(addr d, 3, "broEmitCSS",
          emitCssMeta(cached, pc, cast[Chunk](trace.chunk))):
        return nil
