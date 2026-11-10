#!/usr/bin/env python3
"""Loopback correctness evidence; bodies and qlog events stream to disk."""

from __future__ import annotations

import argparse

import gzip
import hashlib
import json
import os
import select
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from contextlib import ExitStack
from pathlib import Path
from typing import TYPE_CHECKING, BinaryIO, TextIO, TypedDict

if TYPE_CHECKING:
    from aioquic.h3.connection import H3Connection
    from aioquic.h3.events import H3Event
    from aioquic.quic.connection import QuicConnection


LARGE_SIZE = 104857600
CHUNK_SIZE = 8192
HEADER_BOUND = 65536
DATAGRAM_BOUND = 65536
SMALL_BODY = b"uWebZockets static representation fixture.\n" * 32
# BrotliEncoderCompress(5, 22, 0); raw BrotliEncoderVersion is 16781312.
SMALL_BR = bytes.fromhex(
    "1b5f05004437d72d6921d9aa6054269c87c3aff01e2419820cd496d6a1728ce12737"
    "fbc14398915365de41addf73a98203"
)


def require(condition: bool, detail: str) -> None:
    if not condition:
        raise RuntimeError(detail)


def digest_file(path: Path) -> dict:
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as body:
        while chunk := body.read(CHUNK_SIZE):
            digest.update(chunk)
            size += len(chunk)
    return {"bytes": size, "sha256": digest.hexdigest()}


def compare_files(actual: Path, expected: Path, offset: int = 0, length: int | None = None) -> dict:
    remaining = expected.stat().st_size - offset if length is None else length
    digest = hashlib.sha256()
    count = 0
    with actual.open("rb") as received, expected.open("rb") as source:
        source.seek(offset)
        while remaining:
            chunk = received.read(min(CHUNK_SIZE, remaining))
            require(bool(chunk), f"premature body EOF at {count}: {actual}")
            require(chunk == source.read(len(chunk)), f"body mismatch at {count}: {actual}")
            digest.update(chunk)
            remaining -= len(chunk)
            count += len(chunk)
        require(received.read(1) == b"", f"body exceeds selected representation: {actual}")
    return {"bytes": count, "sha256": digest.hexdigest(), "comparison_chunk_bound": CHUNK_SIZE}


def fixtures(root: Path) -> dict:
    root.mkdir()
    large = root / "large.bin"
    sentinels = [0, 8191, 8192, 32767, 65535, 65536, LARGE_SIZE - 1]
    with large.open("wb") as output:
        output.truncate(LARGE_SIZE)
        for index, offset in enumerate(sentinels):
            output.seek(offset)
            output.write(bytes([index + 1]))
    (root / "asset.txt").write_bytes(SMALL_BODY)
    (root / "asset.txt.gz").write_bytes(gzip.compress(SMALL_BODY, mtime=0))
    (root / "asset.txt.br").write_bytes(SMALL_BR)
    (root / "health.expected").write_bytes(b"ok")
    for path in root.iterdir():
        os.utime(path, (1700000000, 1700000000))
    return {
        "large_size": LARGE_SIZE,
        "large_allocated_file_bytes": large.stat().st_blocks * 512,
        "sentinels": [{"offset": value, "byte": index + 1} for index, value in enumerate(sentinels)],
        "files": {path.name: digest_file(path) for path in sorted(root.iterdir())},
        "brotli_encoder_version": "16781312 (raw development encoder version)",
    }


def command(directory: Path, label: str, arguments: list[str], *, env: dict | None = None, timeout: int = 300) -> Path:
    (directory / f"{label}.command").write_text(shlex.join(arguments) + "\n", encoding="utf-8")
    output = directory / f"{label}.log"
    status = None
    timed_out = False
    try:
        with output.open("wb") as stream:
            process = subprocess.Popen(arguments, stdout=stream, stderr=subprocess.STDOUT, env=env)
            try:
                status = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                process.kill()
                status = process.wait(timeout=5)
    finally:
        (directory / f"{label}.status").write_text(f"{status}\n", encoding="utf-8")
        (directory / f"{label}.timeout").write_text(f"{str(timed_out).lower()}\n", encoding="ascii")
    require(not timed_out and status == 0, f"{label} exited {status}, timeout={timed_out}; see {output}")
    return output


