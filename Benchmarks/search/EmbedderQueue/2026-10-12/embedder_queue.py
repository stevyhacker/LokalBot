#!/usr/bin/env python3
"""How long a typed Ask or Quick Recall query waits behind background
embedding in LokalBot's embedder llama-server.

The app runs that server with `--parallel 1`, so it encodes inputs one at a
time, first in, first out. This script starts the bundled llama-server on a
private port with the app's exact embedder arguments (`LlamaServer.embedder`),
sends synthetic background work, then a query, and reports how long the query
took. Each request is preceded by the `/health` and `/v1/models` probes that
an inference lease runs. Only synthetic text is embedded; nothing touches the
installed app, its settings or its library.

Modes (run in the order given, with a cool-down between them):

  strategies    query wait behind one-shot, fixed-size and gated background
                requests; probe latency on a busy server; vector identity
  overhead      total background time for the same inputs split different ways
  before-after  the app's rule (at most 8 inputs and 2,000 characters per
                request, one request at a time, held while a query is in
                flight) against the previous one-request behaviour

    python3 -I Benchmarks/search/EmbedderQueue/2026-10-12/embedder_queue.py \\
        strategies overhead before-after

Each mode takes one to two minutes of GPU time on an M4 Max.
"""
import argparse
import hashlib
import http.client
import json
import os
import random
import secrets
import socket
import statistics
import subprocess
import sys
import threading
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
DEFAULT_SERVER = REPO / "Vendor/llama-cpp/llama-server"
DEFAULT_MODEL = Path.home() / "Library/Application Support/me.dotenv.LokalBot/models/embeddinggemma-2-Q8_0.gguf"
# EmbeddingIndex.modelSHA256
MODEL_SHA256 = "2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135"
APP_PORT = 17873
# EmbeddingIndex.documentPrefix and queryPrefix
DOCUMENT = "title: none | text: "
QUERY = "task: search result | query: "
# EmbeddingIndex.backgroundRequestMaximumInputs and ...MaximumCharacters
APP_MAX_INPUTS = 8
APP_MAX_CHARACTERS = 2_000
QUERIES = ["launch budget review", "what did we decide about hiring",
           "invoice from the vendor", "quarterly roadmap draft"]


class Server:
    def __init__(self, binary, model, port):
        self.port = port
        self.token = secrets.token_hex(16)
        # LlamaServer.start, then LlamaServer.embedder's extra arguments.
        self.arguments = [
            str(binary), "-m", str(model), "--host", "127.0.0.1", "--port", str(port),
            "-c", "2048", "-ngl", "99", "--jinja", "--no-webui", "--api-key", self.token,
            "--embeddings", "-b", "2048", "-ub", "2048", "--parallel", "1"]
        self.process = None

    def __enter__(self):
        self.process = subprocess.Popen(self.arguments, stdout=subprocess.DEVNULL,
                                        stderr=subprocess.DEVNULL)
        client = Client(self)
        for _ in range(240):
            if self.process.poll() is not None:
                sys.exit("llama-server exited during startup")
            try:
                if client.get("/health").get("status") == "ok":
                    return self
            except (OSError, http.client.HTTPException, ValueError):
                client.reset()
            time.sleep(0.25)
        self.__exit__(None, None, None)
        sys.exit("llama-server did not become healthy")

    def __exit__(self, *_):
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()


class Client:
    """One keep-alive connection, like URLSession. Use one per thread."""

    def __init__(self, server):
        self.server = server
        self.connection = None

    def reset(self):
        if self.connection:
            self.connection.close()
        self.connection = None

    def call(self, method, path, body=None):
        # The server closes idle keep-alive connections; reconnect once, as
        # URLSession does.
        for attempt in range(2):
            if self.connection is None:
                self.connection = http.client.HTTPConnection("127.0.0.1", self.server.port, timeout=120)
            try:
                self.connection.request(
                    method, path, body=json.dumps(body) if body is not None else None,
                    headers={"Content-Type": "application/json",
                             "Authorization": f"Bearer {self.server.token}"})
                response = self.connection.getresponse()
                return json.loads(response.read())
            except (BrokenPipeError, ConnectionResetError, http.client.RemoteDisconnected):
                self.reset()
                if attempt:
                    raise

    def get(self, path):
        return self.call("GET", path)

    def tokens(self, text):
        return len(self.call("POST", "/tokenize", {"content": text})["tokens"])

    def embed(self, texts, prefix):
        # InferenceBroker's lease checks the runtime before every request.
        self.get("/health")
        self.get("/v1/models")
        payload = self.call("POST", "/v1/embeddings", {
            "input": [prefix + text for text in texts],
            "model": "embeddinggemma-2-q8", "cache_prompt": False})
        rows = sorted(payload["data"], key=lambda row: row["index"])
        return [row["embedding"] for row in rows]


