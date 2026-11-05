#!/usr/bin/env python3
"""A logging proxy for comparing what browsers download from real sites.

    Scripts/compare/proxy.py [port]

Point the iPhone's Wi-Fi at it (Settings, Wi-Fi, the network, Configure Proxy,
Manual: the Mac's address and this port). HTTPS stays encrypted and is only passed
along: this sees which server each connection goes to and how many bytes moved,
never the pages. run_sites.sh names what's being tested in sites-label.txt, and
each connection is written to sites.jsonl under that name.
"""
import json, pathlib, select, socket, sys, threading, time

here = pathlib.Path(__file__).parent
label_file, out = here / "sites-label.txt", here / "sites.jsonl"
lock = threading.Lock()


def pump(client, server):
    sizes = {client: 0, server: 0}
    other = {client: server, server: client}
    while True:
        ready, _, _ = select.select([client, server], [], [], 120)
        if not ready:
            return sizes[client], sizes[server]
        for sock in ready:
            data = sock.recv(65536)
            if not data:
                return sizes[client], sizes[server]
            sizes[sock] += len(data)
            other[sock].sendall(data)


def handle(client):
    started, host, up, down = time.time(), None, 0, 0
    label = label_file.read_text().strip() if label_file.exists() else "?"
    server = None
    try:
        head = b""
        while b"\r\n\r\n" not in head and len(head) < 65536:
            piece = client.recv(4096)
            if not piece:
                return
            head += piece
        line = head.split(b"\r\n")[0].decode("latin1").split()
        if line[0] == "CONNECT":
            host, port = line[1].rsplit(":", 1)
            server = socket.create_connection((host, int(port)), timeout=15)
            client.sendall(b"HTTP/1.1 200 OK\r\n\r\n")
        else:
            target = line[1].split("//", 1)[-1].split("/", 1)
            host, port = (target[0].rsplit(":", 1) + ["80"])[:2]
            server = socket.create_connection((host, int(port)), timeout=15)
            path = "/" + (target[1] if len(target) > 1 else "")
            server.sendall(head.replace(line[1].encode("latin1"), path.encode("latin1"), 1))
        up, down = pump(client, server)
    except (OSError, IndexError, ValueError):
        pass
    finally:
        client.close()
        if server:
            server.close()
        if host:
            with lock, open(out, "a") as log:
                log.write(json.dumps({"label": label, "host": host, "up": up, "down": down, "start": started, "end": time.time()}) + "\n")


listener = socket.socket()
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(("0.0.0.0", int(sys.argv[1]) if len(sys.argv) > 1 else 8766))
listener.listen(256)
while True:
    connection, _ = listener.accept()
    threading.Thread(target=handle, args=(connection,), daemon=True).start()
