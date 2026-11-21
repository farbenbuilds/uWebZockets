wrk.headers["Connection"] = "keep-alive"
wrk.headers["User-Agent"] = "uwz-sql-local-v1"

function init(args)
    if args[1] == nil then return end
    local file = assert(io.open(args[1], "wb"))
    file:write(wrk.format())
    file:close()
end

function done(summary, latency, requests)
    io.write(string.format(
        'SQL_SAMPLE {"requests":%d,"duration_us":%d,"bytes":%d,"connect_errors":%d,"read_errors":%d,"write_errors":%d,"status_errors":%d,"timeout_errors":%d,"p50_us":%.3f,"p99_us":%.3f}\n',
        summary.requests, summary.duration, summary.bytes,
        summary.errors.connect, summary.errors.read, summary.errors.write,
        summary.errors.status, summary.errors.timeout,
        latency:percentile(50), latency:percentile(99)))
end