def read_headers(path: Path) -> dict[str, list[str]]:
    raw = path.read_bytes()
    require(len(raw) <= HEADER_BOUND, f"response headers exceed harness bound: {path}")
    block = raw.replace(b"\r\n", b"\n").strip().split(b"\n\n")[-1]
    fields: dict[str, list[str]] = {}
    for line in block.split(b"\n")[1:]:
        name, value = line.split(b":", 1)
        fields.setdefault(name.decode("ascii").lower(), []).append(value.strip().decode("ascii"))
    return fields


def one_header(fields: dict[str, list[str]], name: str) -> str:
    values = fields.get(name, [])
    require(len(values) == 1, f"expected one {name}: {values}")
    return values[0]


Endpoint = TypedDict("Endpoint", {
    "name": str, "version": str, "flag": str,
    "scheme": str, "port": int, "cert": Path,
})

ResponseState = TypedDict("ResponseState", {
    "source": BinaryIO, "output": BinaryIO, "body_path": Path,
    "headers": list[tuple[bytes, bytes]], "bytes": int,
    "max_event_bytes": int, "done": bool, "proof": dict,
    "require_content_length": bool,
})

QuicClientState = TypedDict("QuicClientState", {
    "quic": "QuicConnection", "http": "H3Connection",
    "requests": dict[int, ResponseState], "trace": TextIO,
    "handshake": bool, "terminated": bool,
})


def curl_transport(endpoint: Endpoint) -> list[str]:
    options = [endpoint["flag"], "--noproxy", "*", "--connect-timeout", "3", "--max-time", "240"]
    if endpoint["scheme"] == "https":
        options += ["--cacert", str(endpoint["cert"])]
    return options


def curl_request(endpoint: Endpoint, directory: Path, label: str, path: str, headers: tuple[str, ...] = (), *, head: bool = False, compressed: bool = False, reuse: bool = False) -> dict:
    base = f"{endpoint['scheme']}://127.0.0.1:{endpoint['port']}"
    body_path = directory / f"{label}.body"
    if not head:
        body_path.touch(exist_ok=False)
    metadata = "%{http_version} %{response_code} %{size_download} %{num_connects} %{conn_id}\\n"
    arguments = ["curl", "--disable", "--silent", "--show-error", "--verbose", "--trace-time", "--stderr", str(directory / f"{label}.trace")]
    arguments += curl_transport(endpoint)
    arguments += ["--dump-header", str(directory / f"{label}.headers"), "--output", os.devnull if head else str(body_path), "--write-out", metadata]
    for value in headers:
        arguments += ["--header", value]
    if head:
        arguments += ["--head"]
    if compressed:
        arguments += ["--compressed"]
    arguments += [base + path]
    if reuse:
        arguments += ["--next", *curl_transport(endpoint), "--silent", "--show-error", "--dump-header", str(directory / f"{label}.reuse.headers"), "--output", str(directory / f"{label}.reuse.body"), "--write-out", metadata, base + "/health"]
    env = dict(os.environ)
    env["QLOGDIR"] = str(directory / "qlog")
    output = command(directory, label, arguments, env=env)
    rows = [line.split() for line in output.read_text(encoding="utf-8").splitlines()]
    require(len(rows) == (2 if reuse else 1), f"invalid curl metadata: {output}")
    require(all(len(row) == 5 for row in rows), f"invalid curl metadata columns: {output}")
    require(all(row[0] == endpoint["version"] for row in rows), f"wrong negotiated protocol: {rows}")
    if reuse:
        require(rows[1][1] == "200" and rows[1][3] == "0" and rows[0][4] == rows[1][4], f"connection was not reused: {rows}")
        require((directory / f"{label}.reuse.body").read_bytes() == b"ok", f"reuse health body failed: {label}")
    return {"status": int(rows[0][1]), "metadata": rows, "headers": read_headers(directory / f"{label}.headers"), "body": body_path, "head": head}


