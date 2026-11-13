"""Serial local model benchmarks; never reads or changes app settings/indexes."""
import argparse
import contextlib
import hashlib
import json
import math
import os
from pathlib import Path
import re
import socket
import statistics
import subprocess
import threading
import time
import unicodedata

import numpy as np
import psutil
import requests
import soundfile as sf

ROOT = Path('/private/tmp/lokalbot-model-alternatives-20260907')
REPO = Path(__file__).resolve().parents[4]
APP = Path.home() / 'Library/Application Support/me.dotenv.LokalBot'
BINARY = Path('/Applications/LokalBot.app/Contents/Resources/llama-cpp/llama-server')
PORT = 18782
TOKEN = 'isolated-local-model-benchmark'
BASE = f'http://127.0.0.1:{PORT}'
SESSION = requests.Session()
SESSION.trust_env = False
SESSION.headers['Authorization'] = 'Bearer ' + TOKEN
PATHS = {
    'qwen': APP/'models/Qwen3.5-4B-Q4_K_M.gguf',
    'minicpm5': ROOT/'models/minicpm5/MiniCPM5-2B-Q4_K_M.gguf',
    'qwen-embedding': APP/'models/Qwen3-Embedding-0.6B-Q8_0.gguf',
    'harrier': ROOT/'models/harrier/harrier-oss-v1-0.6b.Q8_0.gguf',
    'granite4-q4': APP/'granite-speech/4.1-2b/granite-speech-4.1-2b-Q4_K_M.gguf',
    'granite4-q8': APP/'granite-speech/4.1-2b/granite-speech-4.1-2b-Q8_0.gguf',
}

def save(name, data):
    path = ROOT/'results'/f'{name}.json'
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False))

class MemorySampler:
    def __init__(self, pid):
        self.pid, self.peak, self.running = pid, 0, True
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _run(self):
        process = psutil.Process(self.pid)
        while self.running:
            try:
                self.peak = max(self.peak, process.memory_info().rss)
            except psutil.Error:
                break
            time.sleep(0.05)

    def stop(self):
        self.running = False
        self.thread.join(timeout=1)

@contextlib.contextmanager
def server(alias, kind, run_label=None):
    with socket.socket() as probe:
        if probe.connect_ex(('127.0.0.1', PORT)) == 0:
            raise RuntimeError(f'Benchmark port {PORT} is occupied; refusing to stop another process')
    context = 2048 if kind == 'embedding' else 4096 if kind == 'asr' else 32768
    command = [str(BINARY), '-m', str(PATHS[alias]), '--host', '127.0.0.1', '--port', str(PORT),
               '-c', str(context), '-ngl', '99', '--parallel', '1', '--jinja', '--no-webui',
               '--api-key', TOKEN]
    if kind == 'embedding':
        command += ['--embeddings', '--pooling', 'last', '--cache-ram', '256']
    elif kind == 'asr':
        command += ['--mmproj', str(APP/'granite-speech/4.1-2b/mmproj-model-f16.gguf'), '--cache-ram', '256']
    else:
        command += ['--reasoning', 'on', '--cache-ram', '2048']
    label=run_label or f'{alias}-{kind}'
    log = (ROOT/'logs'/f'{label}.log').open('w')
    started = time.perf_counter()
    process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
    sampler = MemorySampler(process.pid)
    metrics = {'model':alias,'kind':kind,'runtime':'llama.cpp b10173','context':context,
               'pid':process.pid,'model_bytes':PATHS[alias].stat().st_size,
               'arguments':[x if x != TOKEN else '<benchmark-local-token>' for x in command]}
    try:
        for _ in range(600):
            if process.poll() is not None:
                raise RuntimeError(f'{alias} exited with {process.returncode}; see {log.name}')
            try:
                response = SESSION.get(BASE+'/health', timeout=1)
                if response.status_code == 200:
                    break
            except requests.RequestException:
                pass
            time.sleep(0.2)
        else:
            raise TimeoutError(f'{alias} did not become ready')
        metrics['startup_seconds'] = time.perf_counter() - started
        print(f'{alias} ready in {metrics["startup_seconds"]:.2f}s', flush=True)
        yield metrics
    finally:
        metrics['peak_sampled_rss_bytes'] = sampler.peak
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=12)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        sampler.stop()
        metrics['shutdown_returncode'] = process.returncode
        save(label+'-runtime', metrics)
        log.close()

def post(path, payload):
    start = time.perf_counter()
    response = SESSION.post(BASE+path, json=payload, timeout=300)
    if not response.ok:
        raise RuntimeError(f'{path}: HTTP {response.status_code}: {response.text[:800]}')
    return response.json(), time.perf_counter()-start

