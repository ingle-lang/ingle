#ifndef EMBER_JSONW_H
#define EMBER_JSONW_H

#include <stdio.h>

// The single JSON-string escaper for the whole compiler (diagnostics, the tape,
// and Faults), so the three can never drift. Writes `s` to `out` as a quoted,
// escaped JSON string literal — or the literal `null` when s == NULL. Escapes the
// JSON-significant bytes (" and \) and every C0 control byte (\n \r \t, and \u00xx
// for the rest), so no raw control byte or ANSI escape sequence can leak into a
// JSON-Lines channel that an LLM or tool parses. That escaping is also the
// prompt-injection guard for the agent-facing render (MANIFESTO — LLM-first).
void json_write_string(FILE *out, const char *s);

#endif // EMBER_JSONW_H
