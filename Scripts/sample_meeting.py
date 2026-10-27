#!/usr/bin/env python3
"""Build and check the bundled sample meeting (LokalBot/Resources/SampleMeeting).

    sample_meeting.py build [--lang en] [--cache DIR]
        Voice every turn of script.<lang>.json with the script's voice service,
        ElevenLabs (ELEVENLABS_API_KEY, or ~/.config/elevenlabs/env) or Gemini
        (GEMINI_API_KEY), join the turns into one mono recording, and write
        <audio>.m4a plus the reference transcript (reference.<lang>.json and
        reference.<lang>.md) with each turn's measured start and end. Only the
        script text leaves the computer, and only here: the apps never call a
        voice service. Synthesized turns are cached by text, voice and model
        settings, so editing one line re-voices only that line (and, with
        ElevenLabs, its neighbours, which it hears as context).

    sample_meeting.py check [--lang en] <transcript.json | meeting folder> [--summary FILE]
        Score a LokalBot transcript of the sample against the reference: word
        error rate (character error rate for Chinese and Japanese), which names,
        numbers and dates came through, and how well speakers were separated.
        Then print the checklist a person goes through for the notes and Ask.

Needs ffmpeg and ffprobe on PATH for build; check uses only the standard library.
"""
import argparse, base64, hashlib, json, os, re, struct, subprocess, sys, tempfile, time, unicodedata, urllib.error, urllib.request, wave

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SAMPLE_DIR = os.path.join(ROOT, "LokalBot", "Resources", "SampleMeeting")
RATE = 24_000
LEAD_IN = 0.6
TAIL = 1.2
TARGET_RMS_DB = -21.0


def load(lang, kind):
    with open(os.path.join(SAMPLE_DIR, f"{kind}.{lang}.json"), encoding="utf-8") as f:
        return json.load(f)


def stamp(seconds):
    s = int(seconds)
    return f"{s // 60:02d}:{s % 60:02d}"


# ---------------------------------------------------------------- build

VOICE_SERVICES = {
    "elevenlabs": ("ELEVENLABS_API_KEY", "~/.config/elevenlabs/env"),
    "gemini": ("GEMINI_API_KEY", None),
}


def api_key(provider):
    name, path = VOICE_SERVICES[provider]
    key = os.environ.get(name)
    if key:
        return key
    if path and os.path.exists(os.path.expanduser(path)):
        for line in open(os.path.expanduser(path), encoding="utf-8"):
            key_name, _, value = line.strip().partition("=")
            if key_name.removeprefix("export ").strip() == name:
                return value.strip().strip("'\"")
    sys.exit(f"Set {name} to voice the script.")


