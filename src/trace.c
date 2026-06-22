#include "trace.h"
#include "jsonw.h"

#include <stdio.h>

// write_stack_value emits one stack slot as a JSON value. Strings go through the
// shared escaper (json_write_string) so a quote, newline, or control byte in the
// value can never produce invalid JSON Lines or inject control/ANSI bytes into a
// channel an LLM consumes (the bug this path used to have: a bare %s, OFI-107).
static void write_stack_value(FILE *out, Value v) {
    if (IS_INT(v)) {
        fprintf(out, "%lld", (long long)AS_INT(v));
    } else if (IS_FLOAT(v)) {
        fprintf(out, "%g", AS_FLOAT(v));
    } else if (IS_STRING(v)) {
        json_write_string(out, AS_CSTRING(v));
    } else {
        // A heap value (struct/enum instance): show its kind, not its address.
        fputs("\"<obj>\"", out);
    }
}




// json_lines_on_event writes one event as a single JSON object, e.g.
//   {"ip":4,"op":"ADD","line":3,"stack":[1,2]}
// One object per line (JSON Lines) so a consumer can stream the tape. Every string
// field is escaped through json_write_string — names, the event detail, and string
// stack values alike — so untrusted program data can't break the line or inject.
static void json_lines_on_event(void *ctx, const TraceEvent *event) {
    FILE *out = (FILE *)ctx;
    // A semantic event (e.g. a contract violation) is a distinct, richer record so a
    // tool can spot it without scanning every step. Ordinary steps keep their shape,
    // so existing tapes are unchanged.
    if (event->event != NULL) {
        fputs("{\"event\":", out);
        json_write_string(out, event->event);
        fputs(",\"fn\":", out);
        json_write_string(out, event->fn);
        fprintf(out, ",\"line\":%d,\"detail\":", event->line);
        json_write_string(out, event->detail != NULL ? event->detail : "");
        fputs(",\"stack\":[", out);
        for (size_t i = 0; i < event->stack_count; i++) {
            if (i > 0) {
                fputc(',', out);
            }
            write_stack_value(out, event->stack[i]);
        }
        fputs("]}\n", out);
        return;
    }
    fputs("{\"fn\":", out);
    json_write_string(out, event->fn);
    fprintf(out, ",\"ip\":%zu,\"op\":", event->ip);
    json_write_string(out, opcode_name(event->op));
    fprintf(out, ",\"line\":%d,\"stack\":[", event->line);
    for (size_t i = 0; i < event->stack_count; i++) {
        if (i > 0) {
            fputc(',', out);
        }
        write_stack_value(out, event->stack[i]);
    }
    fputs("]}\n", out);
}





Tracer tracer_json_lines(void *out) {
    Tracer tracer;
    tracer.on_event = json_lines_on_event;
    tracer.ctx      = out;
    return tracer;
}
