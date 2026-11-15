#!/usr/bin/env python3
"""Run production title checks on macOS, including hosts with no XCTest framework."""
from pathlib import Path
import subprocess, tempfile, sys
try:
    root = Path(__file__).resolve().parents[1]
    subprocess.run(['swift', 'build', '--target', 'Capture'], cwd=root, check=True)
    build = Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=root, text=True).strip())
    subprocess.run(['swift', 'build', '--target', 'Database'], cwd=root, check=True)
    objects = [str(p) for target in ['Shared', 'Database', 'SQLCipher', 'Capture'] for p in (build / (target + '.build')).rglob('*.o')]
    with tempfile.TemporaryDirectory(prefix='retrace-title-checks-') as temp:
        executable = str(Path(temp) / 'checks')
        subprocess.run(['swiftc', '-parse-as-library', '-target', 'arm64-apple-macosx13.0', '-swift-version', '5',
                        '-module-cache-path', str(build / 'ModuleCache'),
                        '-Xcc', '-fmodule-map-file=' + str(build / 'SQLCipher.build/module.modulemap'),
                        '-Xcc', '-I', '-Xcc', str(root / '.build/checkouts/swift-sqlcipher/Sources/SQLCipher/sqlite'),
                        '-I', str(build / 'Modules'),
                        '-I', str(build / 'SQLCipher.build'),
                        str(root / 'Processing/WindowTitleValidator.swift'),
                        str(root / 'scripts/WindowTitleValidationChecks.swift'),
                        *objects, '-o', executable], cwd=root, check=True)
        subprocess.run([executable, *sys.argv[1:]], cwd=root, check=True)
except subprocess.CalledProcessError as error:
    sys.exit(error.returncode)
