import ../src/bowdy/engine/parser
import pkg/openparser/css

let css1 = parseCss("*{color:red}")
echo "parsed OK: ", css1.nodes.len, " nodes"

let css2 = parseCss("""*{x:"a\b"}""")
echo "parsed OK: ", css2.nodes.len, " nodes"
