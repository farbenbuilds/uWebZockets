#define SEC(name) __attribute__((section(name), used))
#define XDP_PASS 2
#define BPF_MAP_TYPE_XSKMAP 17

typedef unsigned int __u32;

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
    __uint(type, BPF_MAP_TYPE_XSKMAP);
    __uint(max_entries, 256);
    __uint(key_size, sizeof(__u32));
    __uint(value_size, sizeof(__u32));
} uwz_xsks SEC(".maps");

static long (*bpf_redirect_map)(void *map, __u32 key, __u32 flags) = (void *)51;

SEC("xdp")
int uwz_xdp_redirect(struct xdp_md *context)
{
    return (int)bpf_redirect_map(&uwz_xsks, context->rx_queue_index, XDP_PASS);
}

char uwz_license[] SEC("license") = "GPL";
