// string_escape.em (trace) — locks JSON-string escaping on the execution tape (OFI-107).
// The string value carries a double-quote, a newline, a tab and a backslash; the tape's
// json_write_string must escape every one so the line stays valid JSON Lines and no raw
// control or ANSI byte can leak into the agent-facing channel an LLM consumes.
fn main() -> string {
    return "a\"b\nc\td\\e"
}
