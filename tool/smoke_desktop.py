"""Confirm a packaged desktop process remains running after startup."""
from pathlib import Path
import argparse
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('binary', type=Path)
arguments = parser.parse_args()
binary = arguments.binary.resolve()
process = subprocess.Popen([str(binary)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
try:
    time.sleep(8)
    if process.poll() is not None:
        output = process.communicate()[0].decode(errors="replace")
        raise SystemExit(f"Desktop process exited during startup ({process.returncode}):\n{output}")
    print("Packaged desktop process started successfully")
finally:
    if process.poll() is None:
        process.terminate()
        try:
            process.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate()
