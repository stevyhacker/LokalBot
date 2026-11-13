"""Reproducible Reddit-ready PNG/SVG from reviewed scores; no manual chart values."""
import csv
import json
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.ticker import PercentFormatter,MaxNLocator

ROOT=Path(__file__).resolve().parent
models=json.loads((ROOT/'models.json').read_text())
scores=json.loads((ROOT/'scores.json').read_text())
rows=[]
for m in models:
    assert m['arm']+'/reviewed' in scores,'Complete semantic review before rendering'
    for language in ['en','sr']:
        rows.append(dict(arm=m['arm'],label=m['label'],quantization=m['quantization'],language=language,**scores[m['arm']+'/reviewed'][language]))
with (ROOT/'chart-data.csv').open('w') as f:
    w=csv.DictWriter(f,fieldnames=list(rows[0]));w.writeheader();w.writerows(rows)

plt.rcParams.update({'font.family':'DejaVu Sans','font.size':11,'text.color':'#20252B','axes.labelcolor':'#20252B','xtick.color':'#5A6470','ytick.color':'#20252B','svg.fonttype':'none'})
for language,subtitle in [('en','96 English cases · 48 contrast pairs · one greedy pass per model'),('sr','24 Serbian cases · 12 contrast pairs · exploratory language slice')]:
    data=[r for r in rows if r['language']==language]
    fig,axs=plt.subplots(1,3,figsize=(14,6.8),gridspec_kw={'wspace':.26})
    fig.patch.set_facecolor('#FFFFFF')
    fig.subplots_adjust(left=.19,right=.97,bottom=.25,top=.68)
    fig.text(.035,.93,'What should a local memory model keep?',size=25,weight='bold')
    fig.text(.035,.875,subtitle,size=13,color='#59636E')
    fig.text(.035,.825,'Current app prompt · synthetic policy-following test · CPU llama.cpp · 23 Oct 2026',size=11,color='#59636E')
    panels=[('recalled','gold','Useful memories + correct source','Higher is better','#2866AA'),('clean_empty','empty_cases','Empty cases handled correctly','Higher is better','#2866AA'),('unwanted',None,'Unwanted memory proposals','Lower is better','#BD683B')]
    for ax,(key,denom,title,direction,color) in zip(axs,panels):
        vals=[100*r[key]/r[denom] if denom else r[key] for r in data]
        ax.barh(range(len(data)),vals,height=.48,color=color)
        ax.invert_yaxis();ax.set_ylim(len(data)-.45,-.55)
        ax.set_title(title,fontsize=12,weight='bold',loc='left',pad=42)
        ax.text(0,1.08,direction,transform=ax.transAxes,fontsize=10,color='#59636E')
        ax.set_yticks(range(len(data)))
        ax.set_yticklabels([r['label']+'\n'+r['quantization'] for r in data] if ax is axs[0] else ['']*len(data),fontsize=11)
        ax.tick_params(axis='y',length=0,pad=12)
        for s in ['top','right','left']:ax.spines[s].set_visible(False)
        ax.spines['bottom'].set_color('#C8CED5')
        ax.grid(axis='x',color='#EBEEF2',linewidth=.7);ax.set_axisbelow(True)
        if denom:
            ax.set_xlim(0,120);ax.set_xticks([0,25,50,75,100]);ax.xaxis.set_major_formatter(PercentFormatter())
        else:
            ax.set_xlim(0,max(10,max(r['unwanted'] for r in rows)*1.32));ax.xaxis.set_major_locator(MaxNLocator(integer=True,nbins=4));ax.set_xlabel(f"Count across {data[0]['cases']} cases",fontsize=10)
        for y,(v,r) in enumerate(zip(vals,data)):
            label=f"{r[key]}/{r[denom]}" if denom else str(r[key])
            ax.text(v+(.025*ax.get_xlim()[1]),y,label,va='center',size=12,weight='bold')
    fig.text(.035,.15,'“Unwanted” includes true information the prompt says to skip; it does not mean every item was fabricated.',fontsize=11)
    fig.text(.035,.105,'Assistant-authored cases + assistant semantic review. No independent human validation. Pair members are related.',fontsize=10,color='#59636E')
    fig.text(.035,.065,'Recall requires correct content and source citation. Proposed memories only; no retrieval/storage test or significance claim.',fontsize=10,color='#59636E')
    stem='memory-retention' if language=='en' else 'memory-retention-serbian'
    fig.savefig(ROOT/f'{stem}.png',dpi=180,facecolor='white')
    fig.savefig(ROOT/f'{stem}.svg',facecolor='white')
    plt.close(fig)
print('Wrote charts and exact chart-data.csv')