# --- synthetic texts ---------------------------------------------------------

WORDS = ("budget launch review roadmap hiring plan quarterly revenue design "
         "meeting notes customer feedback deadline invoice draft release "
         "metrics dashboard onboarding contract vendor timeline agenda").split()


def ocr_text(rng, characters=1_500):
    """Screen-OCR-like text: UI labels, numbers, dates, paths and symbols.
    About 880 tokens per 1,500 characters, close to real OCR."""
    parts = []
    length = 0
    while length < characters:
        kind = rng.random()
        if kind < 0.35:
            part = rng.choice(WORDS).capitalize()
        elif kind < 0.55:
            part = f"{rng.randint(0, 99999):,}"
        elif kind < 0.7:
            part = (f"{rng.randint(1, 12)}/{rng.randint(1, 28)}/26 "
                    f"{rng.randint(0, 23):02}:{rng.randint(0, 59):02}")
        elif kind < 0.8:
            part = f"~/{rng.choice(WORDS)}_{rng.randint(1, 99)}.{rng.choice(['pdf', 'xlsx', 'md'])}"
        elif kind < 0.9:
            part = rng.choice(["|", "•", "→", "⌘K", "…", "—", "#", "@", "%"])
        else:
            part = "".join(rng.choice("abcdefghijklmnopqrstuvwxyz0123456789")
                           for _ in range(rng.randint(4, 10)))
        parts.append(part)
        length += len(part) + 1
    return " ".join(parts)[:characters]


def meeting_chunk(rng, characters=500):
    """Transcript-like text: about 93 tokens per 500 characters."""
    lines = []
    length = 0
    while length < characters:
        sentence = " ".join(rng.choice(WORDS) for _ in range(rng.randint(6, 16)))
        line = f"Speaker {rng.randint(1, 4)}: {sentence.capitalize()}.\n"
        lines.append(line)
        length += len(line)
    return "".join(lines)[:characters]


# --- background strategies ---------------------------------------------------

def one_request(texts):
    return [(0, len(texts))]


def fixed_size(size):
    def plan(texts):
        return [(start, min(start + size, len(texts))) for start in range(0, len(texts), size)]
    return plan


def app_rule(texts):
    """Mirror of EmbeddingIndex.backgroundRequestRanges."""
    ranges = []
    start = 0
    characters = 0
    for index, text in enumerate(texts):
        if index > start and (index - start == APP_MAX_INPUTS
                              or characters + len(text) > APP_MAX_CHARACTERS):
            ranges.append((start, index))
            start = index
            characters = 0
        characters += len(text)
    if start < len(texts):
        ranges.append((start, len(texts)))
    return ranges


class Gate:
    """Mirror of EmbeddingRequestGate: one background request at a time, none
    while a foreground request is in flight."""

    def __init__(self):
        self.condition = threading.Condition()
        self.foreground_count = 0
        self.background_running = False

    def background(self, work):
        with self.condition:
            while self.foreground_count or self.background_running:
                self.condition.wait()
            self.background_running = True
        try:
            return work()
        finally:
            with self.condition:
                self.background_running = False
                self.condition.notify_all()

    def foreground(self, work):
        with self.condition:
            self.foreground_count += 1
        try:
            return work()
        finally:
            with self.condition:
                self.foreground_count -= 1
                self.condition.notify_all()


def embed_background(client, texts, plan, gate=None):
    vectors = []
    for start, end in plan(texts):
        part = texts[start:end]
        if gate:
            vectors += gate.background(lambda: client.embed(part, DOCUMENT))
        else:
            vectors += client.embed(part, DOCUMENT)
    return vectors


def trial(server, jobs, plan, gated, delay, query):
    """Starts each background job on its own connection, sends the query
    `delay` seconds later. Returns (query seconds, background wall seconds)."""
    gate = Gate() if gated else None
    finished = []
    threads = []
    started = time.perf_counter()
    for texts in jobs:
        def run(texts=texts):
            embed_background(Client(server), texts, plan, gate)
            finished.append(time.perf_counter() - started)
        thread = threading.Thread(target=run)
        thread.start()
        threads.append(thread)
    time.sleep(delay)
    client = Client(server)
    query_started = time.perf_counter()
    if gate:
        gate.foreground(lambda: client.embed([query], QUERY))
    else:
        client.embed([query], QUERY)
    waited = time.perf_counter() - query_started
    for thread in threads:
        thread.join()
    return waited, max(finished)


