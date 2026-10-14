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
