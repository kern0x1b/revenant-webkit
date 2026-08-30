#include <stdio.h>

__attribute__((constructor))
static void probe(void)
{
    FILE *f = fopen("/tmp/probe-result.log", "a");
    if (f) {
        fprintf(f, "probe constructor ran\n");
        fclose(f);
    }
}