def milliseconds(seconds):
    return f"{seconds * 1000:6.0f}"


def report_trials(label, name, results):
    waits = [result[0] for result in results]
    walls = [result[1] for result in results]
    print(f"  {label:22} {name:14} query {milliseconds(statistics.median(waits))} / "
          f"{milliseconds(max(waits))} ms | background {milliseconds(statistics.median(walls))} ms")


def max_difference(left, right):
    assert len(left) == len(right)
    return max(abs(x - y) for a, b in zip(left, right) for x, y in zip(a, b))


# --- modes -------------------------------------------------------------------

def run_strategies(server, screens, meeting):
    client = Client(server)
    alone = []
    for query in QUERIES * 2:
        started = time.perf_counter()
        client.embed([query], QUERY)
        alone.append(time.perf_counter() - started)
    print(f"query alone, with lease probes: median {milliseconds(statistics.median(alone)).strip()} ms")

    busy = threading.Thread(target=lambda: Client(server).embed(meeting, DOCUMENT))
    busy.start()
    time.sleep(0.05)
    started = time.perf_counter()
    client.get("/health")
    health = time.perf_counter() - started
    started = time.perf_counter()
    client.get("/v1/models")
    models = time.perf_counter() - started
    busy.join()
    print(f"lease probes behind 100 chunks: /health {health * 1000:.1f} ms, /v1/models {models * 1000:.1f} ms")

    print("\nquery sent 50 ms after background starts, 3 trials: median / max | background wall time")
    single = [("one request", one_request, False), ("4 per request", fixed_size(4), False),
              ("8 per request", fixed_size(8), False), ("16 per request", fixed_size(16), False),
              ("app rule+gate", app_rule, True)]
    both = [("one request", one_request, False), ("8 per request", fixed_size(8), False),
            ("8 + gate", fixed_size(8), True), ("app rule", app_rule, False),
            ("app rule+gate", app_rule, True)]
    for label, jobs, strategies in [("screen backfill 32", [screens], single),
                                    ("meeting 100 chunks", [meeting], single),
                                    ("both at once", [meeting, screens], both)]:
        for name, plan, gated in strategies:
            results = [trial(server, jobs, plan, gated, 0.05, QUERIES[i]) for i in range(3)]
            report_trials(label, name, results)
            time.sleep(0.3)

    whole = client.embed(screens, DOCUMENT)
    by_eight = embed_background(client, screens, fixed_size(8))
    one_by_one = embed_background(client, screens[:8], fixed_size(1))
    meeting_whole = client.embed(meeting, DOCUMENT)
    meeting_split = embed_background(client, meeting, app_rule)
    query_alone = client.embed([QUERIES[0]], QUERY)
    busy = threading.Thread(target=lambda: Client(server).embed(meeting, DOCUMENT))
    busy.start()
    time.sleep(0.05)
    query_busy = client.embed([QUERIES[0]], QUERY)
    busy.join()
    print("\nvector identity, largest absolute difference:")
    print(f"  32 screen rows, one request vs 4 × 8:            {max_difference(whole, by_eight)}")
    print(f"  8 screen rows, one request vs one per request:  {max_difference(whole[:8], one_by_one)}")
    print(f"  100 meeting chunks, one request vs app rule:    {max_difference(meeting_whole, meeting_split)}")
    print(f"  query alone vs behind a meeting:                {max_difference(query_alone, query_busy)}")


def run_overhead(server, screens, meeting):
    client = Client(server)
    tiny = []
    for _ in range(20):
        started = time.perf_counter()
        client.embed(["ok"], DOCUMENT)
        tiny.append(time.perf_counter() - started)
    probes = []
    for _ in range(20):
        started = time.perf_counter()
        client.get("/health")
        client.get("/v1/models")
        probes.append(time.perf_counter() - started)
    print(f"one tiny request with probes: median {statistics.median(tiny) * 1000:.1f} ms; "
          f"probes alone {statistics.median(probes) * 1000:.2f} ms")
    print("\ntotal background time, no queries, 3 runs: median (min)")
    for label, texts in [("meeting 100 chunks", meeting), ("screen backfill 32", screens)]:
        for name, plan in [("one request", one_request), ("8 per request", fixed_size(8)),
                           ("app rule", app_rule), ("4 per request", fixed_size(4)),
                           ("1 per request", fixed_size(1))]:
            walls = []
            for _ in range(3):
                started = time.perf_counter()
                embed_background(client, texts, plan)
                walls.append(time.perf_counter() - started)
                time.sleep(0.2)
            print(f"  {label:22} {name:14} {len(plan(texts)):3} requests  "
                  f"{milliseconds(statistics.median(walls))} ms ({min(walls) * 1000:.0f})")


