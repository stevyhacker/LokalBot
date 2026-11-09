"""Do DigUp's reference inputs make DigUp's reference vectors through the app's llama-server?

Three servers run one after another on a private port:
  text     the app's embedder as it ships: text model only
  sized    the same plus the projector, with DigUp's media settings: each image is resized for its token budget
           before it is sent, and the server never rescales it
  default  the same plus the projector, with llama.cpp's own image sizing (what the 7 and 13 October runs used)

Every vector is compared with reference/vectors.json (DigUp at dc2651a: llama.cpp b11461, vectors version 1). A cosine
of 0.999 passes, DigUp's own bar for runtimes that agree.

usage: python3 parity.py   (LLAMA_SERVER, TEXT_MODEL and MMPROJ override the paths in common.py)
"""
import base64
import json
import platform
import subprocess
import sys

from PIL import Image

from common import (HERE, MMPROJ, SERVER, SIZED_MEDIA_ARGS, QUERY_PREFIX, Server, audio_part, cosine, document,
                    image_part, sized_png)

REFERENCE = HERE / 'reference'
AGREEMENT = 0.999

# ReferenceVectorTests.swift, word for word.
TEXTS = [
    ('query', QUERY_PREFIX + 'payment declined error'),
    ('query-bn', QUERY_PREFIX + 'ইলিশ মাছ রান্না'),
    ('query-ar', QUERY_PREFIX + 'متى تغلق المكتبة'),
    ('document', document('Tokyo itinerary', 'Flight to Tokyo Haneda on November 3. Then the train to Kamakura to '
                          'see the Great Buddha, and back for dinner in Shibuya.')),
    ('document-long', document(None, ' '.join(
        f'Note {n}: the review moved to room {n % 7 + 2} because the projector in the main hall failed again, '
        'and the team agreed to send the slides the night before.' for n in range(1, 61)))),
]
IMAGES = [('screen-280', 'screen.png', 280), ('photo-140', 'photo.jpg', 140), ('frame-70', 'photo.jpg', 70)]


def text_vectors(server):
    """The app's shape (one request for a batch) and one request per input; both must agree."""
    batched, payload, _ = server.embed([text for _, text in TEXTS])
    single = [server.embed([text])[0][0] for _, text in TEXTS]
    agreement = min(cosine(a, b) for a, b in zip(batched, single))
    return dict(zip([name for name, _ in TEXTS], batched)), agreement, payload.get('usage')


def sized_images(server):
    out = {}
    for name, file, budget in IMAGES:
        vectors, payload, seconds = server.embed([image_part(sized_png(Image.open(REFERENCE / file), budget))])
        out[name] = (vectors[0], payload.get('usage', {}).get('prompt_tokens'), seconds)
    return out


def default_images(server):
    """The original files, sized by llama.cpp. One vector per file: the server has no budget to vary."""
    out = {}
    for name, file, _ in IMAGES:
        if name == 'frame-70':
            continue
        mime = 'image/png' if file.endswith('.png') else 'image/jpeg'
        vectors, payload, seconds = server.embed([image_part((REFERENCE / file).read_bytes(), mime)])
        out[name] = (vectors[0], payload.get('usage', {}).get('prompt_tokens'), seconds)
    return out


def audio_formats(server):
    """Which request shapes embed a WAV. Returns [(shape, status, vector or None, tokens, detail)]."""
    wav = (REFERENCE / 'speech.wav').read_bytes()
    encoded = base64.b64encode(wav).decode()
    shapes = [
        ('OpenAI input_audio part, /v1/embeddings', '/v1/embeddings',
         {'input': [audio_part(wav)], 'cache_prompt': False}),
        ('multimodal_data prompt, /v1/embeddings', '/v1/embeddings',
         {'input': [{'prompt_string': '<__media__>', 'multimodal_data': [encoded]}], 'cache_prompt': False}),
        ('multimodal_data prompt, /embeddings', '/embeddings',
         {'content': [{'prompt_string': '<__media__>', 'multimodal_data': [encoded]}], 'cache_prompt': False}),
    ]
    results = []
    for shape, path, body in shapes:
        response, _ = server.post(path, body)
        if response.status_code != 200:
            results.append((shape, response.status_code, None, None, response.text[:200]))
            continue
        payload = response.json()
        rows = payload['data'] if isinstance(payload, dict) else payload
        row = rows[0]
        vector = row['embedding']
        if vector and isinstance(vector[0], list):   # the native endpoint returns one row per token without pooling
            vector = vector[0]
        tokens = payload.get('usage', {}).get('prompt_tokens') if isinstance(payload, dict) else None
        results.append((shape, 200, vector, tokens, ''))
    return results


