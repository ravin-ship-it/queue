#!/usr/bin/env python3
"""
hybrid_bridge.py: High-speed UNIX Domain Socket to Windows Named Pipe Bridge
Connects WSL2 Queue (q) to native Windows mpv.exe with sub-millisecond latency
and strict 1:1 request/response routing. Supports both native C# binary (PipeRelay.exe)
and Microsoft-signed PowerShell in-memory relay (PipeRelay.ps1) for Smart App Control / Device Guard.
"""
import os
import sys
import socket
import select
import subprocess
import signal
import re
import shutil
import time

def build_relay_cmd(target, pipe):
    if target.lower().endswith(".ps1"):
        win_ps1 = target
        try:
            r = subprocess.run(["wslpath", "-w", target], capture_output=True, text=True, check=True)
            win_ps1 = r.stdout.strip()
        except Exception:
            pass
        return ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", win_ps1, pipe]
    return [target, pipe]

def start_relay_proc(target, pipe):
    cmd = build_relay_cmd(target, pipe)
    return subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        bufsize=0,
        start_new_session=True
    )

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

    proc = None
    try:
        proc = start_relay_proc(relay_exe, pipe_name)
        time.sleep(0.08)
        if proc.poll() is not None and not relay_exe.lower().endswith(".ps1"):
            # Fallback to .ps1 if .exe is blocked by Windows Code Integrity / Smart App Control
            ps1_cand = os.path.splitext(relay_exe)[0] + ".ps1"
            if os.path.exists(ps1_cand):
                proc = start_relay_proc(ps1_cand, pipe_name)
    except Exception as e:
        if not relay_exe.lower().endswith(".ps1"):
            ps1_cand = os.path.splitext(relay_exe)[0] + ".ps1"
            if os.path.exists(ps1_cand):
                try:
                    proc = start_relay_proc(ps1_cand, pipe_name)
                except Exception:
                    pass
        if proc is None:
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
            lnx_cache = os.path.expanduser("~/.cache/mpv")
            win_users = "/mnt/c/Users"
            if os.path.isdir(win_users):
                for u in os.listdir(win_users):
                    if u not in ("Public", "Default", "All Users", "Default User"):
                        w_cache = os.path.join(win_users, u, ".cache", "mpv")
                        if os.path.isdir(w_cache):
                            for fname in ("state.json", "last_playlist.txt"):
                                w_f = os.path.join(w_cache, fname)
                                l_f = os.path.join(lnx_cache, fname)
                                if os.path.isfile(w_f):
                                    if not os.path.isfile(l_f) or os.path.getmtime(w_f) >= os.path.getmtime(l_f):
                                        shutil.copy2(w_f, l_f)
            v_act = os.path.join(lnx_cache, "video_active")
            if os.path.exists(v_act):
                try:
                    os.remove(v_act)
                except OSError:
                    pass
        except Exception:
            pass
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
                data = os.read(proc.stdout.fileno(), 65536)
                if not data:
                    break
                proc_stdout_buf += data
                while b'\n' in proc_stdout_buf:
                    line, proc_stdout_buf = proc_stdout_buf.split(b'\n', 1)
                    if not line.strip():
                        continue
                    m = req_id_regex.search(line)
                    if m:
                        rid = int(m.group(1))
                        target_sock = pending_requests.pop(rid, None)
                        if target_sock and target_sock in clients:
                            try:
                                target_sock.sendall(line + b'\n')
                                client_pending[target_sock] = max(0, client_pending.get(target_sock, 1) - 1)
                                if client_eof.get(target_sock, False) and client_pending[target_sock] == 0:
                                    close_client(target_sock)
                            except OSError:
                                close_client(target_sock)
                    else:
                        # Broadcast events (e.g. idle-active, playback-restart)
                        for c in list(clients):
                            try:
                                c.sendall(line + b'\n')
                            except OSError:
                                close_client(c)
            except OSError:
                pass

        # 3. Handle UNIX Client connections & commands
        if server in readable:
            try:
                client_sock, _ = server.accept()
                client_sock.setblocking(False)
                clients.add(client_sock)
                client_buffers[client_sock] = b''
                client_pending[client_sock] = 0
                client_eof[client_sock] = False
            except OSError:
                pass

        for s in list(clients):
            if s in readable:
                try:
                    data = s.recv(65536)
                    if not data:
                        client_eof[s] = True
                        if client_pending.get(s, 0) == 0 and not client_buffers.get(s):
                            close_client(s)
                        continue
                    client_buffers[s] = client_buffers.get(s, b'') + data
                    while b'\n' in client_buffers[s]:
                        line, client_buffers[s] = client_buffers[s].split(b'\n', 1)
                        cmd = line.strip()
                        if cmd:
                            if cmd.endswith(b'}'):
                                if b'\"request_id\"' not in cmd:
                                    rid = next_req_id
                                    next_req_id += 1
                                    tagged = cmd[:-1] + f',\"request_id\":{rid}}}\n'.encode()
                                    pending_requests[rid] = s
                                    client_pending[s] = client_pending.get(s, 0) + 1
                                    proc_stdin_buf += tagged
                                else:
                                    proc_stdin_buf += cmd + b'\n'
                            elif cmd:
                                proc_stdin_buf += cmd + b'\n'
                except OSError:
                    close_client(s)

        # 4. Handle any exceptional sockets
        for s in exceptional:
            if s in clients:
                close_client(s)

    cleanup()

if __name__ == "__main__":
    main()