def check_response(response: dict, status: int, source: Path | None, *, encoding: str | None = None, length: int | None = None, offset: int = 0, vary: bool = True) -> dict:
    require(response["status"] == status, f"HTTP status {response['status']} != {status}")
    fields = response["headers"]
    if encoding is None:
        require("content-encoding" not in fields, f"unexpected Content-Encoding: {fields}")
    else:
        require(one_header(fields, "content-encoding") == encoding, f"wrong Content-Encoding: {fields}")
    if vary:
        require("accept-encoding" in ",".join(fields.get("vary", [])).lower().replace(" ", "").split(","), f"missing Vary: {fields}")
    if source is not None:
        selected_length = source.stat().st_size - offset if length is None else length
        require(one_header(fields, "content-length") == str(selected_length), f"wrong Content-Length: {fields}")
        if response["head"]:
            require(response["metadata"][0][2] == "0", "HEAD downloaded body bytes")
            return {"bytes": 0, "declared_bytes": selected_length}
        return compare_files(response["body"], source, offset, selected_length)
    require(response["metadata"][0][2] == "0", "bodyless response downloaded bytes")
    require(response["body"].stat().st_size == 0, "bodyless response has body bytes")
    return {"bytes": 0}


def small_matrix(endpoint: Endpoint, directory: Path, root: Path) -> dict:
    proofs = {}
    identity = curl_request(endpoint, directory, "identity_default", "/identity/asset.txt", ("Accept-Encoding: br, gzip",))
    proofs["identity_default"] = check_response(identity, 200, root / "asset.txt", vary=False)
    identity = curl_request(endpoint, directory, "identity", "/files/asset.txt", ("Accept-Encoding: identity",))
    proofs["identity"] = check_response(identity, 200, root / "asset.txt")
    validators = [one_header(identity["headers"], "etag")]
    response = curl_request(endpoint, directory, "identity_304", "/files/asset.txt", ("Accept-Encoding: identity", f"If-None-Match: {validators[0]}"))
    proofs["identity_304"] = check_response(response, 304, None)
    for coding, suffix in (("gzip", ".gz"), ("br", ".br")):
        source = root / ("asset.txt" + suffix)
        size = source.stat().st_size
        accept = (f"Accept-Encoding: {coding}",)
        response = curl_request(endpoint, directory, coding + "_full", "/files/asset.txt", accept)
        proofs[coding + "_full"] = check_response(response, 200, source, encoding=coding)
        require(one_header(response["headers"], "content-type").startswith("text/plain"), "sidecar changed source MIME")
        etag = one_header(response["headers"], "etag")
        validators.append(etag)
        response = curl_request(endpoint, directory, coding + "_head", "/files/asset.txt", accept, head=True)
        proofs[coding + "_head"] = check_response(response, 200, source, encoding=coding)
        response = curl_request(endpoint, directory, coding + "_304", "/files/asset.txt", (*accept, f"If-None-Match: {etag}"))
        proofs[coding + "_304"] = check_response(response, 304, None, encoding=coding)
        require(one_header(response["headers"], "etag") == etag, "304 validator differs")
        for label, conditional in (("range", ()), ("if_range", (f"If-Range: {etag}",))):
            response = curl_request(endpoint, directory, coding + "_" + label, "/files/asset.txt", (*accept, "Range: bytes=1-10", *conditional))
            proofs[coding + "_" + label] = check_response(response, 206, source, encoding=coding, offset=1, length=10)
            require(one_header(response["headers"], "content-range") == f"bytes 1-10/{size}", "encoded range metadata differs")
        response = curl_request(endpoint, directory, coding + "_if_range_miss", "/files/asset.txt", (*accept, "Range: bytes=1-10", 'If-Range: "different"'))
        proofs[coding + "_if_range_miss"] = check_response(response, 200, source, encoding=coding)
        response = curl_request(endpoint, directory, coding + "_416", "/files/asset.txt", (*accept, f"Range: bytes={size}-"))
        proofs[coding + "_416"] = check_response(response, 416, None)
        require(one_header(response["headers"], "content-range") == f"bytes */{size}", "416 uses wrong representation length")
        response = curl_request(endpoint, directory, coding + "_decoded", "/files/asset.txt", accept, compressed=True)
        require(response["status"] == 200, "decoded transfer failed")
        require(one_header(response["headers"], "content-encoding") == coding, "decoded transfer coding differs")
        require(one_header(response["headers"], "content-length") == str(size), "decoded transfer encoded length differs")
        proofs[coding + "_decoded"] = compare_files(response["body"], root / "asset.txt")
    require(len(set(validators)) == 3, f"representation ETags are not distinct: {validators}")
    duplicate_headers = ("Accept-Encoding: gzip", *(f"X-Filler-{index}: bounded" for index in range(18)), "Accept-Encoding: gzip;q=0, br, identity;q=0")
    response = curl_request(endpoint, directory, "duplicate_fields", "/files/asset.txt", duplicate_headers)
    proofs["duplicate_fields"] = check_response(response, 200, root / "asset.txt.br", encoding="br")
    response = curl_request(endpoint, directory, "refused", "/files/asset.txt", ("Accept-Encoding: gzip;q=0, br;q=0, identity;q=0",))
    proofs["refused"] = check_response(response, 406, None)
    return proofs


