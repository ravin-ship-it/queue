#!/usr/bin/env python3
"""
hybrid_bridge.py: High-speed UNIX Domain Socket to Windows Named Pipe Bridge
Connects WSL2 Queue (q) to native Windows mpv.exe with sub-millisecond latency.
"""
import os
import sys
import socket
import select
import subprocess
import signal

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
            bufsize=0
        )
    except Exception as e:
        sys.stderr.write(f"Failed to start PipeRelay: {e}\n")
        sys.exit(1)

    def cleanup(*args):
        try:
            proc.terminate()
            proc.kill()
        except Exception:
            pass
        if os.path.exists(socket_path):
            try:
                os.remove(socket_path)
            except OSError:
                pass
        sys.exit(0)

    signal.signal(signal.SIGINT, cleanup)
    signal.signal(signal.SIGTERM, cleanup)

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(socket_path)
    server.listen(16)
    server.setblocking(False)

    clients = set()
    inputs = [server, proc.stdout]

    while proc.poll() is None:
        try:
            readable, _, exceptional = select.select(inputs, [], inputs, 0.5)
        except (select.error, OSError):
            break

        for s in readable:
            if s is server:
                try:
                    client_sock, _ = server.accept()
                    client_sock.setblocking(False)
                    inputs.append(client_sock)
                    clients.add(client_sock)
                except OSError:
                    pass
            elif s is proc.stdout:
                line = proc.stdout.readline()
                if not line:
                    cleanup()
                for c in list(clients):
                    try:
                        c.sendall(line)
                    except OSError:
                        pass
            else:
                try:
                    data = s.recv(4096)
                    if data:
                        proc.stdin.write(data)
                        proc.stdin.flush()
                    else:
                        # Client finished sending, stop reading but keep open for response
                        if s in inputs:
                            inputs.remove(s)
                except OSError:
                    if s in inputs:
                        inputs.remove(s)
                    if s in clients:
                        clients.remove(s)
                    try:
                        s.close()
                    except OSError:
                        pass

        for s in exceptional:
            if s in inputs:
                inputs.remove(s)
            if s in clients:
                clients.remove(s)
            try:
                s.close()
            except OSError:
                pass

    cleanup()

if __name__ == "__main__":
    main()