def speech(text, voice, tts, previous, following):
    """One turn's audio file bytes from the script's voice service."""
    if tts["provider"] == "gemini":
        # Gemini voices each turn alone, with no seed; `style` sets the delivery
        # without being spoken.
        content = {"type": "text", "text": text,
                   "annotations": [{"type": "speech_metadata", "style": tts["style"]}]}
        body = {"model": tts["model"], "input": [{"type": "user_input", "content": [content]}],
                "response_format": {"type": "audio"},
                "generation_config": {"speech_config": [{"voice": voice}]}}
        request = urllib.request.Request(
            "https://generativelanguage.googleapis.com/v1beta/interactions", data=json.dumps(body).encode(),
            headers={"x-goog-api-key": api_key("gemini"), "Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=180) as response:
            steps = json.load(response).get("steps", [])
        audio = [c["data"] for step in steps for c in step.get("content") or [] if c.get("type") == "audio"]
        if not audio:
            raise RuntimeError(f"Gemini returned no audio for: {text[:60]}")
        return base64.b64decode(audio[0])  # WAV, 24 kHz mono
    body = {"text": text, "model_id": tts["model"], "seed": tts["seed"]}
    if previous:
        body["previous_text"] = previous
    if following:
        body["next_text"] = following
    request = urllib.request.Request(
        f"https://api.elevenlabs.io/v1/text-to-speech/{voice}?output_format=mp3_44100_128",
        data=json.dumps(body).encode(),
        headers={"xi-api-key": api_key("elevenlabs"), "Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=180) as response:
        return response.read()  # MP3


def synthesize(text, voice, tts, previous, following, cache):
    """One turn as 24 kHz mono 16-bit PCM, edges trimmed. Cached by content."""
    if tts["provider"] == "elevenlabs":
        ident = [text, voice, tts["model"], tts["seed"], previous, following]
    else:
        ident = [text, voice, tts]
    digest = hashlib.sha256(json.dumps(ident, ensure_ascii=False, sort_keys=True).encode()).hexdigest()[:20]
    wav_path = os.path.join(cache, f"{digest}.wav")
    if not os.path.exists(wav_path):
        for attempt in range(6):
            try:
                audio = speech(text, voice, tts, previous, following)
                break
            except urllib.error.HTTPError as error:  # rate limits and overload pass; anything else stops the build
                if error.code not in (429, 500, 502, 503) or attempt == 5:
                    raise
                time.sleep(20 * (attempt + 1))
        source = os.path.join(cache, f"{digest}.source")
        with open(source, "wb") as f:
            f.write(audio)
        trim = ("silenceremove=start_periods=1:start_threshold=-50dB,areverse,"
                "silenceremove=start_periods=1:start_threshold=-50dB,areverse")
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", source, "-af", trim,
                        "-ar", str(RATE), "-ac", "1", "-c:a", "pcm_s16le", wav_path + ".tmp.wav"], check=True)
        os.replace(wav_path + ".tmp.wav", wav_path)
    with wave.open(wav_path) as reader:
        assert (reader.getnchannels(), reader.getsampwidth(), reader.getframerate()) == (1, 2, RATE)
        return reader.readframes(reader.getnframes())


def level(pcm):
    """Scale a turn to the shared speech level, so both voices sit alike."""
    count = len(pcm) // 2
    samples = struct.unpack(f"<{count}h", pcm)
    rms = (sum(s * s for s in samples) / max(count, 1)) ** 0.5
    if rms == 0:
        raise RuntimeError("a synthesized turn is silent")
    gain = (32768 * 10 ** (TARGET_RMS_DB / 20)) / rms
    gain = min(gain, 32000 / max(abs(s) for s in samples))
    return struct.pack(f"<{count}h", *(max(-32768, min(32767, int(s * gain))) for s in samples))


def gap(turns, index):
    """Pause before a turn: shorter when the same person keeps talking, a little
    longer before a change of subject. Deterministic, so rebuilds line up."""
    turn = turns[index]
    if "gapBefore" in turn:
        return turn["gapBefore"]
    if turns[index - 1]["speaker"] == turn["speaker"]:
        return 0.45
    jitter = int(hashlib.sha256(turn["id"].encode()).hexdigest()[:4], 16) / 0xFFFF
    return round(0.5 + 0.35 * jitter, 2)


def build(args):
    script = load(args.lang, "script")
    turns, speakers, tts = script["turns"], script["speakers"], script["tts"]
    cache = args.cache or os.path.join(tempfile.gettempdir(), "lokalbot-sample-meeting")
    os.makedirs(cache, exist_ok=True)
    mix = bytearray(bytes(int(LEAD_IN * RATE) * 2))
    reference = []
    for index, turn in enumerate(turns):
        if index:
            mix.extend(bytes(int(gap(turns, index) * RATE) * 2))
        previous = turns[index - 1]["text"] if index else None
        following = turns[index + 1]["text"] if index + 1 < len(turns) else None
        pcm = level(synthesize(turn["text"], speakers[turn["speaker"]]["voice"], tts, previous, following, cache))
        start = len(mix) / 2 / RATE
        mix.extend(pcm)
        end = len(mix) / 2 / RATE
        reference.append({"id": turn["id"], "speaker": turn["speaker"], "name": speakers[turn["speaker"]]["name"],
                          "start": round(start, 2), "end": round(end, 2), "text": turn["text"]})
        print(f"{turn['id']} {stamp(start)} {end - start:5.2f}s {speakers[turn['speaker']]['name']}: {turn['text'][:60]}")
    mix.extend(bytes(int(TAIL * RATE) * 2))

    with tempfile.TemporaryDirectory() as work:
        mix_path = os.path.join(work, "mix.wav")
        with wave.open(mix_path, "wb") as writer:
            writer.setnchannels(1)
            writer.setsampwidth(2)
            writer.setframerate(RATE)
            writer.writeframes(bytes(mix))
        out = os.path.join(SAMPLE_DIR, script["audio"])
        # AAC-LC: symphonia (Linux, Windows) and AVFoundation (Mac) both decode it.
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", mix_path, "-c:a", "aac", "-b:a", "40k",
                        "-ar", str(RATE), "-ac", "1", "-map_metadata", "-1", "-movflags", "+faststart",
                        "-metadata", f"title={script['title']}",
                        "-metadata", "comment=LokalBot sample meeting. Synthetic voices; the people and company are fictional.",
                        "-fflags", "+bitexact", "-flags:a", "+bitexact", out], check=True)
    duration = len(mix) / 2 / RATE
    with open(os.path.join(SAMPLE_DIR, f"reference.{args.lang}.json"), "w", encoding="utf-8") as f:
        json.dump({"sampleID": script["sampleID"], "language": args.lang, "title": script["title"],
                   "duration": round(duration, 2), "turns": reference}, f, ensure_ascii=False, indent=2)
        f.write("\n")
    with open(os.path.join(SAMPLE_DIR, f"reference.{args.lang}.md"), "w", encoding="utf-8") as f:
        f.write(f"# {script['title']}\n\n")
        f.write("Reference transcript of the LokalBot sample meeting: what each synthetic voice was asked to say, "
                "with the time each turn starts in the recording. The people and the company are fictional.\n\n")
        for turn in reference:
            f.write(f"**[{stamp(turn['start'])}] {turn['name']}:** {turn['text']}\n\n")
    size = os.path.getsize(out)
    print(f"\n{out}: {stamp(duration)} ({duration:.1f} s), {size / 1e6:.2f} MB")