def listener_record(pid: int, port: int, udp: bool) -> str:
    descriptors = set()
    for descriptor in Path(f"/proc/{pid}/fd").iterdir():
        try:
            target = os.readlink(descriptor)
        except FileNotFoundError:
            continue  # A completed descriptor can disappear during the snapshot.
        if target.startswith("socket:["):
            descriptors.add(target[8:-1])
    table = Path("/proc/net/udp" if udp else "/proc/net/tcp").read_text(encoding="ascii")
    matches = [line for line in table.splitlines()[1:] if int(line.split()[1].split(":")[1], 16) == port and line.split()[9] in descriptors]
    require(bool(matches), f"owned PID {pid} has no {'UDP' if udp else 'TCP'} listener at {port}")
    return f"pid={pid}\n" + "\n".join(matches) + "\n"


def precheck_port(port: int) -> None:
    for kind in (socket.SOCK_STREAM, socket.SOCK_DGRAM):
        with socket.socket(socket.AF_INET, kind) as probe:
            probe.bind(("127.0.0.1", port))


def archive_body(path: Path) -> dict:
    proof = digest_file(path)
    archive = path.parent / (path.name + ".gz")
    with path.open("rb") as source, archive.open("wb") as output:
        with gzip.GzipFile(filename="", fileobj=output, mode="wb", mtime=0) as compressed:
            shutil.copyfileobj(source, compressed, length=CHUNK_SIZE)
    path.unlink()
    return {"uncompressed": proof, "gzip_archive": digest_file(archive)}