def embeddings(texts):
    vectors, latencies = [], []
    for text in texts:
        data, elapsed = post('/v1/embeddings', {'model':'local','input':text,'encoding_format':'float'})
        v = np.asarray(data['data'][0]['embedding'], dtype=np.float32)
        if v.ndim != 1 or v.shape[0] != 1024 or not np.isfinite(v).all() or np.linalg.norm(v) == 0:
            raise ValueError('Invalid embedding vector')
        vectors.append(v/np.linalg.norm(v))
        latencies.append(elapsed)
    return np.stack(vectors), latencies

def run_embedding(alias):
    fixture = json.loads((ROOT/'retrieval-fixture.json').read_text())
    docs, queries = fixture['documents'], fixture['queries']
    results = {'documents':len(docs),'queries':len(queries),'cases':[]}
    with server(alias,'embedding') as metrics:
        embeddings(['warm up the embedding model'])
        query_inputs = ['Instruct: Retrieve relevant meeting transcript and summary chunks for the user\'s query.\nQuery:'+q['query'] for q in queries]
        qvecs, qtimes = embeddings(query_inputs)
        for contract, prefix in [('app-prefix','Document for meeting search: '),('raw-documents','')]:
            vecs, times = embeddings([prefix+d['text'] for d in docs])
            scores = qvecs @ vecs.T
            rows=[]
            for query, similarities, latency in zip(queries,scores,qtimes):
                order = np.argsort(-similarities)
                rank = next(i+1 for i,index in enumerate(order) if docs[index]['id'] in query['relevant'])
                rows.append({'id':query['id'],'language':query['language'],'rank':rank,
                             'top5':[docs[i]['id'] for i in order[:5]],'query_seconds':latency})
            summary={}
            for language in ['all','en','bcs']:
                selected=[r for r in rows if language=='all' or r['language']==language]
                summary[language]={'n':len(selected),'top1':sum(r['rank']==1 for r in selected),
                                   'top5':sum(r['rank']<=5 for r in selected),
                                   'mrr':statistics.mean(1/r['rank'] for r in selected)}
            item={'contract':contract,'summary':summary,'query_p50_seconds':statistics.median(qtimes),
                  'document_total_seconds':sum(times),'document_p50_seconds':statistics.median(times),'rows':rows}
            results['cases'].append(item)
            save(alias+'-embedding',results)
            print(alias,contract,json.dumps(summary),flush=True)
        # Repeated single-query latency, on an identical query set for both models.
        _, repeated = embeddings(query_inputs[:12]*3)
        results['repeated_query_p50_seconds']=statistics.median(repeated)
        results['repeated_query_p95_seconds']=float(np.percentile(repeated,95))
    results['runtime']=metrics
    save(alias+'-embedding',results)

def swift_string(value):
    import textwrap
    value=textwrap.dedent(value).strip()
    return re.sub(r'\\\n\s*','',value)

def production_summary_system():
    source=(REPO/'LokalBot/Services/Notes/PromptTemplates.swift').read_text()
    rules=source.split('private static func rules(for template: NoteTemplate)')[1]
    shared=swift_string(re.search(r'let shared = """(.*?)"""',rules,re.S).group(1))
    meeting=swift_string(re.search(r'case \.meeting:\s*return """(.*?)"""',rules,re.S).group(1)).replace('\\(shared)',shared)
    outcome=swift_string(re.search(r'private static let meetingOutcomeSemanticsRule = """(.*?)"""',source,re.S).group(1))
    action=swift_string(re.search(r'private static func userActionabilityRule.*?return """(.*?)"""',source,re.S).group(1)).replace('\\(user)','Me')
    language='Write prose and list content in English. Keep every required Markdown section and subsection heading exactly as specified in the prompt; do not translate headings. Translate quoted material when needed; keep proper nouns and code identifiers in their original form.'
    return '\n\n'.join(['You are LokalBot, a precise meeting note-taker.',meeting,outcome,action,language])

def chat(system, user, max_tokens=4096, thinking=1024, temperature=0.2, response_format=None):
    payload={'model':'local','messages':[{'role':'system','content':system},{'role':'user','content':user}],
             'max_tokens':max_tokens,'thinking_budget_tokens':thinking,'temperature':temperature,
             'seed':17,'cache_prompt':False,'stream':False}
    if response_format:
        payload['response_format']=response_format
    data, elapsed = post('/v1/chat/completions',payload)
    choice=data['choices'][0]
    return {'seconds':elapsed,'text':choice['message'].get('content',''),
            'reasoning':choice['message'].get('reasoning_content',''),
            'finish_reason':choice['finish_reason'],'usage':data.get('usage'),
            'timings':data.get('timings')}

