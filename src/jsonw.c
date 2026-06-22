#include "jsonw.h"

void json_write_string(FILE *out, const char *s) {
    if (s == NULL) {
        fputs("null", out);
        return;
    }
    fputc('"', out);
    for (const char *p = s; *p != '\0'; p++) {
        unsigned char c = (unsigned char)*p;
        switch (c) {
            case '"':  fputs("\\\"", out); break;
            case '\\': fputs("\\\\", out); break;
            case '\n': fputs("\\n", out);  break;
            case '\r': fputs("\\r", out);  break;
            case '\t': fputs("\\t", out);  break;
            default:
                if (c < 0x20) {
                    fprintf(out, "\\u%04x", c);
                } else {
                    fputc((int)c, out);
                }
        }
    }
    fputc('"', out);
}
