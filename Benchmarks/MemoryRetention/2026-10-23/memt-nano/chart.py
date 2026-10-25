"""Five-configuration comparison; the additional runtime is labeled explicitly."""
import csv
import json
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.ticker import PercentFormatter, MaxNLocator

ROOT = Path(__file__).resolve().parent
BASE = ROOT.parent
models = json.loads((BASE/'models.json').read_text()) + [
    {'arm':'memt-nano-nf4-offload', 'label':'MemT-1.0-Nano*',
     'quantization':'NF4 experts / BF16 dense'}]
scores = {**json.loads((BASE/'scores.json').read_text()), **json.loads((ROOT/'scores.json').read_text())}
rows = []
for model in models:
    assert model['arm']+'/reviewed' in scores, 'Finish semantic review first'
    for language in ['en','sr']:
        rows.append(dict(**model, language=language, **scores[model['arm']+'/reviewed'][language]))
with (ROOT/'chart-data.csv').open('w', newline='') as f:
    writer = csv.DictWriter(f, fieldnames=list(rows[0]))
    writer.writeheader()
    writer.writerows(rows)
plt.rcParams.update({'font.family':'DejaVu Sans','font.size':11,'text.color':'#20252B',
                     'axes.labelcolor':'#20252B','xtick.color':'#5A6470','ytick.color':'#20252B','svg.fonttype':'none'})
for language, subtitle in [('en','96 English cases · 52 eligible memories · 44 empty-output cases'),
                           ('sr','24 Serbian cases · 13 eligible memories · 11 empty-output cases')]:
    data = [row for row in rows if row['language']==language]
    fig, axes = plt.subplots(1,3,figsize=(15,8.1),gridspec_kw={'wspace':.27})
    fig.patch.set_facecolor('white')
    fig.subplots_adjust(left=.21,right=.97,bottom=.29,top=.72)
    fig.text(.035,.94,'Recall vs. restraint',size=27,weight='bold')
    fig.text(.035,.89,subtitle,size=13,color='#59636E')
    fig.text(.035,.845,'Stateless personal-memory extraction · thinking disabled · dataset 23 Oct / MemT completed 25 Oct 2026',size=11,color='#59636E')
    panels = [('recalled','gold','Useful memories + correct source','Higher is better'),
              ('clean_empty','empty_cases','Empty cases handled correctly','Higher is better'),
              ('unwanted',None,'Unwanted memory proposals','Lower is better')]
    for ax,(key,denominator,title,direction) in zip(axes,panels):
        values = [100*row[key]/row[denominator] if denominator else row[key] for row in data]
        normal = '#2866AA' if denominator else '#BD683B'
        ax.barh(range(5),values,height=.49,color=[normal]*4+['#7B65A5'])
        ax.set_ylim(4.55,-.55)
        ax.set_title(title,fontsize=11.5,weight='bold',loc='left',pad=40)
        ax.text(0,1.065,direction,transform=ax.transAxes,fontsize=10,color='#59636E')
        ax.set_yticks(range(5))
        ax.set_yticklabels([row['label']+'\n'+row['quantization'] for row in data] if ax is axes[0] else ['']*5,fontsize=10.5)
        ax.tick_params(axis='y',length=0,pad=12)
        for side in ['top','right','left']:
            ax.spines[side].set_visible(False)
        ax.spines['bottom'].set_color('#C8CED5')
        ax.grid(axis='x',color='#EBEEF2',linewidth=.7)
        ax.set_axisbelow(True)
        if denominator:
            ax.set_xlim(0,120)
            ax.set_xticks([0,25,50,75,100])
            ax.xaxis.set_major_formatter(PercentFormatter())
        else:
            ax.set_xlim(0,max(10,max(row['unwanted'] for row in rows)*1.32))
            ax.xaxis.set_major_locator(MaxNLocator(integer=True,nbins=4))
            ax.set_xlabel(f"Count across {data[0]['cases']} cases",fontsize=10)
        for position,(value,row) in enumerate(zip(values,data)):
            label = f"{row[key]}/{row[denominator]}" if denominator else str(row[key])
            ax.text(value+.025*ax.get_xlim()[1],position,label,va='center',size=12,weight='bold')
    fig.text(.035,.205,'* MemT backbone: Qwen3.6-35B-A3B; experimental NF4 offload on RX 6600 XT. Others: GGUF / llama.cpp on Ubuntu CPU.',fontsize=10.5)
    fig.text(.035,.16,'Fresh state in every case: this does not exercise MemT’s persistent latent-memory feature.',fontsize=10.5)
    fig.text(.035,.115,'“Unwanted” includes true but excluded information. Correct recall requires a valid source citation.',fontsize=10.5)
    fig.text(.035,.07,'AI-authored synthetic cases + unblinded AI semantic review. No independent human validation or significance claim.',fontsize=10,color='#59636E')
    stem = 'memory-retention-with-memt' + ('-serbian' if language=='sr' else '')
    for suffix in ['png','svg']:
        destination = ROOT/f'{stem}.{suffix}'
        fig.savefig(destination,dpi=180,facecolor='white')
        if suffix == 'svg':
            # Matplotlib emits spaces before line breaks inside path data.
            destination.write_text('\n'.join(line.rstrip() for line in destination.read_text().splitlines())+'\n')
    plt.close(fig)
print('Saved both comparison charts and exact chart data.')