def run_server(args: argparse.Namespace, runtime: Path, mode: str, endpoints: list[Endpoint], results: dict) -> None:
    directory = args.artifacts / mode
    directory.mkdir()
    (directory / "qlog").mkdir()
    port = endpoints[0]["port"]
    precheck_port(port)
    (directory / "port_precheck.status").write_text("0\n", encoding="ascii")
    env = dict(os.environ)
    env.update(STATIC_INTEROP_MODE=mode, STATIC_INTEROP_PORT=str(port), STATIC_INTEROP_ROOT=str(runtime / "files"), STATIC_INTEROP_CERT=str(runtime / "cert.pem"), STATIC_INTEROP_KEY=str(runtime / "key.pem"))
    arguments = [str(args.server)]
    loader = (args.artifacts / "server.loader").read_text(encoding="utf-8").strip()
    library_path = (args.artifacts / "server.library_path").read_text(encoding="utf-8").strip()
    if loader and "*" not in loader:
        require(bool(library_path), "loader override requires library path")
        arguments = [loader, "--library-path", library_path, *arguments]
    (directory / "server.command").write_text(shlex.join(arguments) + "\n", encoding="utf-8")
    (directory / "server.environment").write_text("\n".join(f"{key}={env[key]}" for key in sorted(env) if key.startswith("STATIC_INTEROP_") and key != "STATIC_INTEROP_KEY") + "\n", encoding="utf-8")
    with (directory / "server.log").open("wb") as log:
        server = subprocess.Popen(arguments, env=env, stdout=log, stderr=subprocess.STDOUT)
        (directory / "server.pid").write_text(f"{server.pid}\n", encoding="ascii")
        try:
            for _ in range(50):
                require(server.poll() is None, "owned server exited before listening")
                try:
                    record = listener_record(server.pid, port, mode == "h3")
                    break
                except RuntimeError:
                    time.sleep(0.1)
            else:
                raise RuntimeError("owned server did not bind within readiness deadline")
            (directory / "listener.raw").write_text(record, encoding="ascii")
            mode_results = results.setdefault(mode, {})
            for endpoint in endpoints:
                protocol_directory = directory / endpoint["name"]
                protocol_directory.mkdir()
                (protocol_directory / "qlog").mkdir()
                health = curl_request(endpoint, protocol_directory, "readiness", "/health")
                require(health["status"] == 200 and health["body"].read_bytes() == b"ok", "readiness health failed")
                response = curl_request(endpoint, protocol_directory, "large", "/files/large.bin", ("Accept-Encoding: identity",), reuse=True)
                proof = check_response(response, 200, runtime / "files/large.bin")
                proof["metadata"] = response["metadata"]
                proof["archived_body"] = archive_body(response["body"])
                mode_results[endpoint["name"]] = {"large": proof, "small": small_matrix(endpoint, protocol_directory, runtime / "files")}
                if endpoint["version"] == "3":
                    qlogs = sorted((protocol_directory / "qlog").iterdir())
                    require(bool(qlogs) and all(path.stat().st_size > 0 for path in qlogs), "pinned curl produced no nonempty QLOGDIR evidence")
                    mode_results[endpoint["name"]]["transport_qlogs"] = {path.name: digest_file(path) for path in qlogs}
            if mode == "h3":
                mode_results["aioquic"] = aioquic_large(endpoints[0], directory, runtime / "files")
        finally:
            forced = False
            if server.poll() is None:
                server.terminate()
                try:
                    server.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    forced = True
                    server.kill()
                    server.wait(timeout=5)
            (directory / "server.status").write_text(f"{server.returncode}\n", encoding="ascii")
            (directory / "server.forced").write_text(f"{str(forced).lower()}\n", encoding="ascii")
    require(not forced and server.returncode == 0, f"{mode} server did not shut down cleanly: {server.returncode}")
    require(b"static interop shutdown drained" in (directory / "server.log").read_bytes(), f"{mode} drain marker absent")


def application_event(state: QuicClientState, event: dict) -> None:
    state["trace"].write(json.dumps(event) + "\n")


