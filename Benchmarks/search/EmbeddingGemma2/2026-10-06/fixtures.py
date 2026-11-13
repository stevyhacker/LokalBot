"""Freeze synthetic relevance labels and screenshots before model inference."""
import ast
import hashlib
import json
from pathlib import Path
import random
import textwrap

from PIL import Image, ImageDraw, ImageFont

ROOT = Path('/private/tmp/lokalbot-embeddinggemma2-20261006')
REPO = Path(__file__).resolve().parents[4]
SIZE = (1000, 700)


def font(size, bold=False):
    name = 'Arial Bold.ttf' if bold else 'Arial.ttf'
    return ImageFont.truetype('/System/Library/Fonts/Supplemental/' + name, size)


def canvas(title):
    image = Image.new('RGB', SIZE, '#f5f7fa')
    draw = ImageDraw.Draw(image)
    draw.rectangle((0, 0, 1000, 55), fill='#202938')
    draw.text((26, 14), 'Work memory | Project Atlas', font=font(22), fill='white')
    draw.text((45, 86), title, font=font(34, True), fill='#182230')
    return image, draw


def arrow(draw, start, end):
    import math
    draw.line((start, end), fill='#2879b8', width=9)
    angle = math.atan2(end[1] - start[1], end[0] - start[0])
    points = [end] + [(end[0] - 22 * math.cos(angle + d),
                      end[1] - 22 * math.sin(angle + d)) for d in (-0.5, 0.5)]
    draw.polygon(points, fill='#2879b8')


