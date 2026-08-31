/*
 * Who is holding the memory, not who asked for it.
 *
 * The first version of this counted every large allocation and named the JS
 * parser's arena as the biggest, at 196 MB - which was true and misleading: an
 * arena that is allocated and freed a thousand times holds nothing. What a
 * decision needs is live bytes, so each block is remembered by address and
 * subtracted again when it is freed.
 *
 * Off unless /tmp/native-mem-probe exists. When it is on, every allocation at or
 * above the threshold costs one hash insert, and every free one lookup.
 */

#include <dlfcn.h>
#include <malloc/malloc.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define SITE_COUNT 2048
#define BLOCK_COUNT 65536

struct Site {
    const void *caller;
    size_t liveBytes;
    size_t everBytes;
    unsigned liveBlocks;
};

/* Open addressing, fixed size, no allocation of its own: this runs inside the
 * allocator and must not call it. A block that does not fit is not tracked,
 * which loses a little accuracy and never loses correctness. */
struct Block {
    const void *address;
    size_t size;
    unsigned site;
};

static struct Site g_sites[SITE_COUNT];
static struct Block g_blocks[BLOCK_COUNT];
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static size_t g_threshold = 4096;
static int g_enabled = -1;

static int probeEnabled(void)
{
    if (g_enabled < 0) {
        g_enabled = access("/tmp/native-mem-probe", F_OK) == 0 ? 1 : 0;
        const char *fromEnvironment = getenv("NATIVE_MEM_PROBE_THRESHOLD");
        if (fromEnvironment)
            g_threshold = (size_t)strtoul(fromEnvironment, NULL, 10);
    }
    return g_enabled;
}

static unsigned siteFor(const void *caller)
{
    unsigned slot = (unsigned)(((uintptr_t)caller >> 2) * 2654435761u) % SITE_COUNT;
    for (unsigned probe = 0; probe < 8; probe++) {
        struct Site *site = &g_sites[(slot + probe) % SITE_COUNT];
        if (!site->caller || site->caller == caller) {
            site->caller = caller;
            return (slot + probe) % SITE_COUNT;
        }
    }
    return slot;
}

static void remember(const void *address, size_t size, const void *caller)
{
    unsigned slot = (unsigned)(((uintptr_t)address >> 4) * 2654435761u) % BLOCK_COUNT;
    for (unsigned probe = 0; probe < 16; probe++) {
        struct Block *block = &g_blocks[(slot + probe) % BLOCK_COUNT];
        if (block->address)
            continue;
        unsigned site = siteFor(caller);
        block->address = address;
        block->size = size;
        block->site = site;
        g_sites[site].liveBytes += size;
        g_sites[site].everBytes += size;
        g_sites[site].liveBlocks++;
        return;
    }
}

static void forget(const void *address)
{
    unsigned slot = (unsigned)(((uintptr_t)address >> 4) * 2654435761u) % BLOCK_COUNT;
    for (unsigned probe = 0; probe < 16; probe++) {
        struct Block *block = &g_blocks[(slot + probe) % BLOCK_COUNT];
        if (block->address != address)
            continue;
        struct Site *site = &g_sites[block->site];
        if (site->liveBytes >= block->size)
            site->liveBytes -= block->size;
        if (site->liveBlocks)
            site->liveBlocks--;
        block->address = NULL;
        block->size = 0;
        return;
    }
}

static void writeReport(void)
{
    FILE *log = fopen("/tmp/native-mem-probe.log", "w");
    if (!log)
        return;
    for (unsigned i = 0; i < SITE_COUNT; i++) {
        if (!g_sites[i].caller || g_sites[i].liveBytes < 262144)
            continue;
        Dl_info info;
        const char *image = "?";
        unsigned long offset = 0;
        if (dladdr(g_sites[i].caller, &info) && info.dli_fname) {
            const char *slash = strrchr(info.dli_fname, '/');
            image = slash ? slash + 1 : info.dli_fname;
            offset = (unsigned long)((const char *)g_sites[i].caller - (const char *)info.dli_fbase);
        }
        fprintf(log, "%8.2f MB live  %6u blocks  %8.1f MB ever  %s+0x%lx\n",
            g_sites[i].liveBytes / 1048576.0, g_sites[i].liveBlocks,
            g_sites[i].everBytes / 1048576.0, image, offset);
    }
    fclose(log);
}

static const void *interestingCaller(const void *immediate, const void *above)
{
    return above ? above : immediate;
}

static void track(const void *address, size_t size, const void *caller)
{
    static unsigned sinceReport;
    pthread_mutex_lock(&g_lock);
    remember(address, size, caller);
    int due = ++sinceReport >= 2048;
    if (due)
        sinceReport = 0;
    pthread_mutex_unlock(&g_lock);
    if (due)
        writeReport();
}

extern void *ourMalloc(size_t size)
{
    void *block = malloc(size);
    if (probeEnabled() && size >= g_threshold && block)
        track(block, size, interestingCaller(__builtin_return_address(0), __builtin_return_address(1)));
    return block;
}

extern void *ourCalloc(size_t count, size_t size)
{
    void *block = calloc(count, size);
    if (probeEnabled() && count * size >= g_threshold && block)
        track(block, count * size, interestingCaller(__builtin_return_address(0), __builtin_return_address(1)));
    return block;
}

extern void *ourRealloc(void *existing, size_t size)
{
    if (probeEnabled() && existing) {
        pthread_mutex_lock(&g_lock);
        forget(existing);
        pthread_mutex_unlock(&g_lock);
    }
    void *block = realloc(existing, size);
    if (probeEnabled() && size >= g_threshold && block)
        track(block, size, interestingCaller(__builtin_return_address(0), __builtin_return_address(1)));
    return block;
}

extern void ourFree(void *block)
{
    if (probeEnabled() && block) {
        pthread_mutex_lock(&g_lock);
        forget(block);
        pthread_mutex_unlock(&g_lock);
    }
    free(block);
}

__attribute__((used)) static struct { const void *replacement; const void *original; }
interpose_malloc __attribute__((section("__DATA,__interpose"))) = { (const void *)&ourMalloc, (const void *)&malloc };
__attribute__((used)) static struct { const void *replacement; const void *original; }
interpose_calloc __attribute__((section("__DATA,__interpose"))) = { (const void *)&ourCalloc, (const void *)&calloc };
__attribute__((used)) static struct { const void *replacement; const void *original; }
interpose_realloc __attribute__((section("__DATA,__interpose"))) = { (const void *)&ourRealloc, (const void *)&realloc };
__attribute__((used)) static struct { const void *replacement; const void *original; }
interpose_free __attribute__((section("__DATA,__interpose"))) = { (const void *)&ourFree, (const void *)&free };