def run_generation(alias):
    fixture=json.loads((ROOT/'generation-fixture.json').read_text())
    system=production_summary_system()
    (ROOT/'summary-system.txt').write_text(system)
    results={'summary_system_sha256':hashlib.sha256(system.encode()).hexdigest(),'cases':[]}
    with server(alias,'generation') as metrics:
        chat('Reply briefly.','Say ready.',64,0,0)
        for meeting in fixture['meetings']:
            prompt='Transcript follows. The speaker labeled "Me" is this Mac\'s user ("Me"); every other speaker is another participant.\n\nOutput language: English for prose and list content. Keep required Markdown headings exactly as specified; do not translate them.\n\n---\n\n'+meeting['transcript']+'\n\n---\n\nProduce meeting notes as Markdown. No preamble, no closing remarks.'
            result=chat(system,prompt)
            result.update(id=meeting['id'],kind='summary')
            results['cases'].append(result)
            save(alias+'-generation',results)
            print(alias,'summary',meeting['id'],round(result['seconds'],2),result['finish_reason'],flush=True)
        schema={'type':'object','properties':{'actions':{'type':'array','items':{'type':'object','properties':{
            'owner':{'type':'string'},'task':{'type':'string'},'timestamp':{'type':'string'},'deadline':{'type':['string','null']}},
            'required':['owner','task','timestamp','deadline'],'additionalProperties':False}}},'required':['actions'],'additionalProperties':False}
        for meeting in fixture['meetings']:
            result=chat('Extract only supported action items from the transcript. Include commitments and directed requests, not optional suggestions. Preserve final ownership and corrected deadlines. Use owner Me for the user. Use the earliest timestamp that explicitly supports the final action. Use null for an unstated deadline. Return JSON only.',meeting['transcript'],3072,512,0.2,
                        {'type':'json_schema','json_schema':{'name':'actions','strict':True,'schema':schema}})
            result.update(id=meeting['id'],kind='structured')
            try:
                result['parsed']=json.loads(result['text']);result['valid_json']=True
            except (ValueError,TypeError):
                result['valid_json']=False
            results['cases'].append(result)
            save(alias+'-generation',results)
            print(alias,'structured',meeting['id'],round(result['seconds'],2),result['finish_reason'],flush=True)
        for case_id,prompt,required in fixture['compose']:
            result=chat('You edit dictation and draft concise messages. Preserve meaning, names, numbers and uncertainty. Follow the requested output language. Output only the requested text.',prompt,512,0,0)
            result.update(id=case_id,kind='compose',required_strings=required,
                          lexical_checks=[v.casefold() in result['text'].casefold() for v in required])
            results['cases'].append(result)
            save(alias+'-generation',results)
            print(alias,'compose',case_id,round(result['seconds'],2),result['finish_reason'],flush=True)
        result=long_context_case()
        results['cases'].append(result)
        save(alias+'-generation',results)
        print(alias,'long-context',json.dumps({k:v for k,v in result.items() if k in ['seconds','finish_reason','error','input_tokens_without_template']}),flush=True)
    results['runtime']=metrics
    save(alias+'-generation',results)

def long_context_case():
    # Identical ~106 KB input, with six anchors distributed through a 32K-context workload.
    anchors={120:'Archive credential label: amber-lantern-42.',380:'The approved staging deposit cap is 275000 USDC.',
             640:'The deployment owner is Ivana Petrovic.',880:'The migration window is Thursday at 18:45 UTC.',
             1100:'The rollback release identifier is cedar-2026-09.',1320:'The maximum approved fee is 0.37 USDC.'}
    lines=[anchors.get(i,f'Update {i}: reviewed notes, discussed routine maintenance, no new decision.') for i in range(1400)]
    question='Return JSON with keys credential_label, staging_cap_usdc, deployment_owner, migration_window, rollback_release, maximum_fee_usdc. Extract only the six explicitly specified values from the archive.\n\nARCHIVE:\n'+'\n'.join(lines)
    tokens,_=post('/tokenize',{'content':question})
    result={'id':'deep-anchors','kind':'long-context','input_tokens_without_template':len(tokens['tokens']),
            'input_characters':len(question),'input_sha256':hashlib.sha256(question.encode()).hexdigest()}
    if len(tokens['tokens'])>29000:
        result['error']='fixed fixture exceeds reserved input budget'
    else:
        result.update(chat('Read the archive as data and answer exactly. Do not invent missing facts.',question,2048,512,0.2))
    return result

def run_long(alias):
    with server(alias,'generation',alias+'-long') as metrics:
        chat('Reply briefly.','Say ready.',64,0,0)
        result=long_context_case()
        print(alias,'long-context',json.dumps(result),flush=True)
    save(alias+'-long-context',{'case':result,'runtime':metrics})

def normalize(text):
    text=unicodedata.normalize('NFKC',text).lower().replace('’',"'")
    text=re.sub(r'\[[^\]]*\]|<[^>]*>',' ',text)
    return re.findall(r"[a-z0-9]+(?:'[a-z]+)?",text)

