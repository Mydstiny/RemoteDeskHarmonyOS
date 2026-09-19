#!/usr/bin/env python3
"""Mutation controls against the actual Release disassembly supplied by the caller."""
import argparse
import copy
from pathlib import Path
from check_pro_release import check_production_default


def extract(assembly):
    methods, key = {}, None
    for line in assembly.splitlines():
        if line.startswith('.function'):
            key = None
            for module, marker, name in (
                    ('ProBackendConfiguration', '#proBackendConfiguration(', 'proBackendConfiguration'),
                    ('ProProductionRelease', '#productionProBackendConfiguration(', 'productionFactory'),
                    ('ProProductionRelease', '.func_main_0(', 'productionMain')):
                if f'services.pro.{module}&.' in line and marker in line:
                    assert name not in methods
                    key = name
                    methods[key] = []
        elif key:
            methods[key].append(line.strip())
            if line.strip() == '}': key = None
    return methods


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--assembly', required=True, type=Path)
    args = parser.parse_args()
    assembly = args.assembly.read_text(errors='replace')
    methods = extract(assembly)
    check_production_default(methods, assembly)
    changes = (
        ('enable production', 'productionMain', 'u1:0', 'u1:1'),
        ('route sandbox', 'proBackendConfiguration', '"production"', '"sandbox"'),
        ('override factory input', 'proBackendConfiguration', 'callarg0', 'callarg1'),
        ('grant other environment', 'proBackendConfiguration', 'ldnull', 'createemptyobject'),
        ('reverse enabled guard', 'productionFactory', 'callruntime.istrue 0x3', 'callruntime.isfalse 0x3'),
        ('return grant', 'productionFactory', 'ldnull', 'ldtrue'),
        ('read other lexical slot', 'productionFactory', 'ldlexvar 0x0, 0x0', 'ldlexvar 0x0, 0x1'),
        ('call on default path', 'productionFactory', 'ldobjbyname 0x1, "enabled"', 'callarg0 0x1'),
    )
    for label, key, old, new in changes:
        mutated = copy.deepcopy(methods)
        assert any(old in line for line in mutated[key]), label
        mutated[key] = [line.replace(old, new) for line in mutated[key]]
        try: check_production_default(mutated, assembly)
        except (AssertionError, KeyError, IndexError): print('PASS rejected ' + label)
        else: raise AssertionError('Gate accepted mutation: ' + label)
    for old, new in (
            ('import_name: productionProBackendConfiguration', 'import_name: otherFactory'),
            ('module_request: @normalized:N&&&entry/src/main/ets/services/pro/ProProductionRelease&;',
             'module_request: @normalized:N&&&entry/src/main/ets/services/pro/OtherRelease&;')):
        assert old in assembly
        try: check_production_default(methods, assembly.replace(old, new))
        except AssertionError: print('PASS rejected import rebinding')
        else: raise AssertionError('Gate accepted rebound factory')
    print('PASS real Release positive control and 10 rejecting mutations')


if __name__ == '__main__':
    main()
