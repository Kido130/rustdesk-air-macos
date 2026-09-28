#!/usr/bin/env python3
"""Bounded native client run; CPU is one-process CPU time, 100% = one core."""
import argparse
import json
import os
from pathlib import Path
import signal
import statistics
import subprocess
import time


def cpu_seconds(value):
    days, _, clock = value.rpartition("-")
    parts = [float(part) for part in clock.split(":")]
    result = 0.0
    for part in parts:
        result = result * 60 + part
    return result + (int(days) * 86400 if days else 0)


def app_pids(binary):
    result = subprocess.run(["/bin/ps", "-ax", "-o", "pid=", "-o", "comm="],
                            capture_output=True, text=True, check=True, timeout=3)
    matches = set()
    for line in result.stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[1] == str(binary):
            matches.add(int(parts[0]))
    return matches


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--pairing", type=Path, required=True)
    parser.add_argument("--mode", choices=["adaptive", "exact", "hevc", "h264"], required=True)
    parser.add_argument("--seconds", type=int, default=35)
    parser.add_argument("--match-display", action="store_true")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not 10 <= args.seconds <= 120:
        parser.error("Duration must be 10–120 seconds")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(args.output.parent, 0o700)
    log = args.output.with_suffix(".log")
    samples = []
    args.binary = args.binary.resolve(strict=True)
    bundle = args.binary.parents[2]
    launch_services = bundle.suffix == ".app"
    started = time.monotonic()
    with log.open("w") as output:
        client_args = ["--test-profile", "--pairing", str(args.pairing),
                       "--mode", args.mode, "--quit-after", str(args.seconds)]
        if args.match_display:
            client_args.append("--match-display")
        previous = app_pids(args.binary) if launch_services else set()
        command = (["/usr/bin/open", "-W", "-n", "-a", str(bundle),
                    "--stdout", str(log), "--stderr", str(log), "--args"]
                   if launch_services else [str(args.binary)]) + client_args
        process = subprocess.Popen(command,
                                   stdout=output, stderr=subprocess.STDOUT)
        client_pid = None if launch_services else process.pid
        awake = None
        try:
            if launch_services:
                deadline = time.monotonic() + 8
                while client_pid is None and time.monotonic() < deadline:
                    candidates = app_pids(args.binary) - previous
                    if len(candidates) == 1:
                        client_pid = candidates.pop()
                    elif candidates:
                        raise RuntimeError("More than one new client appeared; cannot attribute CPU")
                    else:
                        time.sleep(0.1)
                if client_pid is None:
                    raise RuntimeError("Launch Services did not start the client")
            awake = subprocess.Popen(["/usr/bin/caffeinate", "-di", "-w", str(client_pid)])
            while process.poll() is None:
                if time.monotonic() - started > args.seconds + 10:
                    raise RuntimeError("Client did not exit within the bounded test")
                sampled = subprocess.run(["/bin/ps", "-p", str(client_pid), "-o", "time=", "-o", "rss=", "-o", "%cpu="],
                                         capture_output=True, text=True, timeout=3)
                parts = sampled.stdout.split()
                if len(parts) == 3:
                    samples.append({"elapsed_s": time.monotonic() - started,
                                    "cpu_s": cpu_seconds(parts[0]), "rss_kib": int(parts[1]),
                                    "ps_cpu_percent": float(parts[2])})
                time.sleep(1)
        finally:
            if process.poll() is None:
                if launch_services and client_pid in app_pids(args.binary):
                    os.kill(client_pid, signal.SIGTERM)
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            if awake is not None and awake.poll() is None:
                awake.terminate()
                awake.wait(timeout=5)
    text = log.read_text(errors="replace")
    metrics = [json.loads(line) for line in text.splitlines() if line.startswith('{"presented":')]
    session_errors = [line for line in text.splitlines()
                      if line.startswith(("Connection Error:", "Native video error:"))]
    steady = [sample for sample in samples if sample["elapsed_s"] >= 5]
    report = {"mode": args.mode, "match_display": args.match_display, "elapsed_s": time.monotonic() - started,
              "launch": "LaunchServices" if launch_services else "direct executable",
              "exit_code": process.returncode, "samples": samples,
              "session_errors": session_errors,
              "metrics": metrics[-1] if metrics else None,
              "cpu_scope": "client process only; first 5 seconds excluded; 100% equals one CPU core"}
    if len(steady) >= 2:
        first, last = steady[0], steady[-1]
        report["mean_cpu_percent"] = 100 * (last["cpu_s"] - first["cpu_s"]) / (last["elapsed_s"] - first["elapsed_s"])
        report["rss_median_mib"] = statistics.median(sample["rss_kib"] for sample in steady) / 1024
        report["rss_peak_mib"] = max(sample["rss_kib"] for sample in steady) / 1024
    report["functional_pass"] = bool(process.returncode == 0 and not session_errors and metrics and metrics[-1]["presented"] > 0
                                      and (args.mode in ("adaptive", "exact") or metrics[-1]["hardware_sessions"] > 0)
                                      and (not args.match_display or metrics[-1].get("pixel_matched_presentations", 0) > 0))
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: value for key, value in report.items() if key != "samples"}), flush=True)
    if not report["functional_pass"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
