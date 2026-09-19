#define SEC(name) __attribute__((section(name), used))
#define XDP_PASS 2
#define BPF_MAP_TYPE_PERCPU_ARRAY 6
#define UWZ_LATENCY_BUCKETS 16

typedef unsigned int __u32;
typedef unsigned long long __u64;

struct xdp_md {
    __u32 data;
    __u32 data_end;
    __u32 data_meta;
    __u32 ingress_ifindex;
    __u32 rx_queue_index;
    __u32 egress_ifindex;
};

#define __uint(name, value) int (*name)[value]

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, UWZ_LATENCY_BUCKETS);
    __uint(key_size, sizeof(__u32));
    __uint(value_size, sizeof(__u64));
} uwz_latency SEC(".maps");

static void *(*bpf_map_lookup_elem)(void *map, const void *key) = (void *)1;

SEC("xdp")
int uwz_latency_observe(struct xdp_md *context)
{
    __u32 length = context->data_end - context->data;
    __u32 bucket = length == 0 ? 0 : 31 - __builtin_clz(length);
    __u64 *value;

    if (bucket > UWZ_LATENCY_BUCKETS - 1)
        bucket = UWZ_LATENCY_BUCKETS - 1;

    value = bpf_map_lookup_elem(&uwz_latency, &bucket);
    if (value)
        *value += 1;

    return XDP_PASS;
}

char uwz_latency_license[] SEC("license") = "GPL";
