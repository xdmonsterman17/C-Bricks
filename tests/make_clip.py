#!/usr/bin/env python3
"""A tiny MPEG-1 video encoder (2026-11-20), so the repo has its own .mpg for the video test and the TV example
without ffmpeg: intra-only pictures (every frame a key frame), escape-coded AC coefficients, no audio, MPEG-PS.
Not a good encoder (the files are big for their quality); it only has to be a valid stream that pl_mpeg decodes.

    python3 tests/make_clip.py OUT.mpg [pattern] [seconds]       pattern: ball (default) | bars

Pure Python, no numpy: 128 x 96 at 25 fps, 3 seconds takes about 20 s.
"""
import math, struct, sys

W, H, FPS = 128, 96, 25
QSCALE = 6

ZIGZAG = [0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
          35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63]
INTRA = [8, 16, 19, 22, 26, 27, 29, 34, 16, 16, 22, 24, 27, 29, 34, 37, 19, 22, 26, 27, 29, 34, 34, 38, 22, 22, 26, 27, 29, 34, 37, 40,
         22, 26, 27, 29, 32, 35, 40, 48, 26, 27, 29, 32, 35, 40, 48, 58, 26, 27, 29, 34, 38, 46, 56, 69, 27, 29, 35, 38, 46, 56, 69, 83]
DC_LUMA = ["100", "00", "01", "101", "110", "1110", "11110", "111110", "1111110"]
DC_CHROMA = ["00", "01", "10", "110", "1110", "11110", "111110", "1111110", "11111110"]
COS = [[math.cos((2 * x + 1) * u * math.pi / 16) for x in range(8)] for u in range(8)]


class Bits:
    def __init__(self):
        self.bits = []

    def put(self, s):
        self.bits.append(s)

    def num(self, v, n):
        self.bits.append(format(v & ((1 << n) - 1), "0%db" % n))

    def align(self):
        s = "".join(self.bits)
        s += "0" * (-len(s) % 8)
        self.bits = [s]

    def bytes(self):
        self.align()
        s = self.bits[0] if self.bits else ""
        return bytes(int(s[i:i + 8], 2) for i in range(0, len(s), 8))


def dct8(block):  # block: 64 values (row-major) -> 64 coefficients, the MPEG-1 scaling (F00 = 8 * mean)
    tmp = [[0.0] * 8 for _ in range(8)]
    for y in range(8):  # rows
        for u in range(8):
            tmp[y][u] = sum(block[y * 8 + x] * COS[u][x] for x in range(8)) * (math.sqrt(0.5) if u == 0 else 1.0) * 0.5
    out = [0.0] * 64
    for u in range(8):
        for v in range(8):
            out[v * 8 + u] = sum(tmp[y][u] * COS[v][y] for y in range(8)) * (math.sqrt(0.5) if v == 0 else 1.0) * 0.5
    return out


def encode_block(bits, block, pred, chroma):
    f = dct8(block)
    dc = int(round(f[0] / 8.0))
    dc = max(0, min(255, dc))
    diff = dc - pred
    size = abs(diff).bit_length()
    bits.put((DC_CHROMA if chroma else DC_LUMA)[size])
    if size:
        bits.num(diff if diff > 0 else diff + (1 << size) - 1, size)
    run = 0
    for k in range(1, 64):
        pos = ZIGZAG[k]
        lvl = int(round(f[pos] * 8.0 / (QSCALE * INTRA[pos])))
        lvl = max(-127, min(127, lvl))
        if lvl == 0:
            run += 1
            continue
        bits.put("000001")
        bits.num(run, 6)
        bits.num(lvl, 8)
        run = 0
    bits.put("10")  # end of block
    return dc


