#include "MonitorBridge.h"
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/sysctl.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <stdlib.h>
#include <string.h>
#include <dns_sd.h>
#include <arpa/inet.h>
#include <sys/select.h>
#include <time.h>
#include <errno.h>

typedef struct { char *address; int capacity, found, error; } MPDNSContext;
static void mp_dns_reply(DNSServiceRef service, DNSServiceFlags flags, uint32_t index,
                         DNSServiceErrorType error, const char *host,
                         const struct sockaddr *address, uint32_t ttl, void *context) {
    MPDNSContext *c = context;
    if (error) { c->error = error; return; }
    if (!(flags & kDNSServiceFlagsAdd) || !address) return;
    const void *value = address->sa_family == AF_INET ? (const void *)&((const struct sockaddr_in *)address)->sin_addr :
                        address->sa_family == AF_INET6 ? (const void *)&((const struct sockaddr_in6 *)address)->sin6_addr : NULL;
    if (value && inet_ntop(address->sa_family, value, c->address, (socklen_t)c->capacity)) c->found = 1;
}
static double mp_monotonic_seconds(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}
int mp_resolve_host(const char *host, int milliseconds, char *address, int capacity, int *error) {
    if (!host || !address || capacity < INET6_ADDRSTRLEN || !error) return -1;
    address[0] = 0; *error = 0;
    MPDNSContext c = {address, capacity, 0, 0};
    DNSServiceRef service = NULL;
    DNSServiceErrorType initial = DNSServiceGetAddrInfo(&service, 0, 0,
        kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6, host, mp_dns_reply, &c);
    if (initial) { *error = initial; return -1; }
    int fd = DNSServiceRefSockFD(service);
    if (fd < 0 || fd >= FD_SETSIZE) { DNSServiceRefDeallocate(service); *error = -1; return -1; }
    double deadline = mp_monotonic_seconds() + (double)milliseconds / 1000.0;
    while (!c.found && mp_monotonic_seconds() < deadline) {
        fd_set fds; FD_ZERO(&fds); FD_SET(fd, &fds);
        struct timeval interval = {0, 50000};
        int ready = select(fd + 1, &fds, NULL, NULL, &interval);
        if (ready < 0) { if (errno == EINTR) continue; c.error = errno; break; }
        if (ready > 0) {
            DNSServiceErrorType e = DNSServiceProcessResult(service);
            if (e) { c.error = e; break; }
        }
    }
    DNSServiceRefDeallocate(service); *error = c.error;
    return c.found ? 1 : c.error ? -1 : 0;
}

int mp_process(int32_t pid, MPProcess *row) {
    struct proc_bsdinfo b = {0};
    if (pid <= 0 || proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &b, sizeof(b)) != sizeof(b)) return 0;
    memset(row, 0, sizeof(*row));
    row->pid = pid; row->ppid = b.pbi_ppid; row->uid = b.pbi_uid;
    row->start_sec = b.pbi_start_tvsec; row->start_usec = b.pbi_start_tvusec;
    strlcpy(row->name, b.pbi_name[0] ? b.pbi_name : b.pbi_comm, sizeof(row->name));
    proc_pidpath(pid, row->path, sizeof(row->path));
    struct proc_taskinfo t = {0};
    if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &t, sizeof(t)) == sizeof(t)) {
        mach_timebase_info_data_t base;
        mach_timebase_info(&base);
        row->cpu_ns = (uint64_t)((__uint128_t)(t.pti_total_user + t.pti_total_system) * base.numer / base.denom);
        row->resident = t.pti_resident_size; row->cpu_valid = 1;
    }
    return 1;
}
int mp_processes(MPProcess *rows, int capacity) {
    int size = proc_listallpids(NULL, 0) + 1024;
    pid_t *pids = calloc(size, sizeof(pid_t));
    if (!pids) return -1;
    int n = proc_listallpids(pids, size * sizeof(pid_t)), used = 0;
    if (n < 0) { free(pids); return -1; }
    for (int i = 0; i < n && used < capacity; i++) {
        if (mp_process(pids[i], &rows[used])) used++;
    }
    free(pids); return used;
}
int mp_networks(MPNetwork *rows, int capacity) {
    struct ifaddrs *head = NULL;
    if (getifaddrs(&head) != 0) return -1;
    int n = 0;
    for (struct ifaddrs *p = head; p && n < capacity; p = p->ifa_next) {
        if (!p->ifa_addr || p->ifa_addr->sa_family != AF_LINK || !p->ifa_data) continue;
        struct if_data *d = p->ifa_data;
        MPNetwork *r = &rows[n++]; memset(r, 0, sizeof(*r));
        strlcpy(r->name, p->ifa_name, sizeof(r->name));
        r->in_packets = d->ifi_ipackets; r->out_packets = d->ifi_opackets;
        r->in_bytes = d->ifi_ibytes; r->out_bytes = d->ifi_obytes;
    }
    freeifaddrs(head); return n;
}
MPSystem mp_system(void) {
    MPSystem r = {0}; size_t len = sizeof(r.physical);
    if (sysctlbyname("hw.memsize", &r.physical, &len, NULL, 0) == 0) r.memory_valid = 1;
    vm_statistics64_data_t vm = {0}; mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &count) == KERN_SUCCESS)
        r.compressed = (uint64_t)vm.compressor_page_count * vm_page_size;
    struct xsw_usage swap = {0}; len = sizeof(swap);
    if (sysctlbyname("vm.swapusage", &swap, &len, NULL, 0) == 0) r.swap_used = swap.xsu_used;
    host_cpu_load_info_data_t cpu = {0}; count = HOST_CPU_LOAD_INFO_COUNT;
    if (host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, (host_info_t)&cpu, &count) == KERN_SUCCESS) {
        r.cpu_valid = 1;
        r.user_ticks = cpu.cpu_ticks[CPU_STATE_USER]; r.system_ticks = cpu.cpu_ticks[CPU_STATE_SYSTEM];
        r.idle_ticks = cpu.cpu_ticks[CPU_STATE_IDLE]; r.nice_ticks = cpu.cpu_ticks[CPU_STATE_NICE];
    }
    len = sizeof(r.pressure);
    sysctlbyname("kern.memorystatus_vm_pressure_level", &r.pressure, &len, NULL, 0);
    return r;
}
