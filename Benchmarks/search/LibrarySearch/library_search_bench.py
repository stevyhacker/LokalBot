"""Times `lokalbot-cli search` and MCP `search_meetings` on a synthetic library.

Usage:
    python3 -I Benchmarks/search/LibrarySearch/library_search_bench.py \
        --cli before=/path/to/old/lokalbot-cli --cli after=/path/to/new/lokalbot-cli

Builds a library of made-up meetings in a temporary folder (250 meetings with
200 transcript segments each by default; "telescope checksum" is in every 25th
meeting), checks that every binary prints the same hits, then prints median
milliseconds. CLI rows start a new process per search, like an agent running
the CLI. MCP rows send repeated requests to one `lokalbot-cli mcp` process and
leave out the first. Runs alternate between binaries so load on the machine
affects each the same way.
"""

import argparse
import datetime
import json
import os
import random
import statistics
import subprocess
import sys
import tempfile
import time
import uuid

QUERIES = [
    ("rare words", "telescope checksum"),
    ("quoted phrase", '"telescope checksum"'),
    ("absent short word", "api"),
    ("word in 1 of 5 segments", "budget"),
    ("word in most segments", "the"),
]

WORDS = (
    "we the and to of a in that is for it on with as this be are was have not they "
    "but at from or by an will can about so if what there all would our project "
    "release roadmap customer budget pricing deadline team design review feedback "
    "deploy server database cache latency migration onboarding contract invoice "
    "quarter planning metrics dashboard sprint backlog ticket bug fix test build "
    "izveštaj sastanak budžet rok tim klijent ugovor plaćanje café résumé naïve "
    "meeting agenda notes action item follow up schedule calendar vendor partner "
    "hiring interview candidate offer salary equity board investor runway growth"
).split()


def make_library(root, meetings, segments_per_meeting):
    rng = random.Random(42)
    start = datetime.datetime(2026, 11, 1, 9, 0, tzinfo=datetime.timezone.utc)
    iso = lambda moment: moment.strftime("%Y-%m-%dT%H:%M:%SZ")
    for index in range(meetings):
        meeting_id = str(uuid.UUID(int=rng.getrandbits(128), version=4)).upper()
        started = start - datetime.timedelta(hours=6 * index)
        relative = f"meetings/{started.year}/{started.month:02d}/{meeting_id.lower()[:8]}-synthetic"
        folder = os.path.join(root, relative)
        os.makedirs(folder, exist_ok=True)
        meta = {
            "appName": "Zoom", "endedAt": iso(started + datetime.timedelta(minutes=45)), "hasSystemTrack": True,
            "id": meeting_id, "relativePath": relative, "startedAt": iso(started), "title": f"Weekly sync {index}",
        }
        with open(os.path.join(folder, "meta.json"), "w") as handle:
            json.dump(meta, handle, indent=2, sort_keys=True)
        segments = []
        for position in range(segments_per_meeting):
            text = " ".join(rng.choice(WORDS) for _ in range(rng.randint(12, 28)))
            text = text[0].upper() + text[1:] + "."
            if index % 25 == 0 and position == 120:
                text = "We found the telescope checksum mismatch in the nightly build."
            segments.append({"end": position * 12.0 + 11.0, "speaker": "me" if position % 2 == 0 else "them",
                             "start": position * 12.0, "text": text, "timingPrecision": "span"})
        # Swift's JSONEncoder escapes "/" and writes other characters as they are.
        body = json.dumps({"engine": "synthetic", "segments": segments}, indent=2, sort_keys=True,
                          ensure_ascii=False).replace("/", "\\/")
        with open(os.path.join(folder, "transcript.json"), "w", encoding="utf-8") as handle:
            handle.write(body)
        with open(os.path.join(folder, "summary.md"), "w", encoding="utf-8") as handle:
            handle.write(f"## TL;DR\nWeekly sync {index}: roadmap, budget and hiring.\n")
    # The synthetic library's own agent-access switch, so the CLI may read it.
    os.makedirs(os.path.join(root, "control"), exist_ok=True)
    with open(os.path.join(root, "control", "agent-access-enabled"), "w") as handle:
        handle.write("synthetic")


def cli_ms(cli, query):
    started = time.perf_counter()
    subprocess.run([cli, "search", query], stdout=subprocess.DEVNULL, check=True)
    return (time.perf_counter() - started) * 1000


class MCP:
    def __init__(self, cli):
        self.process = subprocess.Popen([cli, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, text=True, bufsize=1)
        self.next_id = 0
        self.call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                 "clientInfo": {"name": "library-search-bench", "version": "1"}})
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def send(self, message):
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()

    def call(self, method, params):
        self.next_id += 1
        self.send({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params})
        return json.loads(self.process.stdout.readline())

    def search_ms(self, query):
        started = time.perf_counter()
        self.call("tools/call", {"name": "search_meetings", "arguments": {"query": query}})
        return (time.perf_counter() - started) * 1000

    def close(self):
        self.process.stdin.close()
        self.process.wait()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", action="append", required=True, help="label=path, repeatable")
    parser.add_argument("--meetings", type=int, default=250)
    parser.add_argument("--segments", type=int, default=200)
    parser.add_argument("--runs", type=int, default=7)
    args = parser.parse_args()
    binaries = [entry.split("=", 1) for entry in args.cli]

    with tempfile.TemporaryDirectory(prefix="library-search-bench-") as root:
        make_library(root, args.meetings, args.segments)
        os.environ["LOKALBOT_STORAGE_ROOT"] = root
        for _, query in QUERIES:
            outputs = {label: subprocess.run([cli, "search", query, "--limit", "500"], capture_output=True,
                                             text=True, check=True).stdout for label, cli in binaries}
            if len(set(outputs.values())) != 1:
                sys.exit(f"hits differ for {query!r}")

        print(f"{args.meetings} meetings x {args.segments} segments, median of {args.runs} runs, ms\n")
        print("| Query | Route | " + " | ".join(label for label, _ in binaries) + " |")
        print("| --- | --- | " + " | ".join("---:" for _ in binaries) + " |")
        for name, query in QUERIES:
            cli_runs = {label: [] for label, _ in binaries}
            for _ in range(args.runs + 1):
                for label, cli in binaries:
                    cli_runs[label].append(cli_ms(cli, query))
            servers = {label: MCP(cli) for label, cli in binaries}
            mcp_runs = {label: [] for label, _ in binaries}
            for _ in range(args.runs + 1):
                for label, _ in binaries:
                    mcp_runs[label].append(servers[label].search_ms(query))
            for server in servers.values():
                server.close()
            for route, runs in (("CLI", cli_runs), ("MCP warm", mcp_runs)):
                cells = " | ".join(f"{statistics.median(runs[label][1:]):.0f}" for label, _ in binaries)
                print(f"| {name}: `{query}` | {route} | {cells} |")


if __name__ == "__main__":
    main()
