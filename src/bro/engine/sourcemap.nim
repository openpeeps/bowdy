# A super fast stylesheet language for cool kids
#
# (c) 2026 George Lemon | LGPL License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/bowdy
#
# Source map generation for the BASS -> CSS pipeline.
# Produces a v3 source map (https://sourcemaps.info/spec.html).

import std/[strutils, tables]

type
  MapSegment* = object
    ## A single generated->original mapping.
    genLine*: int   # generated line (0 for minified single-line output)
    genCol*: int    # generated column (byte offset into the CSS output)
    file*: string   # source file path
    line*: int      # source line (0-based)
    col*: int       # source column (0-based)

  SourceInfo* = object
    ## Accumulator for mappings + optional embedded source contents.
    segments*: seq[MapSegment]
    contents*: Table[string, string]

  SourceMap* = object
    ## A v3 source map ready to be serialized to JSON.
    version*: int
    file*: string
    sources*: seq[string]
    sourcesContent*: seq[string]
    names*: seq[string]
    mappings*: string

proc initSourceInfo*: SourceInfo =
  result = SourceInfo(contents: initTable[string, string]())

proc addSegment*(info: var SourceInfo, genLine, genCol: int, file: string, line, col: int) =
  ## Record a single generated->original mapping.
  info.segments.add(MapSegment(
    genLine: genLine, genCol: genCol, file: file, line: line, col: col))

proc addContent*(info: var SourceInfo, file, content: string) =
  ## Attach the raw source content for `file` so it can be embedded
  ## into `sourcesContent`.
  info.contents[file] = content

# base64_VLQ
proc encode*(values: seq[int]): string =
  ## Encodes a series of integers into a VLQ base64 encoded string
  # References:
  #   - https://www.lucidchart.com/techblog/2019/08/22/decode-encoding-base64-vlqs-source-maps/
  const
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    shift = 5
    continueBit = 1 shl 5
    mask = continueBit - 1
  for val in values:
    # Sign is stored in first bit
    var newVal = abs(val) shl 1
    if val < 0:
      newVal = newVal or 1
    # Now comes the variable length part
    while true:
      var masked = newVal and mask
      newVal = newVal shr shift
      if newVal > 0:
        masked = masked or continueBit
      result &= alphabet[masked]
      if newVal == 0:
        break

proc toSourceMap*(info: SourceInfo, outputFile: string): SourceMap =
  ## Convert the accumulated mappings into a v3 SourceMap object.
  result.version = 3
  result.file = outputFile

  # Deduplicate source files in order of first appearance
  var srcIdx: Table[string, int]
  for seg in info.segments:
    if not srcIdx.hasKey(seg.file):
      srcIdx[seg.file] = srcIdx.len
      result.sources.add(seg.file)
      result.sourcesContent.add(info.contents.getOrDefault(seg.file, ""))

  var
    prevGenLine = -1
    prevGenCol = 0
    prevSrc = 0
    prevLine = 0
    prevCol = 0
  for seg in info.segments:
    if seg.genLine != prevGenLine:
      if prevGenLine != -1:
        result.mappings.add(";")
      prevGenLine = seg.genLine
      prevGenCol = 0
    else:
      result.mappings.add(",")
    var vals = @[
      seg.genCol - prevGenCol,
      srcIdx[seg.file] - prevSrc,
      seg.line - prevLine,
      seg.col - prevCol
    ]
    result.mappings.add(encode(vals))
    prevGenCol = seg.genCol
    prevSrc = srcIdx[seg.file]
    prevLine = seg.line
    prevCol = seg.col
