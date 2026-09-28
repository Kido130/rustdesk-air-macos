#!/usr/bin/env python3
"""Bounded live tests through the real RustDesk transport and native renderer."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time


def metrics(path):
    for line in reversed(path.read_text(errors="replace").splitlines()):
        if line.startswith('{"presented":'):
            return json.loads(line)
    raise RuntimeError(f"No final metrics in {path.name}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--work-dir", required=True, type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    folder = args.work_dir.resolve()
    folder.mkdir(parents=True, exist_ok=True)
    os.chmod(folder, 0o700)
    pairing = folder / "pairing.json"
    report = {"scope": "real local desktop, both endpoints on this Mac", "modes": {}}
    host_log = folder / "host.log"
    with host_log.open("w") as output:
        host = subprocess.Popen([str(binary), "--test-profile", "--host", "--pairing", str(pairing),
                                 "--address", "127.0.0.1:21128", "--quit-after", "100"],
                                stdout=output, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 12
            while not pairing.exists():
                if host.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("Host did not create its private pairing file")
                time.sleep(0.1)
            # Pairing is written before the listener is opened.
            time.sleep(1)
            for mode in ("exact", "hevc", "h264", "adaptive"):
                log = folder / f"client-{mode}.log"
                with log.open("w") as client_output:
                    result = subprocess.run([str(binary), "--test-profile", "--pairing", str(pairing),
                                             "--mode", mode, "--quit-after", "20"],
                                            stdout=client_output, stderr=subprocess.STDOUT,
                                            timeout=30)
                if result.returncode:
                    raise RuntimeError(f"{mode} client exited with {result.returncode}")
                if any(line.startswith(("Connection Error:", "Native video error:"))
                       for line in log.read_text(errors="replace").splitlines()):
                    raise RuntimeError(f"{mode}: session reported an error")
                measured = metrics(log)
                report["modes"][mode] = measured
                (folder / "results.json").write_text(json.dumps(report, indent=2) + "\n")
                if measured["presented"] <= 0:
                    raise RuntimeError(f"{mode}: no completed Metal presentations")
                if mode == "exact" and measured["patches"] <= 1:
                    raise RuntimeError("Exact mode did not apply multiple real updates")
                if mode != "exact" and (measured["decoded"] <= 0 or measured["hardware_sessions"] <= 0):
                    raise RuntimeError(f"{mode}: no verified hardware decoding")
                print(json.dumps({"mode": mode, **measured}), flush=True)
        finally:
            if host.poll() is None:
                host.terminate()
                try:
                    host.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    host.kill()
                    host.wait(timeout=5)
    report["functional_pass"] = True
    (folder / "results.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
