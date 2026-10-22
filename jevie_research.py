"""Multi-model proposal, critique, evaluation and Hermes learning workflow."""
import hashlib, json, os, subprocess, sys, time
from dataclasses import asdict
from datetime import date,timedelta
from pathlib import Path
from jevie_core import Strategy,simulate,gate,demo_bars
from jevie_clients import APIError
from jevie_debate import make_candidates,discuss

def parse_proposal(text):
    text=text.strip()
    if text.startswith('```'): text=text.split('\n',1)[1].rsplit('```',1)[0].strip()
    raw=json.loads(text); s=Strategy.parse(raw['strategy'])
    summary=str(raw.get('summary',''))[:4000]
    return s,summary

class Research:
    def __init__(self,app): self.app=app
    def discuss(self,symbol,prompt,job):return discuss(self.app,symbol,prompt,job)
    def run(self,symbol,job,override=None,rolling=False):
        a=self.app;cfg=dict(a.config);demo=a.demo
        if rolling:cfg['end']=(date.today()-timedelta(days=1)).isoformat()
        a.chat(symbol,'system','Loading chronological history. Models see only the discovery segment.',job)
        bars=demo_bars(symbol) if demo else a.broker.bars(symbol,cfg['start'],cfg['end'],cfg['timeframe'])
        if len(bars)<400: raise ValueError('Research needs at least 400 completed bars for discovery, validation and holdout')
        n=len(bars);train_end=int(n*.6);val_end=int(n*.8)
        exposed=a.store.get('holdout_until:'+symbol,'');fresh_window=True
        if exposed:
            first_new=next((i for i,b in enumerate(bars) if b['t']>exposed),n)
            if n-first_new>=80 and first_new>=320:
                # Freeze each new proposal using old history, then test only new bars.
                val_end=first_new;train_end=int(first_new*.75)
            else:
                fresh_window=False
                # Leave a small incoming window untouched until enough new bars
                # accumulate. A diagnostic replay only shows already seen history.
                if first_new<400:raise ValueError('This date range needs more previously seen training history')
                bars=bars[:first_new];n=len(bars);train_end=int(n*.6);val_end=int(n*.8)
        discovery=bars[:train_end]
        # A snapshot/experiment fingerprint distinguishes data sources and execution intervals.
        fingerprint=hashlib.sha256(json.dumps([symbol,cfg['timeframe'],demo,bars],sort_keys=True).encode()).hexdigest()
        prior=a.store.get('lessons:'+symbol,[])
        context=dict(symbol=symbol,timeframe=cfg['timeframe'],data_source='synthetic fixture' if demo else 'Alpaca',
                     start=discovery[0]['t'],end=discovery[-1]['t'],bars=discovery[-160:],lessons=prior[-8:])
        candidates=[];prepared=None;consensus=True
        if override:
            candidates=[(Strategy.parse(override),'Frozen external proposal')]
        elif demo:
            candidates=[(Strategy(),'Synthetic fixture: trend baseline'),(Strategy(family='reversion',fast=8,slow=30),'Synthetic fixture: reversion baseline')]
            a.chat(symbol,'fixture','Offline workflow test. No Gemini, ChatGPT, Kimi, Claude or Hermes call is simulated as real.',job)
        else:
            a.chat(symbol,'system','Historical hypothesis research; current news is excluded from historical selection to avoid future-data leakage.',job)
            candidates,prepared,index,consensus=make_candidates(a,symbol,job,cfg,context,bars,train_end,val_end)
        evaluations=prepared or []
        if prepared is None:
            for s,summary in candidates:
                val=simulate(bars,s,train_end,val_end,cfg['fee_bps'],cfg['slippage_bps'])
                evaluations.append(dict(strategy=asdict(s),summary=summary,validation={k:v for k,v in val.items() if k not in ('curve','ledger')}))
            index=max(range(len(evaluations)),key=lambda i:evaluations[i]['validation']['net_pnl'])
        s,summary=candidates[index]
        # Holdout is consumed once per exact dataset; failed experiments also consume it.
        fresh=a.store.claim('holdout:'+fingerprint,dict(job=job,version=s.version))
        validation=simulate(bars,s,train_end,val_end,cfg['fee_bps'],cfg['slippage_bps'])
        holdout=simulate(bars,s,val_end,len(bars),cfg['fee_bps'],cfg['slippage_bps'])
        reasons=gate(validation,holdout)
        if not consensus:reasons.append('Debate budget ended without consensus')
        if not fresh_window: reasons.append('Need at least 80 unseen bars after the last holdout; diagnostic replay only')
        if exposed and bars[val_end]['t']<=exposed: reasons.append('Holdout overlaps previously inspected market history; diagnostic only')
        # Diagnostic runs expose their full history too. Track that exposure so a
        # later experiment cannot present the same prices as unseen evidence.
        a.store.put('holdout_until:'+symbol,max(exposed,bars[-1]['t']))
        if not fresh: reasons.append('Holdout already inspected: diagnostic replay only; use genuinely new unseen data')
        if demo: reasons.append('Synthetic fixture cannot qualify for broker trading')
        report=dict(id=job,symbol=symbol,version=s.version,strategy=asdict(s),summary=summary,source=context['data_source'],timeframe=cfg['timeframe'],fingerprint=fingerprint,
                    created=time.time(),market_curve=[{'t':b['t'],'c':b['c']} for b in bars[-250:]],split=dict(discovery=train_end,validation=val_end-train_end,holdout=n-val_end),
                    validation=validation,holdout=holdout,candidates=evaluations,eligible=not reasons,reasons=reasons)
        # Commit active version only when no broker exposure or unresolved order exists.
        a.store.put('report:'+symbol,report);a.store.put('version:'+symbol+':'+s.version,report)
        a.store.event('experiment',symbol,dict(version=s.version,eligible=not reasons,reasons=reasons,net_pnl=holdout['net_pnl'],job=job))
        a.chat(symbol,'evaluator',f"{s.family} / {s.version}: holdout net ${holdout['net_pnl']:.2f}. "+('; '.join(reasons) if reasons else 'Passed evaluation; queued for '+('LIVE' if a.live else 'paper')+' activation.'),job)
        if not reasons:
            with a.lock:
                a.store.put('candidate:'+symbol,dict(version=s.version,strategy=asdict(s),timeframe=cfg['timeframe'],at=time.time()))
        if os.getenv('HERMES_PYTHON') and not demo:
            self.learn(symbol,report,job)
        elif demo:
            a.chat(symbol,'system','Offline demo: Hermes inference is disabled. Installed integrations are used only outside demo mode.',job)
        else:
            a.chat(symbol,'system','Hermes reflection is disconnected. Set HERMES_PYTHON and HERMES_SOURCE to enable the real Hermes runtime.',job)
        return report
    def learn(self,symbol,report,job):
        a=self.app;exe=os.getenv('HERMES_PYTHON');source=os.getenv('HERMES_SOURCE')
        if a.demo:raise ValueError('Hermes inference is disabled in offline demo mode')
        if not exe or not source: raise ValueError('Configure HERMES_PYTHON and HERMES_SOURCE')
        payload=dict(symbol=symbol,model=a.config['models']['evolver'],prior=a.store.get('lessons:'+symbol,[])[-8:],
                     experiment={k:v for k,v in report.items() if k not in ('validation','holdout','candidates')},
                     validation={k:v for k,v in report['validation'].items() if k not in ('curve','ledger')},holdout={k:v for k,v in report['holdout'].items() if k not in ('curve','ledger')})
        # Subprocess receives only the OpenRouter credential and isolated Hermes home.
        env={k:os.environ[k] for k in ('PATH','SYSTEMROOT','WINDIR','LANG','SSL_CERT_FILE','USERPROFILE','HOME') if k in os.environ}
        env.update(OPENROUTER_API_KEY=a.router.key,HERMES_SOURCE=source,HERMES_HOME=str(a.root/'hermes'/symbol),PYTHONIOENCODING='utf-8')
        r=subprocess.run([exe,str(Path(__file__).with_name('hermes_bridge.py'))],input=json.dumps(payload),text=True,capture_output=True,timeout=150,env=env)
        if r.returncode: raise APIError('Hermes reflection failed; check its isolated runtime and dependency setup')
        result=json.loads(r.stdout);lesson=result['lesson']
        if not isinstance(lesson,str) or not lesson:raise ValueError('Hermes returned no lesson')
        a.store.put('hermes_last_success',time.time())
        lessons=a.store.get('lessons:'+symbol,[]);lessons.append(dict(at=time.time(),version=report['version'],text=lesson[:8000]))
        a.store.put('lessons:'+symbol,lessons[-50:]);a.chat(symbol,'hermes',lesson,job,dict(model=payload['model']))
        skill_dir=a.root/'hermes'/symbol/'skills'/'jevie-research';skill_dir.mkdir(parents=True,exist_ok=True)
        (skill_dir/'SKILL.md').write_text('---\nname: jevie-research\ndescription: Lessons from evaluated Jevie experiments\n---\n\n'+ '\n\n'.join(x['text'] for x in lessons[-8:]),encoding='utf-8')
        return result
