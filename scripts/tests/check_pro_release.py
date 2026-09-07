#!/usr/bin/env python3
"""Verify Pro simulation pruning in the actual Release HAP, not source text."""
import argparse
import hashlib
from pathlib import Path
import subprocess
import tempfile
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("hap", type=Path)
    parser.add_argument("--disassembler", type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="pro-release-") as directory:
        abc = Path(directory) / "modules.abc"
        assembly = Path(directory) / "modules.pa"
        with zipfile.ZipFile(args.hap) as hap:
            names = [name for name in hap.namelist() if name.endswith("/modules.abc")]
            if len(names) != 1:
                raise AssertionError("Expected exactly one entry modules.abc")
            abc.write_bytes(hap.read(names[0]))
        subprocess.run([str(args.disassembler), str(abc), str(assembly)], check=True,
                       stdout=subprocess.DEVNULL)
        methods = {}
        method = None
        with assembly.open(errors="replace") as source:
            for line in source:
                if line.startswith(".function"):
                    method = None
                    for name in ("setDebugMode", "snapshot", "decision"):
                        if "services.pro.ProRuntime&." in line and f"#{name}(" in line:
                            if name in methods:
                                raise AssertionError(f"Duplicate method: {name}")
                            method = name
                            methods[name] = []
                elif method:
                    methods[method].append(line.strip())
                    if line.strip() == "}":
                        method = None
        if set(methods) != {"setDebugMode", "snapshot", "decision"}:
            raise AssertionError("Missing runtime methods; pruning cannot be certified")
        for name, lines in methods.items():
            body = "\n".join(lines)
            for forbidden in ('"debugMode"', '"PRO_LIFETIME"', '"pro.lifetime"', '"模拟 Pro"', '"模拟免费"'):
                if forbidden in body:
                    raise AssertionError(f"Simulation remains in {name}: {forbidden}")
        # Release setter is a no-op (a retained module-initialization check is harmless).
        for line in methods["setDebugMode"]:
            if line and line != "}" and not line.startswith(("ldexternalmodulevar ",
                    'throw.undefinedifholewithname "DEBUG"', "returnundefined")):
                raise AssertionError(f"Release simulation setter has executable logic: {line}")
        decision = "\n".join(methods["decision"])
        if '"entitlementIds"' not in decision or '"proFeatureAccess"' not in decision:
            raise AssertionError("Real entitlement policy call is missing")
        print("PASS Release setter, snapshot and decision contain no simulation override")
        print("modules.abc SHA256=" + hashlib.sha256(abc.read_bytes()).hexdigest())


if __name__ == "__main__":
    main()
