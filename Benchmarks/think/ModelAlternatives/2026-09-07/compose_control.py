"""Re-score short Qwen requests with the verified template-level control."""
import json
import run as bench
from followups import request

fixture=json.loads((bench.ROOT/'generation-fixture.json').read_text())
results={'model':'qwen','cases':[]}
with bench.server('qwen','generation','qwen-compose-template-disabled') as runtime:
    for case_id,prompt,required in fixture['compose']:
        result=request('You edit dictation and draft concise messages. Preserve meaning, names, numbers and uncertainty. Follow the requested output language. Output only the requested text.',prompt,512,0,0,
                       {'chat_template_kwargs':{'enable_thinking':False}})
        result.update(id=case_id,kind='compose-template-disabled',required_strings=required)
        results['cases'].append(result)
        print(case_id,round(result['seconds'],3),result['finish_reason'],repr(result['text']),flush=True)
results['runtime']=runtime
bench.save('qwen-compose-template-disabled',results)
