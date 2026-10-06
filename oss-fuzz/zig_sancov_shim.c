/* Registers Zig's inline-8bit-counter coverage sections with libFuzzer.
 *
 * Zig 0.16 emits `__sancov_cntrs` increments for `-ffuzz` objects but no
 * `__sanitizer_cov_8bit_counters_init` calls, and libFuzzer only observes
 * counters registered through that hook. This constructor runs at startup
 * before the fuzzer loop and hands the linked sections to the engine.
 * Trace-pc-guard callbacks are not an option: current libFuzzer runtimes
 * reject them outright.
 */
#include <stddef.h>

extern unsigned char __start___sancov_cntrs[] __attribute__((weak));
extern unsigned char __stop___sancov_cntrs[] __attribute__((weak));
extern void __sanitizer_cov_8bit_counters_init(unsigned char *start,
                                               unsigned char *stop);

__attribute__((constructor)) static void uz_register_zig_sancov(void)
{
    if (__start___sancov_cntrs == NULL || __start___sancov_cntrs == __stop___sancov_cntrs)
        return;
    __sanitizer_cov_8bit_counters_init(__start___sancov_cntrs,
                                       __stop___sancov_cntrs);
}
