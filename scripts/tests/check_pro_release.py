#!/usr/bin/env python3
"""Verify Pro simulation pruning in the actual Release HAP, not source text."""
import argparse
import hashlib
import re
from pathlib import Path
import subprocess
import tempfile
import zipfile



def check_production_default(methods, assembly):
    """Fail closed on the exact release route and a small interpreted default path."""
    def normalized(lines):
        return [re.sub(r"0x[0-9a-f]+", "IC", line) for line in lines if line and line != "}"]
    route = normalized(methods["proBackendConfiguration"])
    expected = [
        'ldexternalmodulevar IC', 'throw.undefinedifholewithname "DEBUG"',
        'ldexternalmodulevar IC', 'throw.undefinedifholewithname "DEBUG"',
        'lda.str "production"', 'stricteq IC, a3', 'callruntime.isfalse IC',
        'jnez jump_label_0', 'ldexternalmodulevar IC', 'sta v0',
        'throw.undefinedifholewithname "productionProBackendConfiguration"',
        'lda v0', 'callarg0 IC', 'return', 'jump_label_0:', 'ldnull', 'return']
    if route != expected:
        raise AssertionError("Release backend must accept only production and call its zero-argument factory")
    # Match actual import slot indices, not only the diagnostic hole-check names.
    if methods["proBackendConfiguration"][0] != 'ldexternalmodulevar 0x0' or \
            methods["proBackendConfiguration"][2] != 'ldexternalmodulevar 0x0' or \
            methods["proBackendConfiguration"][8] != 'ldexternalmodulevar 0x1':
        raise AssertionError("Unexpected release backend import slots")
    # Locate the unique literal module table exporting this backend function.
    tables = re.findall(r'\d+ 0x[0-9a-f]+ \{ \d+ \[\n(.*?)\]\}', assembly, re.S)
    tables = [table for table in tables if 'ModuleTag: LOCAL_EXPORT, local_name: proBackendConfiguration,' in table]
    if len(tables) != 1:
        raise AssertionError("Missing unique backend module table")
    imports = re.findall(r'ModuleTag: REGULAR_IMPORT, local_name: ([^,]+), import_name: ([^,]+), module_request: ([^;]+);', tables[0])
    expected_imports = [
        ('DEBUG', 'DEBUG', '@normalized:N&&&entry/build/default/generated/profile/default/BuildProfile&'),
        ('productionProBackendConfiguration', 'productionProBackendConfiguration', '@normalized:N&&&entry/src/main/ets/services/pro/ProProductionRelease&')]
    if imports[:2] != expected_imports:
        raise AssertionError("Release route imports are not bound to the reviewed modules")
    main = methods["productionMain"]
    expected_main = [
        'newlexenv 0x1',
        'definefunc 0x0, &entry.src.main.ets.services.pro.ProProductionRelease&.#*#productionProBackendConfiguration:(any,any,any,any), 0x0',
        'stmodulevar 0x0',
        'createobjectwithbuffer 0x1, { 16 [ string:"enabled", u1:0, string:"functionName", string:"", string:"functionVersion", string:"", string:"applicationId", string:"", string:"productId", string:"", string:"issuer", string:"", string:"keyId", string:"", string:"publicKeyBase64", string:"", ]}',
        'stlexvar 0x0, 0x0', 'returnundefined', '}']
    if main != expected_main:
        raise AssertionError("Production default must be a single disabled, empty, unmodified RELEASE object")
    lines = methods["productionFactory"]
    labels = {line[:-1]: index for index, line in enumerate(lines) if line.endswith(':')}
    if len(labels) != sum(line.endswith(':') for line in lines):
        raise AssertionError("Duplicate factory label")
    undefined = object()
    release = {"enabled": False}
    registers = {"a3": undefined}
    value = undefined
    pc = 0
    for _ in range(len(lines) * 2):
        line = lines[pc]; pc += 1
        if line == 'nop' or line.endswith(':'):
            continue
        if line == 'ldundefined': value = undefined
        elif line == 'ldlexvar 0x0, 0x0': value = release
        elif line.startswith('sta '): registers[line[4:]] = value
        elif line.startswith('lda '): value = registers[line[4:]]
        elif re.fullmatch(r'stricteq 0x[0-9a-f]+, a3', line): value = value is registers['a3']
        elif line == 'throw.undefinedifholewithname "RELEASE"':
            if value is not release: raise AssertionError("Invalid default RELEASE binding")
        elif re.fullmatch(r'ldobjbyname 0x[0-9a-f]+, "enabled"', line):
            if value is not release: raise AssertionError("Invalid enabled receiver")
            value = release['enabled']
        elif re.fullmatch(r'callruntime.istrue 0x[0-9a-f]+', line): value = value is True
        elif re.fullmatch(r'callruntime.isfalse 0x[0-9a-f]+', line): value = value is False
        elif line == 'ldtrue': value = True
        elif line == 'ldfalse': value = False
        elif line == 'ldnull': value = None
        elif line.startswith(('jeqz ', 'jnez ', 'jmp ')):
            op, label = line.split()
            if label not in labels: raise AssertionError("Missing branch label")
            if op == 'jmp' or (op == 'jnez' and value is True) or (op == 'jeqz' and value is False): pc = labels[label]
        elif line == 'return':
            if value is not None: raise AssertionError("Default production path did not reject")
            return
        else:
            raise AssertionError("Unexpected instruction on default production path: " + line)
    raise AssertionError("Default production path did not terminate")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("hap", type=Path)
    parser.add_argument("--disassembler", type=Path, required=True)
    parser.add_argument("--usb-probe", action="store_true", help="Also require the Debug USB probe gate to return false")
    parser.add_argument("--fido-library", action="store_true", help="Check library availability pruning and both native ABI binaries")
    parser.add_argument("--debug-hap", type=Path, help="Debug positive control for --fido-library")
    parser.add_argument("--sandbox-purchase", action="store_true", help="Require sandbox pruning and the production default to stay disabled")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="pro-release-") as directory:
        abc = Path(directory) / "modules.abc"
        assembly = Path(directory) / "modules.pa"
        with zipfile.ZipFile(args.hap) as hap:
            names = [name for name in hap.namelist() if name.endswith("/modules.abc")]
            if len(names) != 1:
                raise AssertionError("Expected exactly one entry modules.abc")
            abc.write_bytes(hap.read(names[0]))
            if args.fido_library:
                if args.debug_hap is None:
                    parser.error('--fido-library requires --debug-hap as a positive control')
                with zipfile.ZipFile(args.debug_hap) as debug:
                    for abi in ('arm64-v8a', 'x86_64'):
                        name = f'libs/{abi}/librdpnapi.so'
                        release_bytes, debug_bytes = hap.read(name), debug.read(name)
                        for marker in (b'fido_dev_open', b'fido_dev_get_cbor_info', b'cbor_load',
                                       b'remotedesk-debug-usb-capability-probe'):
                            if marker not in debug_bytes or marker in release_bytes:
                                raise AssertionError(f'FIDO native pruning/positive control failed: {abi}: {marker!r}')
                        print(f'PASS {abi} Release ELF excludes FIDO/CBOR worker markers present in Debug')
        subprocess.run([str(args.disassembler), str(abc), str(assembly)], check=True,
                       stdout=subprocess.DEVNULL)
        assembly_text = assembly.read_text(errors="replace")
        methods = {}
        method = None
        with assembly.open(errors="replace") as source:
            for line in source:
                if line.startswith(".function"):
                    method = None
                    if args.sandbox_purchase:
                        for marker, key in (("#productionProBackendConfiguration(", "productionFactory"), (".func_main_0(", "productionMain")):
                            if "services.pro.ProProductionRelease&." in line and marker in line:
                                if key in methods: raise AssertionError("Duplicate production method")
                                method = key; methods[key] = []
                        for module, name in (("ProAppRuntime", "setSandbox"), ("ProAppRuntime", "sandboxSelected"),
                                             ("ProBackendConfiguration", "proBackendConfiguration")):
                            if f"services.pro.{module}&." in line and f"#{name}(" in line:
                                if name in methods:
                                    raise AssertionError(f"Duplicate sandbox gate: {name}")
                                method = name
                                methods[method] = []
                    if args.usb_probe and "services.pro.ProUsbFidoProbe&." in line and "#debugAllowed(" in line:
                        if "usbDebugAllowed" in methods:
                            raise AssertionError("Duplicate USB probe gate")
                        method = "usbDebugAllowed"
                        methods[method] = []
                    if args.fido_library and "services.pro.ProUsbFidoProbe&." in line and "#libraryAvailable(" in line:
                        if "usbLibraryAvailable" in methods:
                            raise AssertionError("Duplicate FIDO library gate")
                        method = "usbLibraryAvailable"
                        methods[method] = []
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
        expected = {"setDebugMode", "snapshot", "decision"}
        if args.usb_probe:
            expected.add("usbDebugAllowed")
        if args.fido_library:
            expected.add("usbLibraryAvailable")
        if args.sandbox_purchase:
            expected.update(("setSandbox", "sandboxSelected", "proBackendConfiguration", "productionFactory", "productionMain"))
        if set(methods) != expected:
            raise AssertionError("Missing runtime methods; pruning cannot be certified")
        for name, lines in methods.items():
            body = "\n".join(lines)
            for forbidden in ('"debugMode"', '"PRO_LIFETIME"', '"pro.lifetime"', '"模拟 Pro"', '"模拟免费"',
                              '"experimental"', '"resolveProFeatureAccess"'):
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
        for gate in (["usbDebugAllowed"] if args.usb_probe else []) + (["usbLibraryAvailable"] if args.fido_library else []):
            body = methods[gate]
            if "ldfalse" not in body or "return" not in body:
                raise AssertionError("Release USB probe gate does not return false")
            for line in body:
                if line and line != "}" and not line.startswith(("ldexternalmodulevar ",
                        'throw.undefinedifholewithname "DEBUG"', "ldfalse", "return")):
                    raise AssertionError(f"Release USB gate retains executable granting logic: {line}")
            print(f"PASS Release {gate} always returns false")
        if args.sandbox_purchase:
            for name, required, allowed in (("setSandbox", "returnundefined", ("returnundefined",)),
                    ("sandboxSelected", "ldfalse", ("ldfalse", "return"))):
                if required not in methods[name]:
                    raise AssertionError(f"Release sandbox gate is not disabled: {name}")
                for line in methods[name]:
                    if line and line != "}" and not line.startswith(("ldexternalmodulevar ",
                            'throw.undefinedifholewithname "DEBUG"') + allowed):
                        raise AssertionError(f"Release sandbox gate retains executable logic: {name}: {line}")
            check_production_default(methods, assembly_text)
            print("PASS Release sandbox is disabled; production-only route calls a disabled default factory")
        print("PASS Release setter, snapshot and decision contain no simulation override")
        print("modules.abc SHA256=" + hashlib.sha256(abc.read_bytes()).hexdigest())


if __name__ == "__main__":
    main()
