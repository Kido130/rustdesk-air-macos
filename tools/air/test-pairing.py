#!/usr/bin/env python3
"""Verify failed authentication never reaches capture or the native renderer."""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import time


def receive_exact(sock, count):
    result = bytearray()
    while len(result) < count:
        part = sock.recv(count - len(result))
        if not part:
            raise RuntimeError("Unexpected disconnect")
        result.extend(part)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--work-dir", type=Path, required=True)
    args = parser.parse_args()
    binary = str(args.binary.resolve(strict=True))
    folder = args.work_dir.resolve()
    folder.mkdir(parents=True, exist_ok=True)
    os.chmod(folder, 0o700)
    pairing = folder / "pairing.json"
    passed = []
    with (folder / "host.log").open("w") as host_output:
        host = subprocess.Popen([binary, "--test-profile", "--host", "--pairing", str(pairing),
                                 "--address", "127.0.0.1:21128", "--quit-after", "40"],
                                stdout=host_output, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 10
            while not pairing.exists():
                if host.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("Host startup failed")
                time.sleep(0.1)
            time.sleep(1)
            valid = json.loads(pairing.read_text())
            for name, field, value in [("wrong-key", "public_key", "00" * 32),
                                       ("wrong-identity", "host_id", "not-the-paired-host"),
                                       ("wrong-password", "password", "deliberately-invalid-test-password")]:
                wrong = dict(valid)
                wrong[field] = value
                path = folder / f"{name}.json"
                descriptor = os.open(path, os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o600)
                with os.fdopen(descriptor, "w") as output:
                    json.dump(wrong, output)
                log = folder / f"{name}.log"
                with log.open("w") as output:
                    subprocess.run([binary, "--test-profile", "--pairing", str(path), "--quit-after", "5"],
                                   stdout=output, stderr=subprocess.STDOUT, timeout=12, check=True)
                text = log.read_text(errors="replace")
                samples = [json.loads(line) for line in text.splitlines() if line.startswith('{"presented":')]
                if not samples or samples[-1]["presented"] or samples[-1]["patches"] or samples[-1]["decoded"]:
                    raise RuntimeError(f"{name}: rejected credentials reached video")
                if "Successful: Connected" in text:
                    raise RuntimeError(f"{name}: login was accepted")
                passed.append(name)
            with socket.create_connection(("127.0.0.1", 21128), timeout=5) as sock:
                first = receive_exact(sock, 1)
                header = first + receive_exact(sock, (first[0] & 3))
                receive_exact(sock, int.from_bytes(header, "little") >> 2)
                sock.sendall(b"\x00")  # Empty RustDesk message requests no encryption.
                if sock.recv(1):
                    raise RuntimeError("Host continued after a plaintext downgrade request")
            passed.append("plaintext-downgrade-rejected")
        finally:
            if host.poll() is None:
                host.terminate()
                host.wait(timeout=5)
    result = {"real_socket_tests_passed": passed}
    (folder / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))


if __name__ == "__main__":
    main()
