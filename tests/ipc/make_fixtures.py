#!/usr/bin/env python3
"""Writes the crafted Arrow IPC streams of this directory: standard library only.

    python3 tests/ipc/make_fixtures.py

Each file is a small stream that no usual writer makes (see README.md for the
list). The output is the same on every run. The FlatBuffers are laid out
forwards: a table, then what it points to.
"""
import os
import struct

END = b"\xff\xff\xff\xff\x00\x00\x00\x00"
V4, V5 = 3, 4


class Table:
    def __init__(self, *fields):
        self.fields = fields            # (kind, value) or None for an absent field


class Vec:
    """A vector of tables or strings (`items`), or of structs (`structs`, `size` bytes each).

    `claim` writes another length than the true one. `shared` writes that many
    slots, all pointing to the one item.
    """

    def __init__(self, items=(), structs=None, size=16, claim=None, shared=None):
        self.items, self.structs, self.size, self.claim, self.shared = list(items), structs, size, claim, shared


SIZES = {"u8": (1, "<B"), "i16": (2, "<h"), "i32": (4, "<i"), "i64": (8, "<q"), "off": (4, "<I")}


def pad(buf, n):
    while len(buf) % n:
        buf.append(0)


def emit(buf, obj):
    """Appends `obj` and returns the position a reference points to."""
    if isinstance(obj, str):
        data = obj.encode()
        pad(buf, 4)
        pos = len(buf)
        buf += struct.pack("<I", len(data)) + data + b"\0"
        return pos
    if isinstance(obj, Vec):
        if obj.structs is not None:                 # structs of int64: align the elements to 8
            pad(buf, 4)
            if (len(buf) + 4) % 8:
                buf += b"\0\0\0\0"
            pos = len(buf)
            count = len(obj.structs) // obj.size
            buf += struct.pack("<I", count if obj.claim is None else obj.claim) + obj.structs
            return pos
        pad(buf, 4)
        pos = len(buf)
        count = len(obj.items) if obj.shared is None else obj.shared
        buf += struct.pack("<I", count if obj.claim is None else obj.claim)
        slots = len(buf)
        buf += b"\0" * (4 * count)
        if obj.shared is not None:
            target = emit(buf, obj.items[0])
            for i in range(count):
                at = slots + 4 * i
                struct.pack_into("<I", buf, at, target - at)
            return pos
        for i, item in enumerate(obj.items):
            at = slots + 4 * i
            struct.pack_into("<I", buf, at, emit(buf, item) - at)
        return pos
    # A table: its vtable, then the table (aligned to 8 so that an int64 field can be).
    pad(buf, 2)
    vtable = len(buf)
    buf += b"\0" * (4 + 2 * len(obj.fields))
    pad(buf, 8)
    pos = len(buf)
    buf += struct.pack("<i", pos - vtable)
    later = []
    for k, field in enumerate(obj.fields):
        if field is None:
            continue
        kind, value = field
        size, fmt = SIZES[kind]
        pad(buf, size)
        struct.pack_into("<H", buf, vtable + 4 + 2 * k, len(buf) - pos)
        if kind == "off":
            later.append((len(buf), value))
            buf += b"\0\0\0\0"
        else:
            buf += struct.pack(fmt, value)
    struct.pack_into("<HH", buf, vtable, 4 + 2 * len(obj.fields), len(buf) - pos)
    for at, child in later:
        struct.pack_into("<I", buf, at, emit(buf, child) - at)
    return pos


def message(header_type, header, body=b"", version=V5, body_len=None):
    """One framed message. `body_len` claims another body length than the true one."""
    buf = bytearray(b"\0\0\0\0")
    claimed = len(body) if body_len is None else body_len
    root = emit(buf, Table(("i16", version), ("u8", header_type), ("off", header), ("i64", claimed)))
    struct.pack_into("<I", buf, 0, root)
    pad(buf, 8)
    return b"\xff\xff\xff\xff" + struct.pack("<i", len(buf)) + bytes(buf) + body


# ---------------------------------------------------------------- schemas

INT64 = (2, Table(("i32", 64), ("u8", 1)))
UTF8 = (5, Table())
LIST = (12, Table())
STRUCT = (13, Table())
UTF8_VIEW = (24, Table())


def timestamp(unit):
    return (10, Table(("i16", unit)))


