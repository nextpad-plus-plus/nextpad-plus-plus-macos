#!/usr/bin/env python3
"""Run native Cocoa scroll regressions using an existing CMake build (no visible windows)."""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[2]
build = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else root / 'build'
artifacts = build / 'scroll-probes'
artifacts.mkdir(parents=True, exist_ok=True)
profile = artifacts / 'profile'
config = profile / 'Library/Application Support/Nextpad++'
config.mkdir(parents=True, exist_ok=True)
for source, dest in [('stylers.model.xml', 'stylers.xml'), ('langs.model.xml', 'langs.xml')]:
    shutil.copy2(root / 'resources' / source, config / dest)
udls = config / 'userDefineLangs'
udls.mkdir(exist_ok=True)
udl = ET.parse(root / 'resources/userDefineLangs/markdown._preinstalled.udl.xml')
udl.getroot().find('UserLang').set('name', 'Python')  # legal collision with a built-in
udl.write(udls / 'scroll-probe.xml', encoding='utf-8', xml_declaration=True)
env = dict(os.environ, CFFIXED_USER_HOME=str(profile))
objects = sorted((build / 'CMakeFiles/NotepadPlusPlusMac.dir/src').glob('*.o'))
# Compile path helpers from source, so even a build with diagnostic config-path
# overrides runs the tests with this disposable profile.
objects = [p for p in objects if p.name not in {'main.mm.o', 'NppPaths.mm.o', 'NppLocalizer.mm.o'}]
scintilla_libraries = [build / name for name in ('libscintilla.a', 'libscintilla_core.a')]
if not objects or not all(path.exists() for path in scintilla_libraries):
    sys.exit('Build the application with CMake first, then pass that build directory.')
common = ['clang++', '-std=c++17', '-fobjc-arc', '-O2', '-g']
for folder in ['src', 'scintilla/include', 'scintilla/src', 'scintilla/cocoa', 'lexilla/include']:
    common += ['-I', str(root / folder)]
results = []
for test in (sys.argv[2:] or ['ScrollProbe', 'EditorScrollProbe', 'OverscrollProbe', 'ScrollWorkProbe', 'GestureTransitionProbe']):
    exe = artifacts / test
    command = common + [str(root / 'tests/cocoa' / (test + '.mm'))]
    if test in {'EditorScrollProbe', 'ScrollWorkProbe'}:
        command += [str(p) for p in objects]
        command += [str(root / 'src/NppPaths.mm'), str(root / 'src/NppLocalizer.mm')]
    command += [str(path) for path in scintilla_libraries]
    if test in {'EditorScrollProbe', 'ScrollWorkProbe'}:
        command += [str(build / 'liblexilla.a')]
    for framework in ['Cocoa', 'QuartzCore', 'UniformTypeIdentifiers', 'CoreGraphics']:
        command += ['-framework', framework]
    command += ['-o', str(exe)]
    subprocess.run(command, check=True)
    result = subprocess.run([str(exe)], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    print(result.stdout, end='')
    (artifacts / (test + '.log')).write_text(result.stdout)
    results.append(result.returncode)
sys.exit(1 if any(results) else 0)
