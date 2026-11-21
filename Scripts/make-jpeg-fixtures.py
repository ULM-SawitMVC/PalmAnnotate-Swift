#!/usr/bin/env python3
import base64, hashlib, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "Packages", "PalmCore", "Tests", "PalmCoreTests", "JPEGFixtures.swift")

def synthetic(width, height):
    state = 12345
    rows = bytearray()
    for y in range(height):
        for x in range(width):
            state = (state * 1103515245 + 12345) & 0x7FFFFFFF
            noise = (state >> 16) % 48
            r = (x * 255 // max(width - 1, 1) + noise) % 256
            g = (y * 255 // max(height - 1, 1) + noise // 2) % 256
            b = ((x + y) * 255 // max(width + height - 2, 1)) % 256
            if (x // 7 + y // 5) % 3 == 0:
                r, g, b = 255 - r, b, 255 if (x + y) % 2 else 0
            if x < width // 4 and y < height // 4:
                r, g, b = 255, 0, 0
            if x > 3 * width // 4 and y > 3 * height // 4:
                r, g, b = 0, 0, 255
            rows += bytes((r, g, b))
    return b"P6\n%d %d\n255\n" % (width, height) + bytes(rows)

def ppm_payload(data):
    fields = data.split(None, 4)
    assert fields[0] == b"P6" and fields[3] == b"255"
    width, height = int(fields[1]), int(fields[2])
    payload = data[len(data) - width * height * 3:]
    return width, height, payload

CASES = [
    ("baseline420", 64, 48, ["-sample", "2x2"]),
    ("baseline420Odd", 63, 47, ["-sample", "2x2"]),
    ("baseline422Odd", 63, 47, ["-sample", "2x1"]),
    ("baseline440Odd", 63, 47, ["-sample", "1x2"]),
    ("baseline444Odd", 63, 47, ["-sample", "1x1"]),
    ("baseline411Odd", 61, 45, ["-sample", "4x1"]),
    ("baseline420Tiny", 5, 3, ["-sample", "2x2"]),
    ("baseline420Restart", 63, 47, ["-sample", "2x2", "-restart", "2"]),
    ("baseline420Quality95", 64, 48, ["-sample", "2x2", "-quality", "95"]),
    ("baseline420Quality30", 64, 48, ["-sample", "2x2", "-quality", "30"]),
    ("optimized420Odd", 63, 47, ["-sample", "2x2", "-optimize"]),
    ("progressive420Odd", 63, 47, ["-sample", "2x2", "-progressive"]),
    ("progressive422Odd", 63, 47, ["-sample", "2x1", "-progressive"]),
    ("progressive444Odd", 63, 47, ["-sample", "1x1", "-progressive"]),
    ("grayscaleOdd", 63, 47, ["-grayscale"]),
    ("rgbColorSpace", 63, 47, ["-rgb"]),
    ("arithmetic420Odd", 63, 47, ["-sample", "2x2", "-arithmetic"]),
]
REJECTED = [("twelveBit", 32, 32, ["-precision", "12"])]

def run(arguments, stdin=None):
    return subprocess.run(arguments, input=stdin, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout

def main():
    lines = []
    for name, width, height, extra in CASES:
        jpeg = run(["cjpeg"] + extra, synthetic(width, height))
        w, h, payload = ppm_payload(run(["djpeg", "-rgb", "-pnm"], jpeg))
        assert (w, h) == (width, height)
        lines.append('    JPEGFixture(name: "%s", width: %d, height: %d, rgbSHA256: "%s",\n        base64: "%s"),'
                     % (name, w, h, hashlib.sha256(payload).hexdigest(), base64.b64encode(jpeg).decode()))
    rejected = []
    for name, width, height, extra in REJECTED:
        jpeg = run(["cjpeg"] + extra, synthetic(width, height))
        rejected.append('    ("%s", "%s"),' % (name, base64.b64encode(jpeg).decode()))
    with open(OUT, "w") as out:
        out.write("struct JPEGFixture {\n    let name: String\n    let width: Int\n    let height: Int\n"
                  "    let rgbSHA256: String\n    let base64: String\n}\n\n"
                  "let jpegFixtures: [JPEGFixture] = [\n" + "\n".join(lines) + "\n]\n\n"
                  "let rejectedJPEGFixtures: [(name: String, base64: String)] = [\n" + "\n".join(rejected) + "\n]\n")
    print("wrote", os.path.normpath(OUT), file=sys.stderr)

main()
