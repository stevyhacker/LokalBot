"""Bounded follow-ups for observed template/budget and vendor-sampling issues."""
import argparse
import json
from pathlib import Path
import run as bench

def request(system,user,max_tokens,thinking,temperature,extra=None):
    payload={'model':'local','messages':[{'role':'system','content':system},{'role':'user','content':user}],
             'max_tokens':max_tokens,'thinking_budget_tokens':thinking,'temperature':temperature,
             'seed':17,'cache_prompt':False,'stream':False}
    if extra:
        payload.update(extra)
    data,elapsed=bench.post('/v1/chat/completions',payload)
    choice=data['choices'][0]
    return {'seconds':elapsed,'text':choice['message'].get('content',''),
            'reasoning':choice['message'].get('reasoning_content',''),'finish_reason':choice['finish_reason'],
            'usage':data.get('usage'),'timings':data.get('timings'),'request_overrides':extra or {}}

def followup(alias):
    fixture=json.loads((bench.ROOT/'generation-fixture.json').read_text())
    results={'model':alias,'cases':[]}
    with bench.server(alias,'generation',alias+'-followups') as metrics:
        bench.chat('Reply briefly.','Say ready.',64,0,0)
        if alias=='qwen':
            for case_id,prompt,required in fixture['compose']:
                result=request('You edit dictation and draft concise messages. Preserve meaning, names, numbers and uncertainty. Follow the requested output language. Output only the requested text.',prompt,512,0,0,{'reasoning_effort':'none'})
                result.update(id=case_id,kind='compose-explicit-no-reasoning',required_strings=required)
                results['cases'].append(result)
                bench.save(alias+'-followups',results)
                print(alias,case_id,round(result['seconds'],3),result['finish_reason'],repr(result['text']),flush=True)
            result=bench.long_context_case()
            results['cases'].append(result)
            print(alias,'long-context',json.dumps(result),flush=True)
        else:
            for meeting in fixture['meetings']:
                prompt='Transcript follows. The speaker labeled "Me" is this Mac\'s user ("Me"); every other speaker is another participant.\n\n---\n\n'+meeting['transcript']+'\n\n---\n\nProduce meeting notes as Markdown. No preamble, no closing remarks.'
                result=request(bench.production_summary_system(),prompt,4096,1024,1.0,{'top_p':0.95})
                result.update(id=meeting['id'],kind='vendor-temperature-summary')
                results['cases'].append(result)
                bench.save(alias+'-followups',results)
                print(alias,'vendor-temperature',meeting['id'],round(result['seconds'],2),result['finish_reason'],flush=True)
            # Production's first summary failure is retried at a larger budget with thinking disabled.
            meeting=fixture['meetings'][0]
            result=request(bench.production_summary_system(),'Produce meeting notes for this transcript:\n'+meeting['transcript'],6144,0,0)
            result.update(id=meeting['id'],kind='summary-recovery')
            results['cases'].append(result)
            print(alias,'recovery',round(result['seconds'],2),result['finish_reason'],flush=True)
    results['runtime']=metrics
    bench.save(alias+'-followups',results)

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('model',choices=['qwen','minicpm5'])
    followup(parser.parse_args().model)
