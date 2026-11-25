#!/usr/bin/env sh
set -eu
LC_ALL=C
export LC_ALL

script_directory=$(CDPATH='' cd "$(dirname "$0")" && pwd)
repository=$(CDPATH='' cd "$script_directory/.." && pwd)
cd "$repository"
. "$repository/benchmarks/sql_local_v1.env"

[ "$#" -ge 1 ] && [ "$#" -le 3 ] || { printf '%s\n' 'usage: benchmark_sql.sh <empty-output-directory> [workers=1] [all|db]' >&2; exit 2; }
output=$1
workers=${2:-1}
selection=${3:-all}
case " $SQL_WORKER_COUNTS " in
    *" $workers "*) ;;
    *) printf '%s\n' 'workers must select a contract cohort: 1, 4, 8, or 12' >&2; exit 2 ;;
esac
case "$selection" in
    all) routes='db queries updates' ;;
    db) routes=db ;;
    *) printf '%s\n' 'route selection must be all or db' >&2; exit 2 ;;
esac
connections=$((workers * SQL_CONNECTIONS_PER_WORKER))
mkdir -p "$output"
output=$(CDPATH='' cd "$output" && pwd)
[ -z "$(ls -A "$output")" ] || { printf '%s\n' 'output directory must be empty' >&2; exit 2; }
zig_binary=${UWZ_ZIG:-zig}
wrk_binary=${UWZ_WRK:-wrk}
: "${PGHOST:?Set the database host explicitly}"
: "${PGPORT:?Set the database port explicitly}"
: "${PGUSER:?Set the database user explicitly}"
: "${PGDATABASE:?Set the database name explicitly}"
: "${PGPASSWORD:?Supply database credentials through the environment}"
: "${UWZ_WRK_SOURCE:?Record the load generator source URL}"
: "${UWZ_WRK_RETRIEVED_AT:?Record when the load generator was retrieved in UTC}"
: "${UWZ_ZIG_RETRIEVED_AT:?Record when the Zig toolchain was retrieved in UTC}"
: "${UWZ_SQL_PG_VERSION:?Record the actual PostgreSQL version}"
: "${UWZ_SQL_PG_IMAGE:?Record the immutable PostgreSQL image digest}"
command -v "$zig_binary" >/dev/null
command -v "$wrk_binary" >/dev/null
command -v python3 >/dev/null
command -v curl >/dev/null
command -v ss >/dev/null

server_pid=
sampler_pid=
probe_pid=
probe_sampler=
status=failed
printf '%s\n' in_progress > "$output/run.status"

stop_server()
{
    [ -n "$server_pid" ] || return 0
    kill -TERM "$server_pid" 2>/dev/null || true
    attempts=0
    while kill -0 "$server_pid" 2>/dev/null; do
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 150 ]; then
            kill -KILL "$server_pid" 2>/dev/null || true
            wait "$server_pid" 2>/dev/null || true
            printf '%s\n' 'server exceeded the 15-second shutdown bound' >&2
            return 1
        fi
        sleep 0.1
    done
    wait "$server_pid"
    server_pid=
    if [ -n "$sampler_pid" ]; then wait "$sampler_pid"; sampler_pid=; fi
}

cleanup()
{
    # An earlier failure must still stop only this harness's owned process.
    stop_server || status=failed
    if [ -n "$probe_pid" ]; then
        kill -TERM "$probe_pid" 2>/dev/null || true
        wait "$probe_pid" 2>/dev/null || true
    fi
    if [ -n "$probe_sampler" ]; then wait "$probe_sampler" 2>/dev/null || true; fi
    printf '%s\n' "$status" > "$output/run.status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

snapshot()
{
    prefix=$1
    git rev-parse HEAD > "$output/$prefix.commit"
    git status --short > "$output/$prefix.status.txt"
    git diff --binary HEAD -- build.zig build.zig.zon builds src include examples/*.zig examples/sql/*.sql \
        vendor/sqlite benchmarks/*.zig benchmarks/*.env benchmarks/*.lua \
        scripts/benchmark_sql.sh scripts/summarize_sql_benchmark.py scripts/check_static_archive.sh > "$output/$prefix.patch"
    git ls-files --others --exclude-standard -z -- build.zig build.zig.zon builds src include examples/*.zig examples/sql/*.sql \
        vendor/sqlite benchmarks/*.zig benchmarks/*.env benchmarks/*.lua \
        scripts/benchmark_sql.sh scripts/summarize_sql_benchmark.py scripts/check_static_archive.sh |
        xargs -0 -r sha256sum > "$output/$prefix.untracked.sha256"
    sha256sum "$output/$prefix.patch" "$output/$prefix.untracked.sha256" | awk '{print $1}' > "$output/$prefix.content.sha256"
}

sample_process()
{
    pid=$1
    file=$2
    printf '%s\n' 'uptime_seconds pid ppid state cpu_percent rss_kib elapsed_seconds threads' > "$file"
    while kill -0 "$pid" 2>/dev/null; do
        timestamp=$(cut -d' ' -f1 /proc/uptime)
        # The child may exit between kill and ps; that completes sampling.
        process=$(ps -p "$pid" -o pid=,ppid=,state=,%cpu=,rss=,etimes=,nlwp=) || return 0
        if [ -n "$process" ]; then printf '%s %s\n' "$timestamp" "$process" >> "$file"; fi
        sleep 0.1
    done
}

process_details()
{
    pid=$1
    prefix=$2
    ps -p "$pid" -o pid=,ppid=,state=,%cpu=,rss=,args= > "$output/$prefix.process.txt"
    taskset -pc "$pid" > "$output/$prefix.affinity.txt"
    cat "/proc/$pid/status" > "$output/$prefix.status.txt"
    for task in "/proc/$pid/task/"*; do
        # Worker threads may finish while the supervisor is being observed.
        if [ ! -r "$task/status" ]; then continue; fi
        printf 'task=%s\n' "${task##*/}"
        awk '/^Name:|^Cpus_allowed_list:/ {print}' "$task/status"
    done > "$output/$prefix.thread_affinity.txt"
    for descriptor in "/proc/$pid/fd/"*; do
        # Descriptors can close between enumeration and readlink.
        readlink "$descriptor" || true
    done > "$output/$prefix.descriptors.txt"
}

