#!/usr/bin/env python3
"""Loopback-only SSH fixture for production SshAdapter runtime tests."""

from __future__ import annotations

import argparse
import os
import signal
import socket
import threading
import time

import paramiko


FIRST_RESPONSE = "alpha-secret"
SECOND_RESPONSE = "beta-secret"
WINDOW_PAYLOAD_BYTES = 4 * 1024 * 1024


class RuntimeServer(paramiko.ServerInterface):
    def __init__(self, events_file: str) -> None:
        self._interactive_round = 0
        self._events_file = events_file
        self._events_lock = threading.Lock()

    def _record(self, event: str) -> None:
        with self._events_lock:
            with open(self._events_file, "a", encoding="utf-8") as events:
                events.write(event + "\n")

    def get_allowed_auths(self, username: str) -> str:
        del username
        return "keyboard-interactive"

    def check_auth_interactive(self, username: str, submethods: str):
        del username, submethods
        self._interactive_round = 1
        self._record("prompt:1")
        return paramiko.InteractiveQuery(
            "RemoteDesk runtime fixture",
            "First authentication round",
            ("First code:", False),
        )

    def check_auth_interactive_response(self, responses: list[str]):
        if self._interactive_round == 1 and responses == [FIRST_RESPONSE]:
            self._record("response:1:accepted")
            self._interactive_round = 2
            self._record("prompt:2")
            return paramiko.InteractiveQuery(
                "RemoteDesk runtime fixture",
                "Second authentication round",
                ("Second code:", False),
            )
        if self._interactive_round == 2 and responses == [SECOND_RESPONSE]:
            self._record("response:2:accepted")
            self._interactive_round = 3
            return paramiko.AUTH_SUCCESSFUL
        self._record(f"response:{self._interactive_round}:rejected")
        return paramiko.AUTH_FAILED

    def check_channel_request(self, kind: str, chanid: int) -> int:
        del chanid
        if kind == "session":
            return paramiko.OPEN_SUCCEEDED
        return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_pty_request(
        self, channel, term, width, height, pixelwidth, pixelheight, modes
    ) -> bool:
        del channel, term, width, height, pixelwidth, pixelheight, modes
        return True

    def check_channel_env_request(self, channel, name, value) -> bool:
        del channel, name, value
        return True

    def check_channel_window_change_request(
        self, channel, width, height, pixelwidth, pixelheight
    ) -> bool:
        del channel, width, height, pixelwidth, pixelheight
        return True

    def check_channel_shell_request(self, channel) -> bool:
        def announce() -> None:
            try:
                channel.sendall(b"runtime-shell-ready\n")
            except OSError:
                pass

        threading.Thread(target=announce, daemon=True).start()
        return True

    def check_channel_exec_request(self, channel, command: bytes) -> bool:
        if command != b"runtime-window-adjust":
            return False

        def stream_output() -> None:
            block = b"W" * 32768
            remaining = WINDOW_PAYLOAD_BYTES
            try:
                while remaining > 0:
                    sent = channel.send(block[: min(len(block), remaining)])
                    if sent <= 0:
                        return
                    remaining -= sent
                channel.send_exit_status(0)
                channel.shutdown_write()
            except (EOFError, OSError, paramiko.SSHException):
                pass

        threading.Thread(target=stream_output, daemon=True).start()
        return True


class Fixture:
    def __init__(self, port: int, ready_file: str, events_file: str) -> None:
        self._port = port
        self._ready_file = ready_file
        self._events_file = events_file
        self._stop = threading.Event()
        self._listener: socket.socket | None = None
        self._workers: list[threading.Thread] = []
        self._host_key = paramiko.RSAKey.generate(2048)

    def stop(self, *_args) -> None:
        self._stop.set()
        listener = self._listener
        if listener is not None:
            try:
                listener.close()
            except OSError:
                pass

    def _handle(self, client: socket.socket) -> None:
        transport = paramiko.Transport(client)
        transport.add_server_key(self._host_key)
        try:
            transport.start_server(server=RuntimeServer(self._events_file))
            while transport.is_active() and not self._stop.wait(0.05):
                transport.accept(0.05)
        except (EOFError, OSError, paramiko.SSHException):
            pass
        finally:
            transport.close()
            client.close()

    def run(self) -> int:
        listener = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        listener.bind(("::1", self._port))
        listener.listen(16)
        listener.settimeout(0.1)
        self._listener = listener
        with open(self._ready_file, "w", encoding="utf-8") as ready:
            ready.write(str(os.getpid()))

        while not self._stop.is_set():
            try:
                client, _address = listener.accept()
            except TimeoutError:
                continue
            except OSError:
                if self._stop.is_set():
                    break
                raise
            worker = threading.Thread(target=self._handle, args=(client,), daemon=True)
            self._workers.append(worker)
            worker.start()

        for worker in self._workers:
            worker.join(timeout=1.0)
        return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--ready-file", required=True)
    parser.add_argument("--events-file", required=True)
    args = parser.parse_args()
    fixture = Fixture(args.port, args.ready_file, args.events_file)
    signal.signal(signal.SIGTERM, fixture.stop)
    signal.signal(signal.SIGINT, fixture.stop)
    return fixture.run()


if __name__ == "__main__":
    raise SystemExit(main())
