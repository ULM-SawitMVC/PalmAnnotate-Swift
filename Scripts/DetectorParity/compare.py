"""Require a one-to-one match within one original-image pixel on every edge.

Usage: compare.py [--tolerance PIXELS] ANDROID_REPORT IOS_REPORT

A larger tolerance (for example 5) keeps the exit status strict about the count and class but lets
the report measure how far apart boxes are that miss the 1 px target.
"""

import math
import sys
from pathlib import Path


def read(path):
    images = {}
    current = None
    for line in Path(path).read_text().splitlines():
        if line.startswith("PALM_DETECT_BEGIN "):
            name = line.removeprefix("PALM_DETECT_BEGIN ")
            if current is not None or name in images:
                raise ValueError(f"{path}: unexpected start of {name}")
            current = images[name] = []
        elif line.startswith("PALM_DETECT_BOX "):
            identifier, class_id, conf, *box = line.removeprefix("PALM_DETECT_BOX ").split(",")
            values = tuple(map(float, [conf, *box]))
            if (current is None or identifier != f"det{len(current)}" or len(values) != 5
                    or not all(map(math.isfinite, values))):
                raise ValueError(f"{path}: invalid prediction {line!r}")
            current.append((int(class_id), *values))
        elif line == "PALM_DETECT_END":
            if current is None:
                raise ValueError(f"{path}: unexpected end")
            current = None
    if current is not None or not images:
        raise ValueError(f"{path}: incomplete or missing results")
    return images


def edge_delta(a, b):
    return max(abs(x - y) for x, y in zip(a[2:], b[2:]))


def match(reference, swift, tolerance=1):
    # Match by coordinates and class. Confidence can shift rank between platforms.
    choices = [
        sorted((j for j, b in enumerate(swift) if a[0] == b[0] and edge_delta(a, b) <= tolerance),
               key=lambda j: edge_delta(a, swift[j]))
        for a in reference
    ]
    pairs = {}

    def assign(i, tried):
        for j in choices[i]:
            if j in tried:
                continue
            tried.add(j)
            if j not in pairs or assign(pairs[j], tried):
                pairs[j] = i
                return True
        return False

    for i in range(len(reference)):
        assign(i, set())
    return pairs


def main(reference, swift, tolerance):
    if reference.keys() != swift.keys():
        raise ValueError("Results contain different JPEGs")
    passed = any(reference.values())
    for name, a in reference.items():
        b = swift[name]
        pairs = match(a, b, tolerance)
        count = len(pairs)
        edge = max((edge_delta(a[i], b[j]) for j, i in pairs.items()), default=0)
        confidence = max((abs(a[i][1] - b[j][1]) for j, i in pairs.items()), default=0)
        rank = sum(i != j for j, i in pairs.items())
        classes = sorted({row[0] for row in a}), sorted({row[0] for row in b})
        unmatched = [f"android {row[1]:.4f}" for i, row in enumerate(a) if i not in pairs.values()]
        unmatched += [f"ios {row[1]:.4f}" for j, row in enumerate(b) if j not in pairs]
        print(f"{name}: counts={len(a)}/{len(b)}, classes={classes[0]}/{classes[1]}, "
              f"within {tolerance:g} px={count}, max matched edge delta={edge:.6f} px, "
              f"max matched confidence delta={confidence:.8f}, rank changes={rank}"
              + (f", unmatched scores: {', '.join(unmatched)}" if unmatched else ""))
        if count != len(a) or count != len(b) or any(row[0] != -1 for row in a + b):
            passed = False
    return 0 if passed else 1


if __name__ == "__main__":
    arguments = sys.argv[1:]
    tolerance = 1.0
    if arguments[:1] == ["--tolerance"]:
        tolerance = float(arguments[1])
        arguments = arguments[2:]
    sys.exit(main(*(read(path) for path in arguments), tolerance))