snapshot before
tar -czf "$output/source.tgz" build.zig build.zig.zon builds src include examples \
    vendor/sqlite benchmarks/sql_query_probe.zig benchmarks/sql_cluster_server.zig \
    benchmarks/sql_local_v1.env benchmarks/sql_report.lua scripts/check_static_archive.sh \
    LICENSE THIRD_PARTY_NOTICES.md licenses
cp benchmarks/sql_local_v1.env "$output/contract.env"
cp benchmarks/sql_report.lua "$output/load.lua"
printf 'workers=%s\nconnections=%s\nthreads=%s\nroutes=%s\n' "$workers" "$connections" "$SQL_THREADS" "$selection" > "$output/cohort.env"
{
    printf 'recorded_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '%s\n' 'host_policy=shared development host; no quiet-host claim'
    uname -a
    lscpu
    cgroup_path=$(sed -n 's/^0:://p' /proc/self/cgroup)
    while [ -n "$cgroup_path" ]; do
        printf 'cpu_quota_path=%s ' "$cgroup_path"
        if [ -f "/sys/fs/cgroup$cgroup_path/cpu.max" ]; then
            cat "/sys/fs/cgroup$cgroup_path/cpu.max"
        else
            printf '%s\n' 'cpu.max not exposed at this hierarchy level'
        fi
        [ "$cgroup_path" != / ] || break
        cgroup_path=${cgroup_path%/*}
        [ -n "$cgroup_path" ] || cgroup_path=/
    done
    printf 'cpuset='; cat /sys/fs/cgroup/cpuset.cpus.effective
    cat /proc/self/cgroup
    printf '%s\n' 'affinity_policy=public cluster physical-core pinning; generator inherits affinity'
    taskset -pc $$
    printf 'smt='; cat /sys/devices/system/cpu/smt/active
    printf 'governor='; cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
    printf 'memlock_kib='; ulimit -l
    printf 'hertz='; getconf CLK_TCK
    uptime
} > "$output/host.txt"
{
    printf 'zig_source=https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz\n'
    printf 'zig_retrieved_at=%s\n' "$UWZ_ZIG_RETRIEVED_AT"
    "$zig_binary" version
    printf 'load_generator_source=%s\n' "$UWZ_WRK_SOURCE"
    printf 'load_generator_retrieved_at=%s\n' "$UWZ_WRK_RETRIEVED_AT"
    "$wrk_binary" -v 2>&1 | head -1
    curl --version | head -1
    python3 --version
    ldd --version | head -1
    printf 'postgres_version=%s\n' "$UWZ_SQL_PG_VERSION"
    printf 'postgres_image=%s\n' "$UWZ_SQL_PG_IMAGE"
    printf 'pg_host=%s\npg_port=%s\npg_database=%s\npg_user=%s\n' "$PGHOST" "$PGPORT" "$PGDATABASE" "$PGUSER"
    printf 'http_version=HTTP/1.1\nhttp_tls=disabled\nhttp_compression=disabled\nkeep_alive=true\nstreams_per_connection=1\n'
    if [ -n "${PGSSLROOTCERT:-}" ]; then
        printf 'postgres_tls=TLS1.3 verified\n'
    else
        printf 'postgres_tls=disabled; explicit development opt-in\n'
    fi
    printf 'optimization=ReleaseFast\nworkers=%s\npool_connections_per_worker=%s\n' "$workers" "$SQL_POOL_CONNECTIONS"
    printf 'build_command=zig build sql-bench -Dsql=true -Doptimize=ReleaseFast\n'
    sha256sum "$(command -v "$zig_binary")" "$(command -v "$wrk_binary")" flake.lock build.zig.zon
} > "$output/tools.txt"
dpkg-query -W -f='${Package} ${Version}\n' dash bash git curl python3 coreutils tar iproute2 util-linux procps > "$output/system_tool_packages.txt"
printf '%s\n' 'System tool source: Ubuntu archive packages; preinstalled retrieval timestamps unavailable.' >> "$output/system_tool_packages.txt"
ldd "$(command -v "$wrk_binary")" > "$output/load_generator_libraries.txt"
awk '{for (column = 1; column <= NF; column++) if ($column ~ /^\//) print $column}' "$output/load_generator_libraries.txt" |
    xargs -r sha256sum > "$output/load_generator_libraries.sha256"
cp build.zig.zon "$output/dependencies.zon"
sha256sum "$output/source.tgz" > "$output/source.sha256"
"$zig_binary" build sql-bench -Dsql=true -Doptimize=ReleaseFast -j4 --prefix "$output/build" > "$output/build.log" 2>&1
server_binary=$output/build/bin/sql_cluster_server
probe_binary=$output/build/bin/sql_query_probe
sha256sum "$server_binary" "$probe_binary" > "$output/binaries.sha256"

UWZ_HTTP_PORT=$SQL_HTTP_PORT UWZ_SQL_WORKERS=$workers "$server_binary" > "$output/server.log" 2>&1 &
server_pid=$!
sample_process "$server_pid" "$output/server.resources.tsv" &
sampler_pid=$!
attempt=0
while :; do
    ready_count=$(awk -v port="$SQL_HTTP_PORT" 'index($0, "server listening on 127.0.0.1:" port) {count++} END {print count+0}' "$output/server.log")
    if [ "$ready_count" -ge "$workers" ] && curl --silent --fail "http://127.0.0.1:$SQL_HTTP_PORT/db" > /dev/null; then break; fi
    attempt=$((attempt + 1))
    [ "$attempt" -lt 100 ] || { printf '%s\n' 'SQL server did not become ready' >&2; exit 1; }
    kill -0 "$server_pid"
    sleep 0.1
done
process_details "$server_pid" server
ss -ltnp "sport = :$SQL_HTTP_PORT" > "$output/listener.txt"
if ! grep -Fq "pid=$server_pid," "$output/listener.txt"; then
    printf '%s\n' 'listener does not belong to the benchmark child' >&2
    exit 1
fi

for route in $routes; do
    path=/$route
    if [ "$route" != db ]; then path="$path?count=20"; fi
    url="http://127.0.0.1:$SQL_HTTP_PORT$path"
    curl --silent --show-error --fail --http1.1 --raw --include \
        -H 'Connection: keep-alive' -H 'User-Agent: uwz-sql-local-v1' "$url" > "$output/$route.response.http"
    "$wrk_binary" -t"$SQL_THREADS" -c"$connections" -d"${SQL_WARMUP_SECONDS}s" \
        -s "$repository/benchmarks/sql_report.lua" "$url" -- "$output/$route.request.http" > "$output/$route.warmup.log"
    sample=1
    while [ "$sample" -le "$SQL_SAMPLES" ]; do
        "$wrk_binary" -t"$SQL_THREADS" -c"$connections" -d"${SQL_DURATION_SECONDS}s" --latency \
            -s "$repository/benchmarks/sql_report.lua" "$url" -- "$output/$route.request.http" > "$output/${route}_${sample}.log"
        sample=$((sample + 1))
    done
done
stop_server

sample=1
while [ "$sample" -le "$SQL_SAMPLES" ]; do
    UWZ_SQL_PROBE_OUTPUT="$output/probe_$sample.csv" "$probe_binary" > "$output/probe_$sample.log" 2>&1 &
    probe_pid=$!
    sample_process "$probe_pid" "$output/probe_$sample.resources.tsv" &
    probe_sampler=$!
    sleep 0.1
    process_details "$probe_pid" "probe_$sample"
    if wait "$probe_pid"; then probe_status=0; else probe_status=$?; fi
    probe_pid=
    wait "$probe_sampler"
    probe_sampler=
    [ "$probe_status" -eq 0 ] || exit "$probe_status"
    sample=$((sample + 1))
done
snapshot after
cmp "$output/before.content.sha256" "$output/after.content.sha256"
python3 "$repository/scripts/summarize_sql_benchmark.py" "$output" "$SQL_SAMPLES" "$SQL_ACCEPTANCE_RPS"
status=passed
