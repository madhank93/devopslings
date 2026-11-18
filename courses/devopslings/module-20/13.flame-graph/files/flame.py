"""flame.py FOLDED [MIN_PERCENT] — draw folded stacks as a text flame graph.

Each line is one frame: its share of all samples (time in it and everything it
called), then its share of samples where it was the frame actually running.
Children are indented under their caller, widest first; frames under
MIN_PERCENT (default 1) are left out.
"""
import sys

tree = {}
total = 0
for line in open(sys.argv[1]):
    stack, _, count = line.rstrip("\n").rpartition(" ")
    n = int(count)
    total += n
    node = tree
    frames = stack.split(";")
    for i, frame in enumerate(frames):
        entry = node.setdefault(frame, {"total": 0, "self": 0, "children": {}})
        entry["total"] += n
        if i == len(frames) - 1:
            entry["self"] += n
        node = entry["children"]

floor = float(sys.argv[2]) if len(sys.argv) > 2 else 1.0
print(f"{total} samples   total%  self%")


def show(node, depth):
    for frame, e in sorted(node.items(), key=lambda kv: -kv[1]["total"]):
        share = 100 * e["total"] / total
        if share < floor:
            continue
        print(f"{'  ' * depth}{frame:<{max(1, 48 - 2 * depth)}} {share:5.1f}  {100 * e['self'] / total:5.1f}")
        show(e["children"], depth + 1)


show(tree, 0)
