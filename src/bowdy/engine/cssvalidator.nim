# A super fast stylesheet language for cool kids!
#
# (c) 2026 George Lemon | LGPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/bowdy

import pkg/openparser/css

type
  CssValidatorError* = object of CatchableError

  CssValidator* = object
    data*: CssData

proc initCssValidator*: CssValidator =
  result.data = loadCssData()

proc rawValueToCssValues(raw: string): seq[CssValue] =
  let fakeCss = "*{x:" & raw & "}"
  let style = parseCss(fakeCss)
  if style.nodes.len > 0 and style.nodes[0].kind == cssRuleSet:
    if style.nodes[0].declarations.len > 0:
      result = style.nodes[0].declarations[0].valueComponents

proc validateCssProp*(v: CssValidator, propName: string, rawValue: string): string =
  ## Validate a CSS property value against the property's syntax.
  ## Returns the resolved CSS type name.
  ## Raises CssValidatorError on validation failure.
  let values = rawValueToCssValues(rawValue)
  let res = validate(v.data, propName, values)
  if not res.valid:
    var msg = propName & ": " & res.errors[0].message
    raise newException(CssValidatorError, msg)
  let syn = getPropertySyntax(v.data, propName)
  if syn == nil: return "keyword"
  case syn.kind
  of skType: result = syn.cssType
  else: result = "keyword"
