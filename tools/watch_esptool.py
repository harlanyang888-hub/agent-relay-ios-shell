"""Run the isolated Windows ESP tool dependencies without changing global Python."""
from pathlib import Path
import runpy
import sys

dependencies = Path(__file__).resolve().parents[2] / 'agent-relay-ios-shell-builds' / 'esp-tools-deps'
if not dependencies.is_dir():
    raise SystemExit(f'Install esptool into {dependencies} first')
sys.path.insert(0, str(dependencies))
sys.argv[0] = 'esptool'
runpy.run_module('esptool', run_name='__main__')