def h3_consume(state: QuicClientState, message: H3Event) -> None:
    from aioquic.h3.events import DataReceived, HeadersReceived

    if not isinstance(message, (DataReceived, HeadersReceived)):
        return
    response = state["requests"].get(message.stream_id)
    require(response is not None, f"unexpected H3 stream {message.stream_id}")
    require(not response["done"], "event arrived after END_STREAM")
    if isinstance(message, HeadersReceived):
        response["headers"].extend(message.headers)
        require(len(response["headers"]) <= 64 and sum(len(name) + len(value) for name, value in response["headers"]) <= HEADER_BOUND, "aioquic response headers exceed bound")
        application_event(state, {"event": "headers", "stream_id": message.stream_id, "headers": [[name.decode("ascii"), value.decode("ascii")] for name, value in message.headers], "end_stream": message.stream_ended})
    if isinstance(message, DataReceived):
        view = memoryview(message.data)
        for offset in range(0, len(view), CHUNK_SIZE):
            chunk = view[offset:offset + CHUNK_SIZE]
            require(chunk == response["source"].read(len(chunk)), f"aioquic mismatch at {response['bytes']}")
            require(response["output"].write(chunk) == len(chunk), "short body artifact write")
            response["bytes"] += len(chunk)
        response["max_event_bytes"] = max(response["max_event_bytes"], len(view))
        application_event(state, {"event": "data", "stream_id": message.stream_id, "data_bytes": len(view), "body_bytes": response["bytes"], "end_stream": message.stream_ended})
    if not message.stream_ended:
        return
    require(response["source"].read(1) == b"", "aioquic END_STREAM before expected EOF")
    fields = {}
    for name, value in response["headers"]:
        fields.setdefault(name.decode("ascii"), []).append(value.decode("ascii"))
    require(one_header(fields, ":status") == "200", "aioquic wrong status")
    if response["require_content_length"] or "content-length" in fields:
        require(one_header(fields, "content-length") == str(response["bytes"]), "aioquic Content-Length differs")
    require("content-encoding" not in fields, "aioquic identity transfer has Content-Encoding")
    response["output"].flush()
    proof = digest_file(response["body_path"])
    require(proof["bytes"] == response["bytes"], "aioquic body artifact byte count differs")
    response["proof"] = {"stream_id": message.stream_id, "end_stream": True, "headers": fields, **proof, "max_event_bytes": response["max_event_bytes"]}
    response["done"] = True


def quic_events(state: QuicClientState, *, closing: bool) -> None:
    from aioquic.h3.connection import H3_ALPN
    from aioquic.quic.events import ConnectionTerminated, HandshakeCompleted, StopSendingReceived, StreamReset

    while (event := state["quic"].next_event()) is not None:
        if isinstance(event, HandshakeCompleted):
            require(event.alpn_protocol in H3_ALPN, f"unexpected ALPN {event.alpn_protocol}")
            state["handshake"] = True
            application_event(state, {"event": "handshake_complete", "alpn": event.alpn_protocol})
        if isinstance(event, (StopSendingReceived, StreamReset)):
            raise RuntimeError(f"unexpected stream stop/reset: {event}")
        if isinstance(event, ConnectionTerminated):
            require(closing and event.error_code == 0, f"unexpected QUIC termination: {event}")
            state["terminated"] = True
            application_event(state, {"event": "connection_terminated", "error_code": event.error_code})
        for message in state["http"].handle_event(event):
            h3_consume(state, message)


def quic_step(state: QuicClientState, udp: socket.socket, buffer: bytearray, deadline: float, *, closing: bool = False) -> None:
    now = time.monotonic()
    require(now < deadline, "aioquic loop deadline expired")
    for data, address in state["quic"].datagrams_to_send(now=now):
        while True:
            try:
                require(udp.sendto(data, address) == len(data), "short UDP datagram send")
                break
            except BlockingIOError:
                require(time.monotonic() < deadline, "UDP send deadline expired")
                select.select([], [udp], [], min(0.1, max(0.0, deadline - time.monotonic())))
    timer = state["quic"].get_timer()
    now = time.monotonic()
    if timer is not None and timer <= now:
        state["quic"].handle_timer(now=now)
        quic_events(state, closing=closing)
        return
    timeout = min(0.1, max(0.0, deadline - now))
    if timer is not None:
        timeout = min(timeout, max(0.0, timer - now))
    readable, _, _ = select.select([udp], [], [], timeout)
    if readable:
        try:
            length, address = udp.recvfrom_into(buffer)
        except BlockingIOError:
            return  # Stale readiness leaves progress to the next bounded poll.
        state["quic"].receive_datagram(bytes(memoryview(buffer)[:length]), address, now=time.monotonic())
    quic_events(state, closing=closing)


