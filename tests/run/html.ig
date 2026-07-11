// html.ig — locks std/html: Markdown blocks/spans → HTML, list grouping, tables, code, and escaping.
import "std/html" as html

fn main() -> int {
    let src = "# Title\n\nA **bold** and *italic* line with `code` and a [link](/x).\n\n- one\n- two\n\n> quoted\n\n| a | b |\n|---|---|\n| 1 | 2 |"
    println(html.render_markdown(src))
    println(html.escape("<a href=\"x\">& '\"</a>"))
    return 0
}
