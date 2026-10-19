#!/usr/bin/env python3
"""
hybrid_bridge.py: High-speed UNIX Domain Socket to Windows Named Pipe Bridge
Connects WSL2 Queue (q) to native Windows mpv.exe with sub-millisecond latency
and strict 1:1 request/response routing.
"""
import os
import sys
import socket
import select
import subprocess
import signal
import re

def main():
    if len(sys.argv) < 3:
        print("Usage: hybrid_bridge.py <socket_path> <pipe_name> [relay_exe]")
        sys.exit(1)

    socket_path = sys.argv[1]
    pipe_name = sys.argv[2]
    relay_exe = sys.argv[3] if len(sys.argv) > 3 else "PipeRelay.exe"

    if os.path.exists(socket_path):
        try:
            os.remove(socket_path)
        except OSError:
            pass

    try:
        proc = subprocess.Popen(
            [relay_exe, pipe_name],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            bufsize=0,
            start_new_session=True
        )
    except Exception as e:
        sys.stderr.write(f"Failed to start PipeRelay: {e}\n")
        sys.exit(1)

    os.set_blocking(proc.stdin.fileno(), False)
    os.set_blocking(proc.stdout.fileno(), False)

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(socket_path)
    server.listen(64)
    server.setblocking(False)

    clients = set()
    client_buffers = {}
    client_pending = {}
    client_eof = {}
    pending_requests = {}
    next_req_id = 1

    proc_stdin_buf = b''
    proc_stdout_buf = b''

    req_id_regex = re.compile(rb'\"request_id\":\s*(\d+)')

    def close_client(c):
        clients.discard(c)
        client_buffers.pop(c, None)
        client_pending.pop(c, None)
        client_eof.pop(c, None)
        for rid, sock in list(pending_requests.items()):
            if sock is c:
                del pending_requests[rid]
        try:
            c.close()
        except OSError:
            pass

    def cleanup(*args):
        try:
            proc.terminate()
            proc.kill()
        except Exception:
            pass
        for c in list(clients):
            close_client(c)
        try:
            server.close()
        except Exception:
            pass
        if os.path.exists(socket_path):
            try:
                os.remove(socket_path)
            except OSError:
                pass
        sys.exit(0)

    try:
        signal.signal(signal.SIGHUP, signal.SIG_IGN)
    except (AttributeError, ValueError):
        pass
    signal.signal(signal.SIGINT, cleanup)
    signal.signal(signal.SIGTERM, cleanup)

    while proc.poll() is None:
        inputs = [server, proc.stdout] + list(clients)
        outputs = [proc.stdin] if proc_stdin_buf else []
        try:
            readable, writable, exceptional = select.select(inputs, outputs, inputs, 0.05)
        except (select.error, OSError):
            inputs = [s for s in inputs if hasattr(s, 'fileno') and s.fileno() != -1]
            continue

        # 1. PipeRelay STDIN (write commands to Windows MPV)
        if proc.stdin in writable and proc_stdin_buf:
            try:
                n = os.write(proc.stdin.fileno(), proc_stdin_buf[:65536])
                proc_stdin_buf = proc_stdin_buf[n:]
            except OSError:
                pass

        # 2. PipeRelay STDOUT (read responses from Windows MPV)
        if proc.stdout in readable:
            try:
                chunk = os.read(proc.stdout.fileno(), 65536)
                if not chunk:
                    break  # Relay closed
                proc_stdout_buf += chunk
                while b'\n' in proc_stdout_buf:
                    line, proc_stdout_buf = proc_stdout_buf.split(b'\n', 1)
                    line = line + b'\n'
                    m = req_id_regex.search(line)
                    if m:
                        rid = int(m.group(1))
                        csock = pending_requests.pop(rid, None)
                        if csock and csock in clients:
                            try:
                                csock.sendall(line)
                            except OSError:
                                close_client(csock)
                                continue
                            client_pending[csock] = client_pending.get(csock, 1) - 1
                            if client_pending[csock] <= 0 and client_eof.get(csock, False):
                                close_client(csock)
                    else:
                        # Async event line - route only to long-lived interactive clients
                        for csock in list(clients):
                            if not client_eof.get(csock, False):
                                try:
                                    csock.sendall(line)
                                except OSError:
                                    close_client(csock)
            except OSError:
                pass

        # 3. Server & Client UNIX Sockets
        for s in readable:
            if s is server:
                try:
                    csock, _ = server.accept()
                    csock.settimeout(10.0)
                    clients.add(csock)
                    client_buffers[csock] = b''
                    client_pending[csock] = 0
                    client_eof[csock] = False
                except OSError:
                    pass
            elif s in clients:
                try:
                    data = s.recv(65536)
                    if not data:
                        # Client write EOF (shutdown write side)
                        client_eof[s] = True
                        if client_pending.get(s, 0) <= 0:
                            close_client(s)
                    else:
                        client_buffers[s] += data
                        while b'\n' in client_buffers[s]:
                            cmd, client_buffers[s] = client_buffers[s].split(b'\n', 1)
                            cmd = cmd.strip()
                            if not cmd:
                                continue
                            if cmd.startswith(b'{') and cmd.endswith(b'}'):
                                rid = next_req_id
                                next_req_id += 1
                                tagged = cmd[:-1] + f',\"request_id\":{rid}}}\n'.encode()
                                pending_requests[rid] = s
                                client_pending[s] = client_pending.get(s, 0) + 1
                                proc_stdin_buf += tagged
                except OSError:
                    close_client(s)

        # 4. Handle any exceptional sockets
        for s in exceptional:
            if s in clients:
                close_client(s)

    cleanup()

if __name__ == "__main__":
    main()
