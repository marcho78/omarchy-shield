#!/usr/bin/env python3
"""cboot's EMC table, as mainline's tegra210-emc driver takes it.

Reads a device tree blob of cboot's (U-Boot passes cboot's on in
/chosen/darcy,cboot-fdt), takes the EMC table for a RAM code, and lays it
out as an array of Linux's struct tegra210_emc_timing, the layout read from
the kernel's own header. With --compare, checks a table U-Boot built (its
copy in /chosen/darcy,emc-table) against that, field by field: an
independent check of patches/u-boot's converter.

Usage: tools/emc-table.py <cboot.dtb> [--ram-code N] [--compare <table.bin>]
"""
import argparse
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HEADER = ROOT / "vendor/linux/drivers/memory/tegra/tegra210-emc.h"

# Fields whose property isn't "nvidia,emc-<field with dashes>"
PROPS = {
    "revision": "nvidia,revision",
    "dvfs_ver": "nvidia,dvfs-version",
    "rate": "clock-frequency",
    "min_volt": "nvidia,emc-min-mv",
    "gpu_min_volt": "nvidia,gk20a-min-mv",
    "clock_src": "nvidia,source",
    "clk_src_emc": "nvidia,src-sel-reg",
    "needs_training": "nvidia,needs-training",
    "training_pattern": "nvidia,training_pattern",
    "trained": "nvidia,trained",
    "periodic_training": "nvidia,periodic_training",
    "run_clocks": "nvidia,run_clocks",
    "tree_margin": "nvidia,tree_margin",
    "num_burst": "nvidia,burst-regs-num",
    "num_burst_per_ch": "nvidia,burst-regs-per-ch-num",
    "num_trim": "nvidia,trim-regs-num",
    "num_trim_per_ch": "nvidia,trim-regs-per-ch-num",
    "num_mc_regs": "nvidia,burst-mc-regs-num",
    "num_up_down": "nvidia,la-scale-regs-num",
    "vref_num": "nvidia,vref-regs-num",
    "training_mod_num": "nvidia,training-mod-regs-num",
    "dram_timing_num": "nvidia,dram-timing-regs-num",
    "ptfv_list": "nvidia,ptfv",
    "burst_regs": "nvidia,emc-registers",
    "burst_reg_per_ch": "nvidia,emc-burst-regs-per-ch",
    "shadow_regs_ca_train": "nvidia,emc-shadow-regs-ca-train",
    "shadow_regs_quse_train": "nvidia,emc-shadow-regs-quse-train",
    "shadow_regs_rdwr_train": "nvidia,emc-shadow-regs-rdwr-train",
    "trim_regs": "nvidia,emc-trim-regs",
    "trim_perch_regs": "nvidia,emc-trim-regs-per-ch",
    "vref_perch_regs": "nvidia,emc-vref-regs",
    "dram_timings": "nvidia,emc-dram-timing-regs",
    "training_mod_regs": "nvidia,emc-training-mod-regs",
    "save_restore_mod_regs": "nvidia,emc-save-restore-mod-regs",
    "burst_mc_regs": "nvidia,emc-burst-mc-regs",
    "la_scale_regs": "nvidia,emc-la-scale-regs",
    "min_mrs_wait": "nvidia,min-mrs-wait",
    "dll_clk_src": "nvidia,dll-clk-src",
    "clk_out_enb_x_0_clk_enb_emc_dll": "nvidia,clk-out-enb-x-0-clk-enb-emc-dll",
    "latency": "nvidia,emc-clock-latency-change",
}
CLKTREE = ["c0d0u0", "c0d0u1", "c0d1u0", "c0d1u1", "c1d0u0", "c1d0u1", "c1d1u0", "c1d1u1"]


def layout():
    """struct tegra210_emc_timing's fields: (name, type, count), in order"""
    text = HEADER.read_text()
    sizes = {m[0]: int(m[1]) for m in re.findall(r"#define (\w+) (\d+)\b", text)}
    enum = re.search(r"enum \{\s*C0D0U0,(.*?)DRAM_CLKTREE_NUM,", text, re.S)
    sizes["DRAM_CLKTREE_NUM"] = 1 + enum[1].count(",")
    body = re.search(r"struct tegra210_emc_timing \{(.*?)\n\};", text, re.S)[1]
    fields = []
    for kind, name, count in re.findall(r"(u32|char)\s+(\w+)(?:\[(\w+)\])?;", body):
        fields.append((name, kind, int(sizes.get(count, count or 1))))
    return fields