def main():
    reference = json.loads((REFERENCE / 'vectors.json').read_text())
    expected = reference['vectors']
    report = {
        'reference': {'vector_version': reference['vector_version'], 'made_with': reference['made_with']},
        'server': subprocess.run([str(SERVER), '--version'], capture_output=True, text=True).stderr.strip()
        .splitlines()[0],
        'machine': f"{platform.machine()} macOS {platform.mac_ver()[0]}",
        'agreement': AGREEMENT,
    }

    with Server() as server:
        text, batch_vs_single, usage = text_vectors(server)
    report['text'] = {'cosine': {name: cosine(vector, expected[name]) for name, vector in text.items()},
                      'batched_vs_single_min_cosine': batch_vs_single, 'usage': usage}

    with Server(['--mmproj', str(MMPROJ), *SIZED_MEDIA_ARGS]) as server:
        media_text, _, _ = text_vectors(server)
        images = sized_images(server)
        audio = audio_formats(server)
    report['sized'] = {
        'text_same_as_text_server_min_cosine': min(cosine(media_text[n], text[n]) for n in text),
        'text_cosine': {name: cosine(vector, expected[name]) for name, vector in media_text.items()},
        'images': {name: {'cosine': cosine(vector, expected[name]), 'prompt_tokens': tokens, 'seconds': seconds}
                   for name, (vector, tokens, seconds) in images.items()},
        'audio': [{'shape': shape, 'status': status, 'prompt_tokens': tokens, 'detail': detail,
                   'cosine': cosine(vector, expected['speech']) if vector is not None else None}
                  for shape, status, vector, tokens, detail in audio],
    }

    with Server(['--mmproj', str(MMPROJ)]) as server:
        images = default_images(server)
    report['default'] = {'images': {name: {'cosine': cosine(vector, expected[name]), 'prompt_tokens': tokens,
                                           'seconds': seconds}
                                    for name, (vector, tokens, seconds) in images.items()}}

    checks = list(report['text']['cosine'].values()) + list(report['sized']['text_cosine'].values()) \
        + [row['cosine'] for row in report['sized']['images'].values()]
    audio_cosines = [row['cosine'] for row in report['sized']['audio'] if row['cosine'] is not None]
    report['audio_supported'] = bool(audio_cosines)
    report['pass'] = min(checks) >= AGREEMENT and (not audio_cosines or max(audio_cosines) >= AGREEMENT)

    out = HERE / 'results/parity.json'
    out.parent.mkdir(exist_ok=True)
    out.write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n')

    print(f"{report['server']} · reference {reference['made_with']} v{reference['vector_version']}")
    for name, value in report['text']['cosine'].items():
        print(f'  text    {name:14} {value:.6f}')
    print(f"  text batched vs single, min cosine {batch_vs_single:.6f}")
    print(f"  sized server: text same as text-only server, min cosine "
          f"{report['sized']['text_same_as_text_server_min_cosine']:.6f}")
    for name, row in report['sized']['images'].items():
        print(f"  sized   {name:14} {row['cosine']:.6f}  {row['prompt_tokens']} tokens  {row['seconds'] * 1000:.0f} ms")
    for row in report['sized']['audio']:
        value = f"{row['cosine']:.6f}" if row['cosine'] is not None else '—'
        print(f"  audio   {row['shape']:44} HTTP {row['status']}  {value}  {row['prompt_tokens']} tokens "
              f"{row['detail'][:90]}")
    for name, row in report['default']['images'].items():
        print(f"  default {name:14} {row['cosine']:.6f}  {row['prompt_tokens']} tokens")
    print('PASS' if report['pass'] else 'FAIL')
    return 0 if report['pass'] else 1


if __name__ == '__main__':
    sys.exit(main())