def start_h3_request(state: QuicClientState, endpoint: Endpoint, files: ExitStack, directory: Path, root: Path, path: str, filename: str, label: str, *, require_content_length: bool) -> int:
    stream_id = state["quic"].get_next_available_stream_id()
    body_path = directory / (label + ".body")
    state["requests"][stream_id] = ResponseState(source=files.enter_context((root / filename).open("rb")), output=files.enter_context(body_path.open("wb")), body_path=body_path, headers=[], bytes=0, max_event_bytes=0, done=False, proof={}, require_content_length=require_content_length)
    headers = [(b":method", b"GET"), (b":scheme", b"https"), (b":authority", f"127.0.0.1:{endpoint['port']}".encode()), (b":path", path.encode()), (b"accept-encoding", b"identity")]
    state["http"].send_headers(stream_id, headers, end_stream=True)
    application_event(state, {"event": "request", "stream_id": stream_id, "path": path})
    return stream_id


def aioquic_large(endpoint: Endpoint, directory: Path, root: Path) -> dict:
    import aioquic.h3.connection as http3_api
    import aioquic.quic.connection as quic_api
    from aioquic.quic.configuration import QuicConfiguration

    configuration = QuicConfiguration(is_client=True, alpn_protocols=http3_api.H3_ALPN, cafile=str(endpoint["cert"]), server_name="127.0.0.1", max_data=262144, max_stream_data=65536)
    quic = quic_api.QuicConnection(configuration=configuration)
    now = time.monotonic()
    quic.connect(("127.0.0.1", endpoint["port"]), now=now)
    http = http3_api.H3Connection(quic)
    results = {}
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp, (directory / "aioquic.application.jsonl").open("w", encoding="utf-8", buffering=CHUNK_SIZE) as trace, ExitStack() as files:
        udp.bind(("127.0.0.1", 0))
        udp.setblocking(False)
        udp.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 262144)
        state = QuicClientState(quic=quic, http=http, requests={}, trace=trace, handshake=False, terminated=False)
        application_event(state, {"event": "client_configuration", "local_address": udp.getsockname(), "receive_socket_bytes": udp.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF), "datagram_buffer_bytes": DATAGRAM_BOUND, "comparison_slice_bytes": CHUNK_SIZE, "trace_kind": "application events, not transport qlog"})
        buffer = bytearray(DATAGRAM_BOUND)
        deadline = now + 240
        try:
            while not state["handshake"]:
                quic_step(state, udp, buffer, deadline)
            large_id = start_h3_request(state, endpoint, files, directory, root, "/files/large.bin", "large.bin", "aioquic_large", require_content_length=True)
            sibling_id = start_h3_request(state, endpoint, files, directory, root, "/health", "health.expected", "aioquic_sibling", require_content_length=False)
            while not all(state["requests"][stream_id]["done"] for stream_id in (large_id, sibling_id)):
                quic_step(state, udp, buffer, deadline)
            reuse_id = start_h3_request(state, endpoint, files, directory, root, "/health", "health.expected", "aioquic_reuse", require_content_length=False)
            while not state["requests"][reuse_id]["done"]:
                quic_step(state, udp, buffer, deadline)
            require(state["requests"][large_id]["proof"]["bytes"] == LARGE_SIZE, "aioquic large byte count differs")
            results = {"large": state["requests"][large_id]["proof"], "healthy_sibling": state["requests"][sibling_id]["proof"], "reuse": state["requests"][reuse_id]["proof"]}
        finally:
            quic.close()
            close_deadline = time.monotonic() + 5
            while not state["terminated"]:
                quic_step(state, udp, buffer, close_deadline, closing=True)
        files.close()
        for label, stream_id in (("large", large_id), ("healthy_sibling", sibling_id), ("reuse", reuse_id)):
            results[label]["archived_body"] = archive_body(state["requests"][stream_id]["body_path"])
    return {**results, "connection_count": 1, "comparison_slice_bound": CHUNK_SIZE, "receive_datagram_bound": DATAGRAM_BOUND, "trace": "aioquic.application.jsonl is an application-event trace, not transport qlog", "transport_qlog": "retained by pinned curl QLOGDIR; this low-level case produces application events only", "api_source": {"quic": {"path": quic_api.__file__, **digest_file(Path(quic_api.__file__))}, "h3": {"path": http3_api.__file__, **digest_file(Path(http3_api.__file__))}}}