def rgb_to_ycc(img):  # img[y][x] = (r, g, b) -> Y plane (W x H), Cb / Cr planes (W/2 x H/2)
    yp = [[0.0] * W for _ in range(H)]
    cb = [[0.0] * (W // 2) for _ in range(H // 2)]
    cr = [[0.0] * (W // 2) for _ in range(H // 2)]
    for y in range(H):
        for x in range(W):
            r, g, b = img[y][x]
            yp[y][x] = 16 + 0.257 * r + 0.504 * g + 0.098 * b
    for y in range(H // 2):
        for x in range(W // 2):
            rs = gs = bs = 0
            for dy in (0, 1):
                for dx in (0, 1):
                    r, g, b = img[2 * y + dy][2 * x + dx]
                    rs += r; gs += g; bs += b
            r, g, b = rs / 4, gs / 4, bs / 4
            cb[y][x] = 128 - 0.148 * r - 0.291 * g + 0.439 * b
            cr[y][x] = 128 + 0.439 * r - 0.368 * g - 0.071 * b
    return yp, cb, cr


def plane_block(p, bx, by):
    return [p[by + y][bx + x] for y in range(8) for x in range(8)]


def encode_picture(img, index):
    yp, cb, cr = rgb_to_ycc(img)
    out = bytearray()
    bits = Bits()
    bits.num(index & 0x3FF, 10)  # temporal reference
    bits.num(1, 3)               # I picture
    bits.num(0xFFFF, 16)         # vbv delay
    out += b"\x00\x00\x01\x00" + bits.bytes()
    for row in range(H // 16):
        b = Bits()
        b.num(QSCALE, 5)
        b.num(0, 1)  # no extra slice info
        pred = [128, 128, 128]
        for col in range(W // 16):
            b.put("1")  # macroblock address increment 1
            b.put("1")  # macroblock type: intra
            x0, y0 = col * 16, row * 16
            for (dx, dy) in ((0, 0), (8, 0), (0, 8), (8, 8)):
                pred[0] = encode_block(b, plane_block(yp, x0 + dx, y0 + dy), pred[0], False)
            pred[1] = encode_block(b, plane_block(cb, x0 // 2, y0 // 2), pred[1], True)
            pred[2] = encode_block(b, plane_block(cr, x0 // 2, y0 // 2), pred[2], True)
        out += b"\x00\x00\x01" + bytes([row + 1]) + b.bytes()
    return bytes(out)


def pattern_ball(i, n):
    t = i / float(n)
    bx = 20 + (W - 40) * (0.5 + 0.5 * math.sin(t * 2 * math.pi))
    by = 24 + (H - 48) * (0.5 + 0.5 * math.sin(t * 4 * math.pi))
    img = []
    for y in range(H):
        row = []
        for x in range(W):
            base = 40 + 140 * y // H
            c = (30 + base // 3, 60 + base // 2, 120 + base // 2)
            if ((x // 16) + (y // 16)) % 2 == 0:
                c = (c[0] + 20, c[1] + 20, c[2] + 20)
            d = math.hypot(x - bx, y - by)
            if d < 16:
                s = 1.0 - d / 24.0
                c = (int(255 * s + 40), int(200 * s + 30), int(40 * s))
            if y < 10 and x < 6 * (i % 20 + 1):  # a progress bar along the top: its length shows the frame
                c = (255, 255, 255)
            row.append(tuple(max(0, min(255, v)) for v in c))
        img.append(row)
    return img


def pattern_bars(i, n):
    cols = [(255, 255, 255), (255, 255, 0), (0, 255, 255), (0, 255, 0), (255, 0, 255), (255, 0, 0), (0, 0, 255), (20, 20, 20)]
    img = []
    shift = i * 2
    for y in range(H):
        img.append([cols[((x + shift) // 16) % 8] for x in range(W)])
    return img


def pts_bytes(pts):
    p = pts & 0x1FFFFFFFF
    return bytes([0x21 | ((p >> 29) & 0x0E), (p >> 22) & 0xFF, 0x01 | ((p >> 14) & 0xFE), (p >> 7) & 0xFF, 0x01 | ((p << 1) & 0xFE)])


def pack_header(scr):
    s = scr & 0x1FFFFFFFF
    b = bytes([0x21 | ((s >> 29) & 0x0E), (s >> 22) & 0xFF, 0x01 | ((s >> 14) & 0xFE), (s >> 7) & 0xFF, 0x01 | ((s << 1) & 0xFE)])
    rate = 20000  # units of 50 bytes / s
    return b"\x00\x00\x01\xba" + b + bytes([0x80 | (rate >> 15), (rate >> 7) & 0xFF, 0x01 | ((rate << 1) & 0xFE)])


def system_header():
    rate = 20000
    body = bytes([0x80 | (rate >> 15), (rate >> 7) & 0xFF, 0x01 | ((rate << 1) & 0xFE),
                  0x00 | 0x01,                 # audio_bound 0, fixed 0, csps 1
                  0x20 | 0x01,                 # lock flags 0, marker, video_bound 1
                  0xFF,                        # packet rate restriction + reserved
                  0xE0, 0xE0 | 0x00, 0x20])    # video stream 0xE0, P-STD buffer bound 32 * 1024
    return b"\x00\x00\x01\xbb" + struct.pack(">H", len(body)) + body


def pes(stream_id, payload, pts):
    data = (pts_bytes(pts) if pts is not None else b"\x0f") + payload   # (a packet with no time: the rest of a picture)
    return b"\x00\x00\x01" + bytes([stream_id]) + struct.pack(">H", len(data)) + data


def main():
    out = sys.argv[1]
    pattern = sys.argv[2] if len(sys.argv) > 2 else "ball"
    secs = float(sys.argv[3]) if len(sys.argv) > 3 else 3.0
    n = int(secs * FPS)
    make = pattern_ball if pattern == "ball" else pattern_bars
    # sequence header, bit by bit
    sb = Bits()
    sb.num(W, 12); sb.num(H, 12); sb.num(1, 4); sb.num(3, 4)  # 25 frames a second
    sb.num(0x3FFFF, 18); sb.num(1, 1); sb.num(20, 10); sb.num(0, 1); sb.num(0, 1); sb.num(0, 1)
    seq = b"\x00\x00\x01\xb3" + sb.bytes()
    gb = Bits()
    gb.num(0, 1); gb.num(0, 5); gb.num(0, 6); gb.num(1, 1); gb.num(0, 6); gb.num(0, 6); gb.num(1, 1); gb.num(0, 1)
    gop = b"\x00\x00\x01\xb8" + gb.bytes()
    stream = bytearray()
    stream += pack_header(0) + system_header()
    for i in range(n):
        pts = 90000 // 5 + i * 90000 // FPS   # (starts 0.2 s in, as muxers do)
        pic = encode_picture(make(i, n), i)
        payload = (seq + gop if i == 0 else gop) + pic
        for k in range(0, len(payload), 60000):  # a PES packet holds up to 65535 bytes
            stream += pack_header(pts - 9000 // 5) + pes(0xE0, payload[k:k + 60000], pts if k == 0 else None)
        sys.stderr.write("\rframe %d / %d" % (i + 1, n))
    stream += b"\x00\x00\x01\xb9"
    open(out, "wb").write(bytes(stream))
    sys.stderr.write("\nwrote %s (%d bytes, %d frames, %d x %d)\n" % (out, len(stream), n, W, H))


if __name__ == "__main__":
    main()
