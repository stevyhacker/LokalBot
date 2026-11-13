"""Minimal reproduction of the observed zero-budget behavior, not app UI testing."""
import json
import run as bench
from followups import request

variants=[
    ('budget-0',{}),
    ('native-budget-1',{'reasoning_budget_tokens':1}),
    ('template-disabled',{'chat_template_kwargs':{'enable_thinking':False}}),
    ('effort-none-unlimited-budget',{'reasoning_effort':'none','thinking_budget_tokens':-1}),
]
results={'model':'qwen','cases':[]}
with bench.server('qwen','generation','qwen-budget-probe') as runtime:
    for name,extra in variants:
        result=request('Return only the corrected sentence.','Please send the report to ana dot petrovic at example dot com before Tuesday.',256,0,0,extra)
        result['id']=name
        results['cases'].append(result)
        print(name,round(result['seconds'],3),result['finish_reason'],repr(result['text']),flush=True)
        bench.save('qwen-budget-probe',results)
results['runtime']=runtime
bench.save('qwen-budget-probe',results)