# ---------------------------------------------------------------- check

ONES = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split()
TENS = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()
ORDINALS = {"one": "first", "two": "second", "three": "third", "five": "fifth", "eight": "eighth",
            "nine": "ninth", "twelve": "twelfth"}


def words_for(n):
    if n < 20:
        return ONES[n]
    if n < 100:
        return TENS[n // 10] + ("" if n % 10 == 0 else " " + ONES[n % 10])
    for size, name in ((1_000_000_000, "billion"), (1_000_000, "million"), (1000, "thousand"), (100, "hundred")):
        if n >= size:
            rest = n % size
            return words_for(n // size) + " " + name + ("" if rest == 0 else " " + words_for(rest))
    return str(n)


def ordinal(words):
    head, _, last = words.rpartition(" ")
    if last in ORDINALS:
        last = ORDINALS[last]
    elif last.endswith("y"):
        last = last[:-1] + "ieth"
    else:
        last += "th"
    return (head + " " + last).strip()


def spell_numbers(text):
    text = re.sub(r"(?<=\d),(?=\d{3})", "", text)
    text = re.sub(r"(\d+)(st|nd|rd|th)\b", lambda m: ordinal(words_for(int(m.group(1)))), text)
    text = re.sub(r"(\d+)\.(\d+)",
                  lambda m: words_for(int(m.group(1))) + " point " + " ".join(ONES[int(d)] for d in m.group(2)), text)
    text = re.sub(r"(?<=[a-z])(?=\d)|(?<=\d)(?=[a-z])", " ", text)
    return re.sub(r"\d+", lambda m: words_for(int(m.group(0))), text)


# German: digits become words, "einhundert" and "hundert" agree, and an
# ordinal's case ending ("18." / "achtzehnte" / "achtzehnten") doesn't count.
DE_ONES = ("null eins zwei drei vier fünf sechs sieben acht neun zehn elf zwölf dreizehn vierzehn "
           "fünfzehn sechzehn siebzehn achtzehn neunzehn").split()
DE_TENS = "_ _ zwanzig dreißig vierzig fünfzig sechzig siebzig achtzig neunzig".split()
DE_MONTHS = "januar februar märz april mai juni juli august september oktober november dezember".split()


def de_words(n, joined=False):
    """German number words; `joined` is the form inside a compound ("ein")."""
    if n < 20:
        return "ein" if joined and n == 1 else DE_ONES[n]
    if n < 100:
        ones = n % 10
        return (de_words(ones, True) + "und" if ones else "") + DE_TENS[n // 10]
    if n < 1_000_000:
        size, name = (1000, "tausend") if n >= 1000 else (100, "hundert")
        head, rest = divmod(n, size)
        return ("" if head == 1 else de_words(head, True)) + name + (de_words(rest) if rest else "")
    head, rest = divmod(n, 1_000_000)
    return ("eine million" if head == 1 else de_words(head) + " millionen") + (" " + de_words(rest) if rest else "")


def de_ordinal(n):
    stem = {1: "erst", 3: "dritt", 7: "siebt", 8: "acht"}.get(n) or de_words(n) + ("t" if n < 20 else "st")
    return stem + "en"


DE_ORDINAL = re.compile(r"^(" + "|".join(de_ordinal(n)[:-2].replace("ß", "ss") for n in range(1, 32)) + r")(e|en|er|es|em)$")


def spell_numbers_de(text):
    text = re.sub(r"(?<=\d)\.(?=\d{3}\b)", "", text)
    months = "|".join(DE_MONTHS)
    text = re.sub(rf"\b(\d{{1,2}})\.(?=\s*(?:{months})\b)", lambda m: de_ordinal(int(m.group(1))), text)
    text = re.sub(r"\b(am|zum|vom|bis|den|dem|der|des) ([1-9]|[12]\d|3[01])\.(?!\d)",
                  lambda m: m.group(1) + " " + de_ordinal(int(m.group(2))), text)
    text = re.sub(r"(\d+)([.,])(\d+)", lambda m: de_words(int(m.group(1))) + (" punkt " if m.group(2) == "." else " komma ")
                  + " ".join(DE_ONES[int(d)] for d in m.group(3)), text)
    text = re.sub(r"(?<=[^\W\d_])(?=\d)|(?<=\d)(?=[^\W\d_])", " ", text)
    return re.sub(r"\d+", lambda m: de_words(int(m.group(0))), text)


# Serbian: Cyrillic output reads as Latin, digits become words, "dve" and
# "dva" agree, and an ordinal's case ending doesn't count.
SR_CYRILLIC = dict(zip("абвгдђежзијклљмнњопрстћуфхцчџш",
                       "a b v g d đ e ž z i j k l lj m n nj o p r s t ć u f h c č dž š".split()))
SR_ONES = ("nula jedan dva tri četiri pet šest sedam osam devet deset jedanaest dvanaest trinaest četrnaest "
           "petnaest šesnaest sedamnaest osamnaest devetnaest").split()
SR_TENS = "_ _ dvadeset trideset četrdeset pedeset šezdeset sedamdeset osamdeset devedeset".split()
SR_HUNDREDS = "_ sto dvesta trista četiristo petsto šeststo sedamsto osamsto devetsto".split()
SR_MONTHS = "januar februar mart april maj jun jul avgust septembar oktobar novembar decembar".split()


def sr_words(n):
    if n < 20:
        return SR_ONES[n]
    if n < 100:
        return SR_TENS[n // 10] + ("" if n % 10 == 0 else " " + SR_ONES[n % 10])
    if n < 1000:
        return SR_HUNDREDS[n // 100] + ("" if n % 100 == 0 else " " + sr_words(n % 100))
    for size, one, few, many in ((1_000_000, "milion", "miliona", "miliona"), (1000, "hiljadu", "hiljade", "hiljada")):
        if n >= size:
            head, rest = divmod(n, size)
            name = one if head == 1 else few if head % 10 in (2, 3, 4) and head % 100 not in (12, 13, 14) else many
            words = name if head == 1 and size == 1000 else (sr_words(head) + " " if head > 1 else "") + name
            return words + ("" if rest == 0 else " " + sr_words(rest))


def sr_ordinal(n):
    stems = {1: "prv", 2: "drug", 3: "treć", 4: "četvrt", 7: "sedm", 8: "osm"}
    if n > 20 and n % 10:
        return SR_TENS[n // 10] + " " + sr_ordinal(n % 10)
    return stems.get(n, sr_words(n)) + "i"


SR_ORDINAL = re.compile(r"^(" + "|".join(sr_ordinal(n)[:-1] for n in range(1, 21)) + r"|trideset)(i|a|o|e|u|og|oga|om|ome|oj|ih|im)$")


def spell_numbers_sr(text):
    text = re.sub(r"(?<=\d)\.(?=\d{3}\b)", "", text)
    months = "|".join(m[:-2] if m.endswith("ar") else m for m in SR_MONTHS)
    text = re.sub(rf"\b(\d{{1,2}})\.(?=\s*(?:{months}))", lambda m: sr_ordinal(int(m.group(1))), text)
    text = re.sub(r"\b(do|od|za|na|pre|posle|oko) ([1-9]|[12]\d|3[01])\.(?!\d)",
                  lambda m: m.group(1) + " " + sr_ordinal(int(m.group(2))), text)
    text = re.sub(r"(\d+)([.,])(\d+)", lambda m: sr_words(int(m.group(1))) + (" tačka " if m.group(2) == "." else " zarez ")
                  + " ".join(SR_ONES[int(d)] for d in m.group(3)), text)
    text = re.sub(r"(?<=[^\W\d_])(?=\d)|(?<=\d)(?=[^\W\d_])", " ", text)
    return re.sub(r"\d+", lambda m: sr_words(int(m.group(0))), text)


def sr_latin(text):
    return "".join(SR_CYRILLIC.get(c, c) for c in text)


# Chinese: digits read as Chinese numerals, and 两 counts as 二.
ZH_DIGITS = "零一二三四五六七八九"


def zh_numeral(n):
    if n < 10:
        return ZH_DIGITS[n]
    if n >= 10_000:
        head, rest = divmod(n, 10_000)
        return zh_numeral(head) + "万" + ("" if rest == 0 else ("零" if rest < 1000 else "") + zh_numeral(rest))
    out, zero = "", False
    for size, unit in ((1000, "千"), (100, "百"), (10, "十"), (1, "")):
        digit = n // size % 10
        if digit:
            out += ("零" if zero and out else "") + ("" if digit == 1 and unit == "十" and not out else ZH_DIGITS[digit]) + unit
            zero = False
        elif out:
            zero = True
    return out


def spell_numbers_zh(text):
    text = re.sub(r"(?<=\d),(?=\d{3})", "", text)
    text = re.sub(r"(\d+)\.(\d+)", lambda m: zh_numeral(int(m.group(1))) + "点" + "".join(ZH_DIGITS[int(d)] for d in m.group(2)), text)
    return re.sub(r"\d+", lambda m: zh_numeral(int(m.group(0))), text).replace("两", "二")


FILLERS = {"um", "uh", "hm", "hmm", "mm", "ah", "er", "äh", "ähm", "öh", "嗯", "呃"}


def normalize(text, lang):
    base = lang.split("-")[0]
    text = unicodedata.normalize("NFKC", text).lower()
    if base == "en":
        text = spell_numbers(text.replace("-", " "))
        text = re.sub(r"\ba hundred\b", "one hundred", text)
        text = re.sub(r"\bokay\b", "ok", text)
    elif base == "de":
        text = spell_numbers_de(text.replace("-", " ")).replace("ß", "ss")
        text = re.sub(r"\b(?:okay|ok)\b", "ok", text)
    elif base == "sr":
        text = spell_numbers_sr(sr_latin(text).replace("-", " "))
        text = re.sub(r"\b(?:okej|okay|ok)\b", "ok", text)
    elif base == "zh":
        text = spell_numbers_zh(text)
    text = re.sub(r"[^\w\s']|_", " ", text).replace("'", "")
    tokens = [t for t in text.split() if t not in FILLERS]
    if base == "en":  # "a hundred and eighty" and "180" should agree
        tokens = [t for i, t in enumerate(tokens)
                  if not (t == "and" and 0 < i < len(tokens) - 1 and tokens[i - 1] == "hundred")]
    elif base == "de":
        tokens = [DE_ORDINAL.sub(r"\1en", re.sub(r"^ein(hundert|tausend)", r"\1", t)) for t in tokens]
    elif base == "sr":
        tokens = [SR_ORDINAL.sub(r"\1i", "dva" if t == "dve" else t) for t in tokens]
    if base in ("zh", "ja"):
        return [c for c in "".join(tokens) if c not in FILLERS]
    return tokens


def edit_distance(ref, hyp):
    row = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        prev, row[0] = row[0], i
        for j, h in enumerate(hyp, 1):
            prev, row[j] = row[j], min(row[j] + 1, row[j - 1] + 1, prev + (r != h))
    return row[-1]


def speaker_accuracy(reference, segments):
    """Share of transcribed speech time whose speaker label maps to the right
    voice, after giving each label the voice it overlaps most."""
    overlap = {}
    for seg in segments:
        for turn in reference:
            shared = min(seg["end"], turn["end"]) - max(seg["start"], turn["start"])
            if shared > 0:
                key = (seg.get("speaker", "?"), turn["speaker"])
                overlap[key] = overlap.get(key, 0) + shared
    total = sum(overlap.values())
    if not total:
        return 0.0, {}
    mapping, used = {}, set()
    for (label, voice), _ in sorted(overlap.items(), key=lambda item: -item[1]):
        if label not in mapping and voice not in used:
            mapping[label] = voice
            used.add(voice)
    matched = sum(t for (label, voice), t in overlap.items() if mapping.get(label) == voice)
    return matched / total, mapping


def check(args):
    reference = load(args.lang, "reference")
    expected = load(args.lang, "expected")
    path = args.transcript
    if os.path.isdir(path):
        path = os.path.join(path, "transcript.json")
    with open(path, encoding="utf-8") as f:
        segments = json.load(f)["segments"]
    hyp_text = " ".join(s["text"] for s in segments)
    ref_text = " ".join(t["text"] for t in reference["turns"])
    ref_tokens, hyp_tokens = normalize(ref_text, args.lang), normalize(hyp_text, args.lang)
    errors = edit_distance(ref_tokens, hyp_tokens)
    unit = "CER" if args.lang in ("zh", "ja") else "WER"
    print(f"{unit}: {errors / len(ref_tokens):.1%} ({errors} edits over {len(ref_tokens)} reference "
          f"{'characters' if unit == 'CER' else 'words'})")

    raw = unicodedata.normalize("NFKC", hyp_text).lower()
    if args.lang.split("-")[0] == "sr":
        raw = sr_latin(raw)
    flat = " " + " ".join(normalize(raw, "raw")) + " "
    found = 0
    print("\nNames, numbers and dates:")
    for entity in expected["entities"]:
        hit = any(v in raw or f" {' '.join(normalize(v, 'raw'))} " in flat for v in entity["any"])
        found += hit
        print(f"  {'✓' if hit else '✗'} {entity['kind']:<6} {entity['label']}")
    print(f"  {found}/{len(expected['entities'])} came through")

    labels = sorted({s.get("speaker", "?") for s in segments})
    accuracy, mapping = speaker_accuracy(reference["turns"], segments)
    print(f"\nSpeakers: {len(labels)} label(s) for {expected['speakers']} voices "
          f"({', '.join(f'{label} → {mapping.get(label, 'none')}' for label in labels)}); "
          f"{accuracy:.0%} of speech time on the right voice")

    print("\nFor a person to check:")
    print(f"  [ ] The notes state the final decision, not the reversed one:\n      {expected['changedDecision']['after']}")
    print(f"  [ ] The notes keep this decision:\n      {expected['decision']['text']}")
    print(f"  [ ] The open question stays open:\n      {expected['openQuestion']['text']}")
    ask = expected["ask"]
    cited = [t for t in reference["turns"] if t["id"] in ask["citesTurns"]]
    when = f"{stamp(cited[0]['start'])}–{stamp(cited[-1]['end'])}" if cited else "?"
    print(f"  [ ] Ask \"{ask['question']}\" answers:")
    for point in ask["answerPoints"]:
        print(f"        - {point}")
    print(f"      and cites the passage at {when}.")
    if args.summary:
        print("\nNotes under review:\n")
        print(open(args.summary, encoding="utf-8").read())


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    b = sub.add_parser("build")
    b.add_argument("--lang", default="en")
    b.add_argument("--cache")
    c = sub.add_parser("check")
    c.add_argument("--lang", default="en")
    c.add_argument("transcript")
    c.add_argument("--summary")
    args = parser.parse_args()
    build(args) if args.command == "build" else check(args)


if __name__ == "__main__":
    main()
