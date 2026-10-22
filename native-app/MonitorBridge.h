#ifndef MONITOR_BRIDGE_H
#define MONITOR_BRIDGE_H
#include <stdint.h>
typedef struct {
    int32_t pid, ppid;
    uint32_t uid;
    uint64_t start_sec, start_usec, cpu_ns, resident;
    int cpu_valid;
    char name[64], path[1024];
} MPProcess;
typedef struct {
    char name[32];
    uint64_t in_packets, out_packets, in_bytes, out_bytes;
} MPNetwork;
typedef struct {
    uint64_t physical, compressed, swap_used;
    uint64_t user_ticks, system_ticks, idle_ticks, nice_ticks;
    int cpu_valid, memory_valid, pressure;
} MPSystem;
int mp_processes(MPProcess *rows, int capacity);
int mp_process(int32_t pid, MPProcess *row);
int mp_networks(MPNetwork *rows, int capacity);
MPSystem mp_system(void);
/* System resolver, bounded in time; returns 1 for an address, 0 for timeout, -1 for error. */
int mp_resolve_host(const char *host, int milliseconds, char *address, int capacity, int *error);
#endif