def parse_fdt(blob):
    """A device tree blob as nested dicts: {"props": {...}, "nodes": {...}}"""
    magic, _, off_struct, off_strings = struct.unpack_from(">IIII", blob)
    if magic != 0xD00DFEED:
        sys.exit("not a device tree blob")
    root = {"props": {}, "nodes": {}}
    stack, pos = [], off_struct
    while True:
        (token,) = struct.unpack_from(">I", blob, pos)
        pos += 4
        if token == 1:  # FDT_BEGIN_NODE
            end = blob.index(b"\0", pos)
            name = blob[pos:end].decode()
            pos = (end + 4) & ~3
            node = {"props": {}, "nodes": {}}
            (stack[-1]["nodes"].__setitem__(name, node) if stack else None)
            stack.append(node if stack else root)
        elif token == 2:  # FDT_END_NODE
            stack.pop()
        elif token == 3:  # FDT_PROP
            length, nameoff = struct.unpack_from(">II", blob, pos)
            pos += 8
            end = blob.index(b"\0", off_strings + nameoff)
            stack[-1]["props"][blob[off_strings + nameoff:end].decode()] = blob[pos:pos + length]
            pos = (pos + length + 3) & ~3
        elif token == 4:  # FDT_NOP
            continue
        elif token == 9:  # FDT_END
            return root
        else:
            sys.exit(f"bad token {token} at {pos - 4}")


def entry(node, fields):
    """One rate's struct, packed"""
    out = b""
    for name, kind, count in fields:
        if kind == "char":
            s = node["props"][PROPS[name]].split(b"\0")[0][:count - 1]
            out += s.ljust(count, b"\0")
            continue
        if name in ("trained_dram_clktree", "current_dram_clktree"):
            prefix = "nvidia," + name.replace("dram_clktree", "dram_clktree_")
            values = [struct.unpack(">I", node["props"][prefix + c])[0] for c in CLKTREE]
        else:
            prop = PROPS.get(name, "nvidia," + name.replace("_", "-"))
            raw = node["props"][prop]
            if len(raw) != 4 * count:
                sys.exit(f"{prop}: {len(raw)} bytes, {4 * count} expected")
            values = struct.unpack(f">{count}I", raw)
        out += struct.pack(f"<{count}I", *values)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dtb")
    ap.add_argument("--ram-code", type=int, default=1)
    ap.add_argument("--compare")
    args = ap.parse_args()

    fields = layout()
    words = sum(c if k == "u32" else c // 4 for _, k, c in fields)
    fdt = parse_fdt(Path(args.dtb).read_bytes())
    emc = fdt["nodes"]["external-memory-controller@7001b000"]
    table = next(t for t in emc["nodes"].values()
                 if struct.unpack(">I", t["props"]["nvidia,ram-code"])[0] == args.ram_code)
    rates = sorted(table["nodes"].values(), key=lambda n: struct.unpack(">I", n["props"]["clock-frequency"])[0])
    expected = b"".join(entry(n, fields) for n in rates) + bytes(words * 4)
    print(f"struct tegra210_emc_timing: {len(fields)} fields, {words} words; RAM code {args.ram_code}: "
          + ", ".join(str(struct.unpack(">I", n["props"]["clock-frequency"])[0]) for n in rates) + " kHz, trained "
          + "".join(str(struct.unpack(">I", n["props"]["nvidia,trained"])[0]) for n in rates))
    if not args.compare:
        return
    got = Path(args.compare).read_bytes()
    if got == expected:
        print(f"{args.compare}: identical, {len(got)} bytes")
        return
    print(f"{args.compare}: {len(got)} bytes, {len(expected)} expected")
    for i in range(min(len(got), len(expected)) // 4):
        if got[4 * i:4 * i + 4] != expected[4 * i:4 * i + 4]:
            rate, word = divmod(i, words)
            for name, kind, count in fields:
                size = count if kind == "u32" else count // 4
                if word < size:
                    break
                word -= size
            print(f"first difference: rate {rate}, {name}[{word}]")
            break
    sys.exit(1)


if __name__ == "__main__":
    main()
