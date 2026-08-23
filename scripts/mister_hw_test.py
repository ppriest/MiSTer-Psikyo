#!/usr/bin/env python3
"""Automates the real-hardware test loop used during Psikyo bring-up:
deploy a freshly-built .rbf, launch a game via MiSTer's own Remote API,
grab a screenshot, and pull it back locally.

Talks to the MiSTer over SSH/SCP (via PuTTY's plink/pscp -- no sshpass on
Windows) for file transfer, and over MiSTer Remote's HTTP API
(wizzomafizzo/mrext, POST /api/launch and /api/screenshots) for triggering
a game load and a screenshot. See docs/ROADMAP.md's real-hardware bring-up
notes for why this exists: iterating by hand (build -> ask the user to copy
a file -> ask the user to describe what they see) was the bottleneck during
the first real hardware bring-up session, not the actual debugging.

Credentials are NEVER hardcoded here -- pass them via environment variables
or CLI flags. This project's MiSTer sits on a local network with a weak
default password; that's a judgment call for whoever runs this script, not
something to bake into version-controlled source.

Requires PuTTY's plink.exe/pscp.exe on Windows (no OpenSSH password-auth
automation without sshpass, which isn't commonly installed there). Point
--putty-dir at your PuTTY install if it's not in the default location.

Usage:
    export MISTER_HOST=192.168.68.251
    export MISTER_PASSWORD=...        # never commit this

    # Deploy a freshly built .rbf and relaunch a game, then screenshot it:
    python scripts/mister_hw_test.py cycle \\
        --rbf output_files/Psikyo.rbf \\
        --rbf-remote-name Arcade-Psikyo_20260822.rbf \\
        --mra "/media/fat/_Arcade/_Psikyo/Samurai Aces (World).mra" \\
        --core samuraia \\
        --out scratch_screenshot.png

    # Or run the steps individually:
    python scripts/mister_hw_test.py deploy --rbf output_files/Psikyo.rbf \\
        --rbf-remote-name Arcade-Psikyo_20260822.rbf
    python scripts/mister_hw_test.py launch --mra "/media/fat/_Arcade/_Psikyo/Samurai Aces (World).mra"
    python scripts/mister_hw_test.py screenshot --core samuraia --out shot.png
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request

REMOTE_CORES_DIR = "/media/fat/_Arcade/cores"
REMOTE_SCREENSHOTS_DIR = "/media/fat/screenshots"


def find_putty_tool(putty_dir, name):
    candidates = []
    if putty_dir:
        candidates.append(os.path.join(putty_dir, name))
    candidates.append(name)  # rely on PATH
    candidates.append(os.path.join(r"C:\Program Files\PuTTY", name))
    for c in candidates:
        found = shutil.which(c) or (c if os.path.isfile(c) else None)
        if found:
            return found
    raise SystemExit(
        f"Couldn't find {name}. Install PuTTY or pass --putty-dir "
        f"(tried: {', '.join(candidates)})"
    )


class MisterHost:
    def __init__(self, host, user, password, putty_dir=None, api_port=8182):
        if not password:
            raise SystemExit(
                "No password given. Pass --password or set MISTER_PASSWORD "
                "-- never hardcode it into a committed file."
            )
        self.host = host
        self.user = user
        self.password = password
        self.api_base = f"http://{host}:{api_port}/api"
        self.plink = find_putty_tool(putty_dir, "plink.exe")
        self.pscp = find_putty_tool(putty_dir, "pscp.exe")

    def ssh(self, command, timeout=60):
        """Run a command on the MiSTer over plink, accepting an unseen host
        key automatically (matches the plain plink -pw flow used throughout
        this project's real bring-up session -- fine for a local-network
        dev box, not a general-purpose security posture)."""
        proc = subprocess.run(
            [self.plink, "-ssh", "-pw", self.password, f"{self.user}@{self.host}", command],
            input="y\n",
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        if proc.returncode != 0:
            raise RuntimeError(
                f"ssh command failed (exit {proc.returncode}): {command}\n"
                f"stdout: {proc.stdout}\nstderr: {proc.stderr}"
            )
        return proc.stdout

    def scp_to(self, local_path, remote_path, timeout=120):
        proc = subprocess.run(
            [self.pscp, "-pw", self.password, local_path, f"{self.user}@{self.host}:{remote_path}"],
            input="y\n",
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        if proc.returncode != 0:
            raise RuntimeError(
                f"scp upload failed (exit {proc.returncode}): {local_path} -> {remote_path}\n"
                f"stdout: {proc.stdout}\nstderr: {proc.stderr}"
            )

    def scp_from(self, remote_path, local_path, timeout=120):
        proc = subprocess.run(
            [self.pscp, "-pw", self.password, f"{self.user}@{self.host}:{remote_path}", local_path],
            input="y\n",
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        if proc.returncode != 0:
            raise RuntimeError(
                f"scp download failed (exit {proc.returncode}): {remote_path} -> {local_path}\n"
                f"stdout: {proc.stdout}\nstderr: {proc.stderr}"
            )

    def api_post(self, path, body=None, timeout=30):
        url = f"{self.api_base}{path}"
        data = json.dumps(body).encode() if body is not None else b""
        req = urllib.request.Request(url, data=data, method="POST")
        if body is not None:
            req.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            try:
                return json.loads(raw) if raw else {}
            except json.JSONDecodeError:
                return {"raw": raw.decode(errors="replace")}

    def api_get(self, path, timeout=30):
        url = f"{self.api_base}{path}"
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}

    # -- high-level operations --------------------------------------------

    def deploy_rbf(self, local_rbf, remote_name):
        remote_path = f"{REMOTE_CORES_DIR}/{remote_name}"
        print(f"Uploading {local_rbf} -> {self.host}:{remote_path}")
        self.scp_to(local_rbf, remote_path)
        # pscp returning just means the network transfer finished -- force
        # the write durable to the SD card before anything tries to load it.
        # Found the hard way: a cycle run that deployed then immediately
        # launched (zero gap -- unlike doing these as separate manual steps,
        # which always had a few seconds of real latency between them)
        # reliably got MiSTer's "no rbf found" and silently kept running
        # the previous core.
        self.ssh("sync")
        out = self.ssh(f"ls -la '{remote_path}'")
        print(out.strip())

    def launch_mra(self, mra_path):
        print(f"Launching {mra_path}")
        self.api_post("/launch", {"path": mra_path})

    def take_screenshot(self, core_name, out_path, settle_seconds=3,
                         poll_timeout=15, attempts=4):
        """Triggers a screenshot, then polls the core's screenshot folder
        for a new file (the API call itself returns an empty body on this
        MiSTer build -- the real signal is a new file showing up), pulls it
        back, and saves it to out_path.

        The single-trigger version of this (one POST /screenshots, then one
        30s poll) was found to silently fail intermittently throughout real
        hardware bring-up -- roughly 1 in 2 calls -- with a plain manual
        retry (re-POSTing /screenshots and polling again) always succeeding
        right after. That means the POST itself is sometimes lost/ignored,
        not that screenshots are merely slow -- so the fix is to re-POST
        periodically inside the same call, not just poll longer after one
        POST. Retries up to `attempts` times, each re-triggering the API and
        polling for `poll_timeout`s; total worst-case wait is
        attempts * poll_timeout."""
        remote_dir = f"{REMOTE_SCREENSHOTS_DIR}/{core_name}"
        before = set(self._list_screenshot_files(remote_dir))

        time.sleep(settle_seconds)  # let the just-launched core actually render a frame

        newest = None
        for attempt in range(1, attempts + 1):
            self.api_post("/screenshots")

            deadline = time.time() + poll_timeout
            while time.time() < deadline:
                after = self._list_screenshot_files(remote_dir)
                new_files = [f for f in after if f not in before]
                if new_files:
                    newest = sorted(new_files)[-1]
                    break
                time.sleep(1)

            if newest is not None:
                break
            print(f"No new screenshot after trigger {attempt}/{attempts} "
                  f"({poll_timeout}s) -- retriggering")

        if newest is None:
            raise RuntimeError(
                f"No new screenshot appeared in {remote_dir} after "
                f"{attempts} trigger attempts ({attempts * poll_timeout}s total)"
            )

        remote_path = f"{remote_dir}/{newest}"
        print(f"Pulling {remote_path} -> {out_path}")
        self.scp_from(remote_path, out_path)
        return out_path

    def _list_screenshot_files(self, remote_dir):
        out = self.ssh(f"ls -1 '{remote_dir}' 2>/dev/null || true")
        return [line.strip() for line in out.splitlines() if line.strip()]


def build_host_from_args(args):
    return MisterHost(
        host=args.host or os.environ.get("MISTER_HOST"),
        user=args.user or os.environ.get("MISTER_USER", "root"),
        password=args.password or os.environ.get("MISTER_PASSWORD"),
        putty_dir=args.putty_dir or os.environ.get("MISTER_PUTTY_DIR"),
    )


def add_common_args(p):
    p.add_argument("--host", help="MiSTer IP/hostname (or set MISTER_HOST)")
    p.add_argument("--user", help="SSH user (default root, or set MISTER_USER)")
    p.add_argument("--password", help="SSH/root password (or set MISTER_PASSWORD -- never commit this)")
    p.add_argument("--putty-dir", help="Directory containing plink.exe/pscp.exe (or set MISTER_PUTTY_DIR)")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p_deploy = sub.add_parser("deploy", help="Upload a .rbf to the MiSTer's cores directory")
    add_common_args(p_deploy)
    p_deploy.add_argument("--rbf", required=True, help="Local path to the .rbf to upload")
    p_deploy.add_argument("--rbf-remote-name", required=True, help="Filename to deploy as (must match the .mra's <rbf> tag)")

    p_launch = sub.add_parser("launch", help="Launch a .mra via MiSTer Remote's API")
    add_common_args(p_launch)
    p_launch.add_argument("--mra", required=True, help="Remote absolute path to the .mra file")

    p_shot = sub.add_parser("screenshot", help="Trigger and pull back a screenshot")
    add_common_args(p_shot)
    p_shot.add_argument("--core", required=True, help="Core/game short name (matches the screenshots subfolder, e.g. 'samuraia')")
    p_shot.add_argument("--out", required=True, help="Local path to save the screenshot to")
    p_shot.add_argument("--settle-seconds", type=float, default=3, help="Wait this long after launch before screenshotting (default 3)")

    p_cycle = sub.add_parser("cycle", help="deploy + launch + screenshot in one go")
    add_common_args(p_cycle)
    p_cycle.add_argument("--rbf", required=True)
    p_cycle.add_argument("--rbf-remote-name", required=True)
    p_cycle.add_argument("--mra", required=True)
    p_cycle.add_argument("--core", required=True)
    p_cycle.add_argument("--out", required=True)
    p_cycle.add_argument("--settle-seconds", type=float, default=3)

    args = parser.parse_args()
    host = build_host_from_args(args)

    if args.command == "deploy":
        host.deploy_rbf(args.rbf, args.rbf_remote_name)
    elif args.command == "launch":
        host.launch_mra(args.mra)
    elif args.command == "screenshot":
        host.take_screenshot(args.core, args.out, settle_seconds=args.settle_seconds)
    elif args.command == "cycle":
        host.deploy_rbf(args.rbf, args.rbf_remote_name)
        # A bit more margin beyond deploy_rbf's own `sync` -- a fully
        # automated deploy-then-launch has zero natural gap between the two,
        # unlike doing this by hand.
        time.sleep(2)
        host.launch_mra(args.mra)
        host.take_screenshot(args.core, args.out, settle_seconds=args.settle_seconds)
        print(f"Done: {args.out}")


if __name__ == "__main__":
    main()