def run(args: argparse.Namespace) -> None:
    import aioquic

    expected = json.loads((args.source / "scripts/http3_compliance/expectations.json").read_text(encoding="utf-8"))["clients"]
    versions = command(args.artifacts, "curl_version", ["curl", "--disable", "--version"]).read_text(encoding="utf-8")
    require(versions.startswith("curl " + expected["curl"]["version"] + " "), "curl version differs from pinned expectation")
    require(all(value in versions for value in (expected["curl"]["quic"], expected["curl"]["http3"], "HTTP3", "HTTP2", "brotli")), "curl lacks pinned protocol/decoder capabilities")
    require(aioquic.__version__ == expected["aioquic"]["version"], "aioquic version differs from pinned expectation")
    (args.artifacts / "aioquic.version").write_text(aioquic.__version__ + "\n", encoding="ascii")
    tools = {"python": {"path": sys.executable, "version": sys.version, **digest_file(Path(sys.executable))}, "aioquic": {"path": aioquic.__file__, **digest_file(Path(aioquic.__file__))}}
    curl = shutil.which("curl")
    require(curl is not None, "curl executable is absent")
    tools["curl"] = {"path": curl, **digest_file(Path(curl))}
    (args.artifacts / "tool_identity.json").write_text(json.dumps(tools, indent=2) + "\n", encoding="utf-8")
    (args.artifacts / "server.sha256").write_text(json.dumps(digest_file(args.server)) + "\n", encoding="ascii")
    results = {"optimization": "ReleaseSafe", "client_versions": expected, "large_bytes": LARGE_SIZE, "comparison_chunk_bound": CHUNK_SIZE, "allocation_scope": "Application comparison reads, file copies, and qlog writes are bounded. App/TLS/QUIC startup slabs and client-library internal allocations are not allocator-instrumented. No whole response body is retained by the harness."}
    try:
        with tempfile.TemporaryDirectory(prefix="uwz-static-interop-") as temporary:
            runtime = Path(temporary)
            results["fixtures"] = fixtures(runtime / "files")
            (args.artifacts / "fixtures.json").write_text(json.dumps(results["fixtures"], indent=2) + "\n", encoding="ascii")
            command(args.artifacts, "certificate_generation", ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1", "-keyout", str(runtime / "key.pem"), "-out", str(runtime / "cert.pem")])
            shutil.copyfile(runtime / "cert.pem", args.artifacts / "test_certificate.pem")
            command(args.artifacts, "certificate_identity", ["openssl", "x509", "-in", str(runtime / "cert.pem"), "-noout", "-sha256", "-fingerprint", "-dates"])
            cert = runtime / "cert.pem"
            run_server(args, runtime, "plain", [Endpoint(name="h1", version="1.1", flag="--http1.1", scheme="http", port=18880, cert=cert)], results)
            run_server(args, runtime, "tls", [Endpoint(name="h1", version="1.1", flag="--http1.1", scheme="https", port=18881, cert=cert), Endpoint(name="h2", version="2", flag="--http2", scheme="https", port=18881, cert=cert)], results)
            run_server(args, runtime, "h3", [Endpoint(name="h3", version="3", flag="--http3-only", scheme="https", port=18882, cert=cert)], results)
    finally:
        (args.artifacts / "results.json").write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
    print("static interop correctness gate passed; no throughput claim")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["run", "fixtures"])
    parser.add_argument("--source", type=Path)
    parser.add_argument("--artifacts", type=Path, required=True)
    parser.add_argument("--server", type=Path)
    args = parser.parse_args()
    if args.mode == "fixtures":
        print(json.dumps(fixtures(args.artifacts), indent=2))
        return
    require(args.source is not None and args.server is not None, "run requires --source and --server")
    gate_status = 1
    try:
        run(args)
        gate_status = 0
    finally:
        (args.artifacts / "client_gate.status").write_text(f"{gate_status}\n", encoding="ascii")


if __name__ == "__main__":
    main()