def run_before_after(server, screens, meeting):
    print(f"app rule: screen backfill 32 -> {len(app_rule(screens))} requests, "
          f"meeting 100 chunks -> {len(app_rule(meeting))} requests")
    print("\nquery sent 50 ms after background starts, 3 trials: median / max | background wall time")
    for label, jobs in [("screen backfill 32", [screens]), ("meeting 100 chunks", [meeting]),
                        ("both at once", [meeting, screens])]:
        for name, plan, gated in [("before", one_request, False), ("after", app_rule, True)]:
            results = [trial(server, jobs, plan, gated, 0.05, QUERIES[i]) for i in range(3)]
            report_trials(label, name, results)
            time.sleep(0.3)

    print("\nboth at once, query sent at random 20–600 ms offsets, 8 trials: median / max")
    offsets_rng = random.Random(7)
    offsets = [offsets_rng.uniform(0.02, 0.6) for _ in range(8)]
    for name, plan, gated in [("before", one_request, False), ("after", app_rule, True)]:
        waits = []
        for index, delay in enumerate(offsets):
            waits.append(trial(server, [meeting, screens], plan, gated, delay, QUERIES[index % 4])[0])
            time.sleep(0.2)
        print(f"  {name:6} query {milliseconds(statistics.median(waits))} / {milliseconds(max(waits))} ms")

    client = Client(server)
    whole = client.embed(screens, DOCUMENT) + client.embed(meeting, DOCUMENT)
    split = embed_background(client, screens, app_rule) + embed_background(client, meeting, app_rule)
    print(f"\nvectors, one request vs app rule: {len(whole)} and {len(split)} inputs, "
          f"largest absolute difference {max_difference(whole, split)}")


MODES = {"strategies": run_strategies, "overhead": run_overhead, "before-after": run_before_after}


def port_in_use(port):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        return probe.connect_ex(("127.0.0.1", port)) == 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("modes", nargs="+", choices=sorted(MODES))
    parser.add_argument("--server", type=Path, default=DEFAULT_SERVER)
    parser.add_argument("--model", type=Path, default=DEFAULT_MODEL)
    parser.add_argument("--port", type=int, default=18873)
    parser.add_argument("--cooldown", type=float, default=60, help="seconds between modes")
    arguments = parser.parse_args()

    if arguments.port == APP_PORT:
        sys.exit(f"port {APP_PORT} belongs to the app's embedder; choose another")
    if port_in_use(arguments.port):
        sys.exit(f"port {arguments.port} is already in use")
    for path in (arguments.server, arguments.model):
        if not path.exists():
            sys.exit(f"missing {path}")
    digest = hashlib.sha256()
    with open(arguments.model, "rb") as model:
        for block in iter(lambda: model.read(1 << 20), b""):
            digest.update(block)
    build = arguments.server.parent / ".lokalbot-build"
    print(f"llama.cpp: {build.read_text().splitlines()[0] if build.exists() else 'unknown build'}")
    print(f"model: {arguments.model.name}, sha256 {'matches the app' if digest.hexdigest() == MODEL_SHA256 else 'DIFFERS from the app: ' + digest.hexdigest()}")

    rng = random.Random(20261012)
    screens = [ocr_text(rng) for _ in range(32)]
    meeting = [meeting_chunk(rng) for _ in range(100)]
    with Server(arguments.server, arguments.model, arguments.port) as server:
        client = Client(server)
        screen_tokens = statistics.mean(client.tokens(DOCUMENT + text) for text in screens[:8])
        meeting_tokens = statistics.mean(client.tokens(DOCUMENT + text) for text in meeting[:8])
        print(f"screen row ≈ {screen_tokens:.0f} tokens, meeting chunk ≈ {meeting_tokens:.0f} tokens")
        client.embed(screens[:4], DOCUMENT)  # warm up
        for index, mode in enumerate(arguments.modes):
            if index:
                time.sleep(arguments.cooldown)
            print(f"\n== {mode}\n")
            MODES[mode](server, screens, meeting)


if __name__ == "__main__":
    main()
