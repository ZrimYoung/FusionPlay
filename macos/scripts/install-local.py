#!/usr/bin/env python3
"""Install a built app and copy legacy state without overwriting an installation."""
from pathlib import Path
import hashlib
import shutil
import subprocess
import time


def verify_tree(source, destination):
    for p in source.rglob('*'):
        q = destination / p.relative_to(source)
        if p.is_symlink():
            raise RuntimeError(f'Unexpected symbolic link: {p}')
        if p.is_file():
            if not q.is_file() or hashlib.sha256(p.read_bytes()).digest() != hashlib.sha256(q.read_bytes()).digest():
                raise RuntimeError(f'Copy verification failed: {p}')
        elif not q.is_dir():
            raise RuntimeError(f'Missing directory: {q}')


def install(project, app, data):
    if app.exists() or app.is_symlink() or data.exists() or data.is_symlink():
        raise RuntimeError('Destination already exists; refusing to overwrite existing app or identity')
    source = project / 'artifacts/FusionPlay Mac.app'
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(source)], check=True)
    subprocess.run(['osascript', '-e', 'tell application id "tech.zrim.fusionplay.mac" to quit'], capture_output=True)
    for _ in range(40):
        if subprocess.run(['pgrep', '-x', 'FusionPlayMac'], capture_output=True).returncode:
            break
        time.sleep(.25)
    else:
        raise RuntimeError('App is still running')
    data.mkdir(parents=True, mode=0o700)
    # Failed attempts leave their copies available for inspection; legacy data is untouched.
    for name in ('data', 'logs'):
        original = project / name
        if original.exists():
            shutil.copytree(original, data / name)
            verify_tree(original, data / name)
    subprocess.run(['ditto', str(source), str(app)], check=True)
    verify_tree(source, app)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    shutil.copy2(Path(__file__).with_name('uninstall-installed.command'), data / '卸载 FusionPlay.command')
    (data / '卸载 FusionPlay.command').chmod(0o700)
    (data / '.installed-fusionplay').write_text('fusionplay-installed-v1\n')
    (data / '.installed-fusionplay').chmod(0o600)
    print('Verified application and migrated data:', app, data)


if __name__ == '__main__':
    project = Path(__file__).resolve().parents[3]
    install(project, Path('/Applications/FusionPlay Mac.app'), Path.home() / 'Library/Application Support/FusionPlay')