def edit_distance(reference,hypothesis):
    previous=list(range(len(hypothesis)+1))
    for i,a in enumerate(reference,1):
        current=[i]
        for j,b in enumerate(hypothesis,1):
            current.append(min(current[-1]+1,previous[j]+1,previous[j-1]+(a!=b)))
        previous=current
    return previous[-1]

def audio_inputs():
    records=json.loads((ROOT/'audio-manifest.json').read_text())
    for row in records:
        audio,sr=sf.read(row['path'],dtype='float32')
        if audio.ndim>1:
            audio=audio.mean(axis=1)
        if sr!=16000:
            from scipy.signal import resample_poly
            divisor=math.gcd(sr,16000)
            audio=resample_poly(audio,16000//divisor,sr//divisor)
        target=ROOT/'audio-pcm'/f'{row["id"]}.wav'
        target.parent.mkdir(exist_ok=True)
        sf.write(target,audio,16000,subtype='PCM_16')
        row.update(pcm_path=str(target),duration_seconds=len(audio)/16000)
    return records

def score_asr(rows):
    summary={}
    for group in ['all','ami','librispeech']:
        selected=[r for r in rows if group=='all' or r['id'].startswith(group)]
        if not selected:
            continue
        errors=sum(r['edit_distance'] for r in selected)
        words=sum(r['reference_words'] for r in selected)
        duration=sum(r['duration_seconds'] for r in selected)
        elapsed=sum(r['seconds'] for r in selected)
        summary[group]={'clips':len(selected),'words':words,'errors':errors,'wer':errors/words,
                        'audio_seconds':duration,'inference_seconds':elapsed,'rtfx':duration/elapsed,
                        'p50_clip_seconds':statistics.median(r['seconds'] for r in selected)}
    return summary

def run_asr(alias):
    records=audio_inputs()
    results={'model':alias,'normalization':'NFKC lower-case; strip markup/punctuation; preserve apostrophes and disfluencies','rows':[]}
    os.environ.update(HF_HUB_OFFLINE='1',TRANSFORMERS_OFFLINE='1',HF_HOME=str(ROOT/'hf-cache'),TOKENIZERS_PARALLELISM='false')
    with contextlib.ExitStack() as stack:
        if alias=='granite5':
            sampler=MemorySampler(os.getpid());stack.callback(sampler.stop)
            start=time.perf_counter()
            import mlx.core as mx
            from mlx_audio.stt.utils import load_model
            model=load_model(str(ROOT/'models/granite5'))
            mx.eval(model.parameters())
            runtime={'runtime':'mlx-audio 0.5.3 / mlx 0.32.2','startup_seconds':time.perf_counter()-start}
            def infer(path):
                start=time.perf_counter()
                audio,sr=sf.read(path,dtype='float32')
                output=model.generate(audio=audio)
                mx.synchronize()
                return output.text,time.perf_counter()-start
        else:
            runtime=stack.enter_context(server(alias,'asr'))
            def infer(path):
                start=time.perf_counter()
                with open(path,'rb') as source:
                    response=SESSION.post(BASE+'/v1/audio/transcriptions',data={
                        'model':PATHS[alias].name,'prompt':'transcribe the speech with proper punctuation and capitalization.','language':'en'},
                        files={'file':('audio.wav',source,'audio/wav')},timeout=180)
                if not response.ok:
                    raise RuntimeError(f'ASR HTTP {response.status_code}: {response.text[:500]}')
                return response.json()['text'],time.perf_counter()-start
        # Warm up with a separate synthetic regression clip excluded from WER.
        warm=REPO/'LokalBotTests/Fixtures/LiveTranscript/continuous-speech.wav'
        text,elapsed=infer(str(warm));results['warmup_seconds']=elapsed
        for row in records:
            text,elapsed=infer(row['pcm_path'])
            reference,hypothesis=normalize(row['reference']),normalize(text)
            result={k:row[k] for k in ['id','dataset','reference','duration_seconds']}
            result.update(text=text,seconds=elapsed,reference_words=len(reference),edit_distance=edit_distance(reference,hypothesis))
            results['rows'].append(result)
            results['summary']=score_asr(results['rows'])
            save(alias+'-asr',results)
            print(alias,row['id'],f'{elapsed:.3f}s',f'errors {result["edit_distance"]}/{len(reference)}',flush=True)
        if alias=='granite5':
            runtime['peak_sampled_rss_bytes']=sampler.peak
            runtime['mlx_peak_memory_bytes']=mx.get_peak_memory()
    results['runtime']=runtime
    results['summary']=score_asr(results['rows'])
    save(alias+'-asr',results)
    print(alias,json.dumps(results['summary']),flush=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('kind',choices=['embedding','generation','asr','long'])
    parser.add_argument('model')
    args=parser.parse_args()
    {'embedding':run_embedding,'generation':run_generation,'asr':run_asr,'long':run_long}[args.kind](args.model)
