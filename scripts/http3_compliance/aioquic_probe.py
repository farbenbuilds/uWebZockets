#!/usr/bin/env python3

import argparse
import asyncio
import hashlib
import json
import logging
import ssl
from dataclasses import dataclass, field
from pathlib import Path
from typing import cast

import aioquic
from aioquic.asyncio.client import connect
from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import ConnectionTerminated, StreamReset
from aioquic.quic.logger import QuicFileLogger


@dataclass
class ResponseState:
    future: asyncio.Future
    headers: list[tuple[bytes, bytes]] = field(default_factory=list)
    body: bytearray = field(default_factory=bytearray)


class ProbeProtocol(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.http = H3Connection(self._quic)
        self.responses: dict[int, ResponseState] = {}

    async def request(
        self,
        headers: list[tuple[bytes, bytes]],
        timeout: float,
        trailers: list[tuple[bytes, bytes]] | None = None,
    ):
        stream_id = self._quic.get_next_available_stream_id()
        state = ResponseState(asyncio.get_running_loop().create_future())
        self.responses[stream_id] = state
        self.http.send_headers(stream_id, headers, end_stream=trailers is None)
        if trailers is not None:
            self.http.send_data(stream_id, b"body", end_stream=False)
            self.http.send_headers(stream_id, trailers, end_stream=True)
        self.transmit()
        try:
            return await asyncio.wait_for(asyncio.shield(state.future), timeout)
        except asyncio.TimeoutError:
            self.responses.pop(stream_id, None)
            return {"outcome": "timeout", "stream_id": stream_id}

    def quic_event_received(self, event):
        if isinstance(event, StreamReset):
            self._finish(
                event.stream_id,
                {"outcome": "stream_reset", "error_code": event.error_code},
            )
        elif isinstance(event, ConnectionTerminated):
            result = {
                "outcome": "connection_terminated",
                "error_code": event.error_code,
                "reason": event.reason_phrase,
            }
            for stream_id in list(self.responses):
                self._finish(stream_id, result)

        for http_event in self.http.handle_event(event):
            state = self.responses.get(http_event.stream_id)
            if state is None:
                continue
            if isinstance(http_event, HeadersReceived):
                state.headers.extend(http_event.headers)
            elif isinstance(http_event, DataReceived):
                state.body.extend(http_event.data)
            if http_event.stream_ended:
                status = next(
                    (
                        int(value)
                        for name, value in state.headers
                        if name == b":status"
                    ),
                    0,
                )
                self._finish(
                    http_event.stream_id,
                    {
                        "outcome": "response" if status < 400 else "http_error",
                        "status": status,
                        "body": bytes(state.body).decode("utf-8", "replace"),
                    },
                )

    def _finish(self, stream_id: int, result: dict):
        state = self.responses.pop(stream_id, None)
        if state is not None and not state.future.done():
            state.future.set_result(result)


def request_headers(authority: bytes) -> list[tuple[bytes, bytes]]:
    return [
        (b":method", b"GET"),
        (b":scheme", b"https"),
        (b":authority", authority),
        (b":path", b"/"),
        (b"user-agent", b"uwebzockets-aioquic-compliance"),
    ]


def malformed_headers(name: str, authority: bytes):
    base = request_headers(authority)
    if name == "duplicate_method":
        return [base[0], (b":method", b"GET"), *base[1:]]
    if name == "connection_specific_header":
        return [*base, (b"connection", b"keep-alive")]
    if name == "pseudo_header_after_regular":
        return [base[0], base[1], base[2], base[4], base[3]]
    raise ValueError(f"unknown malformed case: {name}")


async def run(args):
    expectations = json.loads(args.expectations.read_text(encoding="utf-8"))
    expected_version = expectations["clients"]["aioquic"]["version"]
    if aioquic.__version__ != expected_version:
        raise RuntimeError(
            f"aioquic version {aioquic.__version__} != {expected_version}"
        )

    authority = f"{args.host}:{args.port}".encode()
    accepted = set(expectations["accepted_rejections"])
    expected_stream_error = expectations["malformed_stream_error"]
    expected_response = expectations["response"]
    results = {
        "aioquic_version": aioquic.__version__,
        "malformed": {},
        "malformed_siblings": {},
    }
    configuration = QuicConfiguration(is_client=True, alpn_protocols=H3_ALPN)
    configuration.verify_mode = ssl.CERT_NONE
    configuration.quic_logger = QuicFileLogger(str(args.qlog_dir))
    async with connect(
        args.host,
        args.port,
        configuration=configuration,
        create_protocol=ProbeProtocol,
        wait_connected=True,
    ) as connected:
        protocol = cast(ProbeProtocol, connected)
        results["positive"] = await protocol.request(
            request_headers(authority), args.timeout
        )
        positive = results["positive"]
        assert_response("positive request", positive, expected_response)
        digest = hashlib.sha256(positive["body"].encode()).hexdigest()
        if digest != expected_response["body_sha256"]:
            raise RuntimeError(f"unexpected response digest: {digest}")

        results["trailers"] = await protocol.request(
            request_headers(authority),
            args.timeout,
            [(b"x-checksum", b"complete")],
        )
        assert_response("request trailers", results["trailers"], expected_response)

        for case in expectations["malformed_cases"]:
            malformed_request = asyncio.create_task(
                protocol.request(malformed_headers(case, authority), args.timeout)
            )
            sibling_request = asyncio.create_task(
                protocol.request(request_headers(authority), args.timeout)
            )
            outcome, sibling = await asyncio.gather(
                malformed_request,
                sibling_request,
            )
            results["malformed"][case] = outcome
            results["malformed_siblings"][case] = sibling
            if outcome.get("outcome") not in accepted:
                raise RuntimeError(
                    f"malformed request was not rejected: {case}: {outcome}"
                )
            if outcome.get("error_code") != expected_stream_error:
                raise RuntimeError(
                    f"malformed request used wrong stream error: {case}: {outcome}"
                )
            assert_response(f"sibling request for {case}", sibling, expected_response)

        results["post_malformed_health"] = await protocol.request(
            request_headers(authority), args.timeout
        )
    health = results["post_malformed_health"]
    assert_response("post-malformed health request", health, expected_response)
    return results


def assert_response(label: str, result: dict, expected: dict):
    if result.get("outcome") != "response":
        raise RuntimeError(f"{label} failed: {result}")
    if result.get("status") != expected["status"]:
        raise RuntimeError(f"{label} returned unexpected status: {result}")
    if result.get("body") != expected["body"]:
        raise RuntimeError(f"{label} returned unexpected body: {result}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--expectations", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--qlog-dir", type=Path, required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8443)
    parser.add_argument("--timeout", type=float, default=5.0)
    args = parser.parse_args()
    args.qlog_dir.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(level=logging.INFO)
    results = asyncio.run(run(args))
    args.output.write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
