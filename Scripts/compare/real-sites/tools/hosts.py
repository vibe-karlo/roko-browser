#!/usr/bin/env python3
"""Reads capture files with no extra tools: names from DNS queries and answers, TLS ClientHello
SNI, and which address each connection went to. Prints one line per name a connection or lookup
used: time, name, via. Usage: hosts.py file.pcap ... > hosts.jsonl"""
import json, struct, sys
def name(buf, o, depth=0):
    parts = []
    while o < len(buf) and depth < 12:
        n = buf[o]
        if n == 0: return ".".join(parts), o + 1
        if n & 0xc0 == 0xc0:
            p = ((n & 0x3f) << 8) | buf[o + 1]
            rest, _ = name(buf, p, depth + 1)
            return ".".join(parts + [rest]), o + 2
        parts.append(buf[o + 1:o + 1 + n].decode("latin1")); o += 1 + n
    return ".".join(parts), o + 1
def dns(buf):
    flags, qd, an = struct.unpack("!HHH", buf[2:8]); o = 12; q = []
    for _ in range(qd):
        n, o = name(buf, o); qt = struct.unpack("!H", buf[o:o + 2])[0]; o += 4; q.append((n, qt))
    ans = []
    if flags & 0x8000:
        for _ in range(an):
            n, o = name(buf, o); t, _, _, l = struct.unpack("!HHIH", buf[o:o + 10]); o += 10
            if t == 1 and l == 4: ans.append((n, ".".join(map(str, buf[o:o + 4]))))
            if t == 28 and l == 16: ans.append((n, buf[o:o + 16].hex()))
            o += l
    return bool(flags & 0x8000), q, ans
def sni(buf):
    if len(buf) < 6 or buf[0] != 22 or buf[5] != 1: return None
    o = 5 + 4 + 2 + 32; o += 1 + buf[o]; o += 2 + struct.unpack("!H", buf[o:o + 2])[0]; o += 1 + buf[o]
    end = o + 2 + struct.unpack("!H", buf[o:o + 2])[0]; o += 2
    while o + 4 <= end and o + 4 <= len(buf):
        t, l = struct.unpack("!HH", buf[o:o + 4]); o += 4
        if t == 0: return buf[o + 5:o + l].decode("latin1")
        o += l
for path in sys.argv[1:]:
    data = open(path, "rb").read()
    # Apple's tcpdump writes pcapng blocks here, behind a classic header when files rotate.
    o = 24 if data[24:28] == b"\n\r\r\n" else 0
    procs = []
    while o + 12 <= len(data):
        kind, size = struct.unpack("<II", data[o:o + 8])
        # A rotated file has the old format's 24-byte header in the middle of its blocks.
        if kind == 0xa1b2c3d4: o += 24; continue
        if size < 12 or o + size > len(data): break
        b = data[o + 8:o + size - 4]; o += size
        if kind == 0x0A0D0D0A: procs = []
        if kind == 0x80000001:
            pid = struct.unpack("<I", b[:4])[0]; n = struct.unpack("<H", b[6:8])[0]
            procs.append((pid, b[8:8 + n].decode("latin1"))); continue
        if kind != 6: continue
        _, hi, lo, cap, _ = struct.unpack("<IIIII", b[:20]); pkt = b[20:20 + cap]; t = ((hi << 32) | lo) / 1e6
        p = 20 + ((cap + 3) & ~3); proc = eproc = None
        while p + 4 <= len(b):
            code, l = struct.unpack("<HH", b[p:p + 4])
            if code == 0: break
            if code == 0x8001 and l >= 4: proc = struct.unpack("<I", b[p + 4:p + 8])[0]
            if code == 0x8003 and l >= 4: eproc = struct.unpack("<I", b[p + 4:p + 8])[0]
            p += 4 + ((l + 3) & ~3)
        who = lambda i: procs[i][1] if i is not None and i < len(procs) else None
        try:
            ip = pkt[14:]; v = ip[0] >> 4
            if v == 4: proto, dst, l4 = ip[9], ".".join(map(str, ip[16:20])), ip[(ip[0] & 15) * 4:]
            elif v == 6: proto, dst, l4 = ip[6], ip[24:40].hex(), ip[40:]
            else: continue
            sp, dp = struct.unpack("!HH", l4[:4]); base = {"t": t, "p": who(proc), "e": who(eproc)}
            if proto == 17 and 53 in (sp, dp):
                resp, q, ans = dns(l4[8:])
                if not resp:
                    for n, _ in q: print(json.dumps({**base, "name": n.lower(), "via": "dns"}))
                for n, addr in ans: print(json.dumps({"t": t, "name": n.lower(), "addr": addr, "via": "answer"}))
            elif proto == 6 and dp == 443:
                flags = l4[13]; pl = l4[(l4[12] >> 4) * 4:]
                if flags & 2 and not flags & 16: print(json.dumps({**base, "dst": dst, "via": "syn"}))
                s = sni(pl) if pl else None
                if s: print(json.dumps({**base, "name": s.lower(), "dst": dst, "via": "sni"}))
            elif proto == 17 and dp == 443: print(json.dumps({**base, "dst": dst, "via": "quic"}))
        except (struct.error, IndexError, UnicodeError):
            pass