def field(name, kind, children=(), metadata=None):
    type_id, type_table = kind
    kids = children if isinstance(children, Vec) else Vec(children)
    custom = None if metadata is None else ("off", metadata)
    return Table(("off", name), ("u8", 1), ("u8", type_id), ("off", type_table), None, ("off", kids), custom)


def schema(fields, version=V5):
    vec = fields if isinstance(fields, Vec) else Vec(fields)
    return message(1, Table(None, ("off", vec)), version=version)


# ---------------------------------------------------------------- record batches

def batch(rows, nodes, buffers, version=V5, variadic=None, buffers_claim=None, body_len=None, with_body=True):
    """A record batch of `rows` rows: `nodes` is (length, null_count) per field, `buffers` the bytes of each buffer."""
    body, places = bytearray(), b""
    for data in buffers:
        places += struct.pack("<qq", len(body), len(data))
        body.extend(data)
        pad(body, 8)
    node_bytes = b"".join(struct.pack("<qq", length, nulls) for length, nulls in nodes)
    counts = None if variadic is None else ("off", Vec(structs=b"".join(struct.pack("<q", n) for n in variadic), size=8))
    header = Table(
        ("i64", rows),
        ("off", Vec(structs=node_bytes)),
        ("off", Vec(structs=places, claim=buffers_claim)),
        None,
        counts,
    )
    return message(3, header, bytes(body) if with_body else b"", version=version, body_len=len(body) if body_len is None else body_len)


def int64s(values):
    return b"".join(struct.pack("<q", v) for v in values)


def int32s(values):
    return b"".join(struct.pack("<i", v) for v in values)


def nested_lists(depth):
    """One column of `depth` fields: lists in lists, an Int64 at the bottom."""
    inner = field("item", INT64)
    for _ in range(depth - 2):
        inner = field("item", LIST, [inner])
    return field("deep", LIST, [inner])


def fan_out(levels, width):
    """`levels` levels of structs, each with `width` children that are all the one next table.

    The names are empty, so that the count of fields is what grows.
    """
    inner = field("", INT64)
    for _ in range(levels):
        inner = field("", STRUCT, Vec([inner], shared=width))
    return inner


ID = [field("id", INT64)]

FIXTURES = {
    # Valid streams.
    "zero_columns.arrow": schema([]) + batch(5, [], []) + END,
    "zero_rows.arrow": schema([field("id", INT64), field("name", UTF8)])
    + batch(0, [(0, 0), (0, 0)], [b"", b"", b"", int32s([0]), b""])
    + END,
    "v4.arrow": schema(ID, version=V4) + batch(2, [(2, 0)], [b"", int64s([7, 8])], version=V4) + END,
    "depth64.arrow": schema([nested_lists(64)]) + END,
    # Invalid or unsupported streams.
    "depth65.arrow": schema([nested_lists(65)]) + END,
    "fan_out.arrow": schema([fan_out(10, 10)]) + END,
    "time_unit.arrow": schema([field("ts", timestamp(7))]) + END,
    "type_id.arrow": schema([field("x", (30, Table()))]) + END,
    "long_vector.arrow": schema(Vec(ID, claim=0xFFFFFFFF)) + END,
    "long_buffers.arrow": schema([field("v", UTF8_VIEW)])
    + batch(1, [(1, 0)], [b"", b"\0" * 16], variadic=[0xFFFFFFFE], buffers_claim=0xFFFFFFFF)
    + END,
    "extra_node.arrow": schema(ID) + batch(2, [(2, 0), (2, 0)], [b"", int64s([7, 8])]) + END,
    "extra_buffer.arrow": schema(ID) + batch(2, [(2, 0)], [b"", int64s([7, 8]), int64s([9])]) + END,
    "short_column.arrow": schema(ID) + batch(3, [(2, 0)], [b"", int64s([7, 8])]) + END,
    "bad_offsets.arrow": schema([field("id", INT64), field("name", UTF8)])
    + batch(2, [(2, 0), (2, 0)], [b"", int64s([7, 8]), b"", int32s([0, 5, 3]), b"hello"])
    + END,
    "shared_text.arrow": schema([field("id", INT64, metadata=Vec([Table(("off", "k" * 100), ("off", "v"))], shared=200))]) + END,
    "old_version.arrow": schema(ID) + batch(2, [(2, 0)], [b"", int64s([7, 8])], version=2, body_len=1000, with_body=False),
}

if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    for name, data in FIXTURES.items():
        with open(os.path.join(here, name), "wb") as out:
            out.write(data)
        print(f"{name}: {len(data)} bytes")