def main():
    ROOT.mkdir(parents=True, exist_ok=True)
    images = ROOT / 'fixtures' / 'images'
    images.mkdir(parents=True, exist_ok=True)
    source = REPO / 'Benchmarks/think/ModelAlternatives/2026-09-07/fixtures.py'
    tree = ast.parse(source.read_text())
    rows = next(ast.literal_eval(node.value) for node in tree.body
                if isinstance(node, ast.Assign)
                and any(isinstance(target, ast.Name) and target.id == 'RETRIEVAL_ROWS'
                        for target in node.targets))
    documents = [{'id': row[0], 'text': row[1]} for row in rows]
    queries = []
    for key, _, english, bcs in rows:
        for language, query in [('en', english), ('bcs', bcs)]:
            queries.append({'id': key + '-' + language, 'query': query,
                            'relevant': [key], 'language': language, 'group': key})
    for index in range(36):
        documents.append({'id': f'distractor-{index}', 'text':
            f'Archived weekly operations note {index+1}. The team reviewed customer onboarding, release schedules, '
            'testing, documentation and account configuration. No specific software failure was diagnosed. '
            'The next discussion covers staffing availability, presentation slides and office supplies. '
            'No transaction, contract change or production release was approved during this administrative update.'})
    random.Random(61006).shuffle(documents)
    text = {'documents': documents, 'queries': queries,
            'provenance': '24 unchanged authored passages and 48 queries from the September pilot, '
                          'plus its 36 synthetic distractors. Private distractors excluded.'}
    (ROOT / 'fixtures' / 'text.json').write_text(json.dumps(text, indent=2, ensure_ascii=False) + '\n')

    screens, screen_queries = [], []

    def add(key, category, image, english, bcs):
        target = images / (key + '.png')
        image.save(target)
        screens.append({'id': key, 'category': category, 'image': str(target)})
        for language, query in [('en', english), ('bcs', bcs)]:
            screen_queries.append({'id': key + '-' + language, 'query': query,
                                   'relevant': [key], 'language': language,
                                   'category': category, 'group': key})

    charts = [
        ('rising', [15, 35, 60, 85], 'Find the revenue chart with steady growth every month.',
         'Pronađi grafikon prihoda koji stalno raste svakog mjeseca.'),
        ('falling', [85, 60, 35, 15], 'Find the revenue chart that declines continuously.',
         'Pronađi grafikon prihoda koji neprekidno opada.'),
        ('flat', [50, 50, 50, 50], 'Find the chart where monthly revenue stays flat.',
         'Pronađi grafikon na kojem mjesečni prihod ostaje isti.'),
        ('spike', [20, 25, 90, 25], 'Find the revenue chart with a sharp peak in March.',
         'Pronađi grafikon prihoda sa naglim vrhuncem u martu.'),
        ('dip', [80, 75, 15, 80], 'Find the revenue chart with a sharp dip in March followed by recovery.',
         'Pronađi grafikon prihoda sa naglim padom u martu i oporavkom poslije toga.'),
        ('rebound', [85, 35, 35, 85], 'Find the U-shaped revenue chart: high, low, low, high.',
         'Pronađi grafikon prihoda u obliku slova U: visoko, nisko, nisko, visoko.'),
    ]
    for key, values, en, bcs in charts:
        image, draw = canvas('Monthly revenue')
        for value in [0, 25, 50, 75, 100]:
            y = 600 - value * 4
            draw.line((120, y, 920, y), fill='#d5dbe4', width=2)
            draw.text((55, y - 12), str(value), font=font(20), fill='#566274')
        draw.line((120, 190, 120, 600), fill='#566274', width=3)
        points = [(160 + i * 240, 600 - value * 4) for i, value in enumerate(values)]
        draw.line(points, fill='#146db3', width=10)
        for i, point in enumerate(points):
            draw.ellipse((point[0] - 9, point[1] - 9, point[0] + 9, point[1] + 9), fill='#146db3')
            draw.text((point[0] - 20, 625), ['Jan', 'Feb', 'Mar', 'Apr'][i], font=font(22), fill='#344054')
        add('chart-' + key, 'visual_chart', image, en, bcs)

    nodes = {'Client': (180, 350), 'API': (490, 230), 'Cache': (820, 350), 'Database': (490, 540)}
    graphs = [
        ('chain', [('Client', 'API'), ('API', 'Cache'), ('Cache', 'Database')],
         'Find the service diagram that routes Client to API to Cache to Database in a chain.',
         'Pronađi dijagram servisa sa lancem Klijent, API, Keš, Baza podataka.'),
        ('star', [('Client', 'API'), ('API', 'Cache'), ('API', 'Database')],
         'Find the service diagram where API connects separately to both Cache and Database.',
         'Pronađi dijagram gdje API ima odvojene veze prema kešu i bazi podataka.'),
        ('cycle', [('Client', 'API'), ('API', 'Cache'), ('Cache', 'Database'), ('Database', 'Client')],
         'Find the service diagram with a closed loop through all four components.',
         'Pronađi dijagram servisa sa zatvorenom petljom kroz sve četiri komponente.'),
        ('isolated', [('Client', 'API'), ('API', 'Database')],
         'Find the service diagram where Cache is disconnected from every other component.',
         'Pronađi dijagram servisa gdje je keš nepovezan sa svim ostalim komponentama.'),
    ]
    for key, edges, en, bcs in graphs:
        image, draw = canvas('Service architecture')
        for a, b in edges:
            start, end = nodes[a], nodes[b]
            delta = (end[0] - start[0], end[1] - start[1])
            arrow(draw, (start[0] + delta[0] * .23, start[1] + delta[1] * .23),
                  (end[0] - delta[0] * .23, end[1] - delta[1] * .23))
        for name, (x, y) in nodes.items():
            draw.rounded_rectangle((x - 85, y - 35, x + 85, y + 35), radius=12,
                                   fill='white', outline='#667085', width=3)
            draw.text((x, y), name, anchor='mm', font=font(24), fill='#182230')
        add('diagram-' + key, 'visual_diagram', image, en, bcs)

    boards = [
        ('pending', [2, 1, 0], 'Find the task board where Build is done and Release has not started.',
         'Pronađi tablu gdje je Build završen, a Release još nije počeo.'),
        ('active', [2, 0, 1], 'Find the task board where Release is in progress and Docs is still waiting.',
         'Pronađi tablu gdje je Release u toku, a Docs još čeka.'),
        ('released', [0, 1, 2], 'Find the task board where Release is complete but Build has not started.',
         'Pronađi tablu gdje je Release završen, ali Build još nije počeo.'),
        ('complete', [2, 2, 2], 'Find the task board where Build, Docs, and Release are all complete.',
         'Pronađi tablu gdje su Build, Docs i Release svi završeni.'),
    ]
    for key, positions, en, bcs in boards:
        image, draw = canvas('Release tasks')
        for column, title in enumerate(['To do', 'In progress', 'Done']):
            x = 40 + column * 320
            draw.rounded_rectangle((x, 175, x + 285, 640), radius=15, fill='#e6ebf2')
            draw.text((x + 18, 195), title, font=font(26, True), fill='#182230')
        counts = [0, 0, 0]
        for name, column in zip(['Build', 'Docs', 'Release'], positions):
            x, y = 55 + column * 320, 260 + counts[column] * 105
            counts[column] += 1
            draw.rounded_rectangle((x, y, x + 255, y + 80), radius=9, fill='white')
            draw.text((x + 20, y + 23), name, font=font(28), fill='#182230')
        add('board-' + key, 'text_layout', image, en, bcs)

    for key, content, en, bcs in rows[:6]:
        image, draw = canvas('Project notes')
        for index, line in enumerate(textwrap.wrap(content, width=57)):
            draw.text((45, 170 + index * 48), line, font=font(27), fill='#182230')
        add('notes-' + key, 'readable_text', image, en, bcs)

    dense = [
        ('01', 'Find the code editor defining a latency budget of 750 milliseconds.',
         'Pronađi uređivač koda koji definiše budžet kašnjenja od 750 milisekundi.'),
        ('02', 'Find the OCR dashboard comparing model latency and token F1.',
         'Pronađi OCR kontrolnu tablu koja poredi kašnjenje modela i token F1.'),
        ('03', 'Find the terminal running the OCR benchmark and printing screenshot results.',
         'Pronađi terminal koji izvršava OCR test i ispisuje rezultate snimaka ekrana.'),
        ('04', 'Find the meeting notes about an OCR comparison and its follow-up actions.',
         'Pronađi bilješke sa sastanka o OCR poređenju i narednim zadacima.'),
        ('05', 'Find the OCR settings showing Apple Vision, language correction off, and a 750 ms latency guardrail.',
         'Pronađi OCR podešavanja sa Apple Vision modelom, isključenom korekcijom jezika i granicom kašnjenja 750 ms.'),
    ]
    for number, en, bcs in dense:
        original = REPO / f'Benchmarks/search/OCR/synthetic/synth-{number}.png'
        image = Image.open(original).convert('RGB')
        add('dense-' + number, 'dense_ui', image, en, bcs)
    random.Random(61007).shuffle(screens)
    screen = {'documents': screens, 'queries': screen_queries,
              'provenance': '20 newly rendered synthetic screens, plus five existing synthetic OCR fixtures. '
                            'Visual pairs deliberately share words; report each category separately.'}
    (ROOT / 'fixtures' / 'screens.json').write_text(json.dumps(screen, indent=2, ensure_ascii=False) + '\n')
    for fixture in [text, screen]:
        ids = {doc['id'] for doc in fixture['documents']}
        assert len(ids) == len(fixture['documents'])
        assert all(set(query['relevant']) <= ids for query in fixture['queries'])
    hashes = {str(path.relative_to(ROOT / 'fixtures')): hashlib.sha256(path.read_bytes()).hexdigest()
              for path in sorted((ROOT / 'fixtures').rglob('*')) if path.is_file()}
    (ROOT / 'fixture-freeze.json').write_text(json.dumps(hashes, indent=2) + '\n')
    print(f'Frozen text: {len(documents)} documents / {len(queries)} queries; '
          f'screens: {len(screens)} images / {len(screen_queries)} queries')


if __name__ == '__main__':
    main()
