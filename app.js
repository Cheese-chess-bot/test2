'use strict';
const $=id=>document.getElementById(id), esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const stocks=['NVDA','AMD','TSLA','AAPL','AMZN'], names={NVDA:'NVIDIA Corporation',AMD:'Advanced Micro Devices',TSLA:'Tesla, Inc.',AAPL:'Apple Inc.',AMZN:'Amazon.com, Inc.'};
let csrf='',state=null,selected='NVDA',initialized=false,chatLast='',toastTimer;
function toast(text){$('toast').textContent=text;$('toast').classList.remove('hidden');clearTimeout(toastTimer);toastTimer=setTimeout(()=>$('toast').classList.add('hidden'),6500);}
async function api(path,body){const r=await fetch(path,{method:body===undefined?'GET':'POST',headers:body===undefined?{}:{'Content-Type':'application/json','X-Jevie-CSRF':csrf},body:body===undefined?undefined:JSON.stringify(body)});const d=await r.json();if(!r.ok)throw Error(d.error||'Request failed');return d;}
const money=v=>v==null?'—':new Intl.NumberFormat('en-US',{style:'currency',currency:'USD',maximumFractionDigits:2}).format(v);
function chart(id,points,key,color='#d4f77d'){
 const values=points.map(p=>Number(p[key])).filter(Number.isFinite);if(values.length<2){$(id).innerHTML='<div class="empty">Waiting for enough observations.</div>';return;}
 const stride=Math.max(1,Math.floor(values.length/250)),v=values.filter((_,i)=>i%stride===0);const lo=Math.min(...v),hi=Math.max(...v),span=hi-lo||1;
 const pts=v.map((n,i)=>`${(i/(v.length-1)*600).toFixed(2)},${(110-(n-lo)/span*95).toFixed(2)}`).join(' ');
 $(id).innerHTML=`<svg viewBox="0 0 600 130" preserveAspectRatio="none" role="img" aria-label="${esc(key)} chart"><defs><linearGradient id="g-${id}" x1="0" y1="0" x2="0" y2="1"><stop offset="0%" stop-color="${color}" stop-opacity=".18"/><stop offset="100%" stop-color="${color}" stop-opacity="0"/></linearGradient></defs><path d="M0 30H600 M0 70H600 M0 110H600" stroke="#2b3330" fill="none" stroke-dasharray="3 6"/><polygon points="0,125 ${pts} 600,125" fill="url(#g-${id})"/><polyline points="${pts}" fill="none" stroke="${color}" stroke-width="2" vector-effect="non-scaling-stroke"/></svg>`;
}
function initForms(){const c=state.config;$('from').value=c.start;$('through').value=c.end;$('timeframe').value=c.timeframe;$('fee-bps').value=c.fee_bps;$('slip-bps').value=c.slippage_bps;$('auto-research').checked=c.auto_research;$('debate-rounds').value=c.debate_rounds;$('diverse-models').checked=c.diverse_models;
 $('workers').innerHTML=stocks.map(s=>`<label><input type="checkbox" value="${s}" ${c.symbols.includes(s)?'checked':''}>${s}</label>`).join('');
 $('model-fields').innerHTML=Object.keys(c.models).map(r=>`<label>${esc(r.toUpperCase())}<input data-role="${r}" list="model-list" placeholder="provider/model-id" value="${esc(c.models[r])}"></label>`).join('');
 if(!c.symbols.includes(selected))selected=c.symbols[0];$('selected').innerHTML=c.symbols.map(s=>`<option ${s===selected?'selected':''}>${s}</option>`).join('');initialized=true;
}
async function selectStock(s){selected=s;$('selected').value=s;chatLast='';render();await chat();}
function renderParticipants(models){
 const roles=['researcher','challenger','critic','decider'],labels={'google/gemma-4-31b-it:free':'Gemma','recursive/flint-v1.0:free':'Flint','cohere/north-mini-code:free':'North Mini','nvidia/nemotron-3.5-super-vl:free':'Nemotron'};
 $('participants').innerHTML=roles.map((role,i)=>`<span class="avatar participant-${i}" title="${esc(role+': '+models[role])}">${esc(models[role].split('/')[0][0]?.toUpperCase()||'?')}</span>`).join('')+`<span>${roles.map(role=>esc(labels[models[role]]||models[role].split('/')[0]||'Unselected')).join(' · ')}</span>`;
}
function render(){if(!state)return;const w=state.workers[selected],r=state.reports[selected],c=state.config,b=w.battery?.answers;
 renderParticipants(c.models);
 $('mode').textContent=state.mode;$('footer-mode').textContent=state.mode==='DEMO'?'SYNTHETIC DATA · NO BROKER ORDERS':'ALPACA '+state.mode+' · OPENROUTER ONLY';
 $('mode').className='badge '+(state.mode==='LIVE'?'red':'');$('start').textContent=state.mode==='LIVE'?'Start LIVE orders ↗':'Start workers ↗';
 $('market').textContent=state.mode==='DEMO'?'Offline demo':state.clock?(state.clock.is_open?'Market open':'Market closed'):'Alpaca disconnected';
 $('summary').textContent=`${c.symbols.length} stock workers · ${state.running?'running':'paused'}`;$('sync').textContent=state.last_sync?'Last sync '+new Date(state.last_sync*1000).toLocaleTimeString():'Waiting for broker connection';
 $('ticker').textContent=selected;$('company').textContent=names[selected];$('price').innerHTML=esc(w.price==null?'—':Number(w.price).toFixed(2))+'<small>USD</small>';
 $('market-note').textContent=state.mode==='DEMO'?'Synthetic fixture price · not a market quote':w.reason;
 $('signal').textContent=w.signal.toUpperCase();$('signal').className='badge '+({buy:'green',sell:'red',hold:'yellow',late:'blue'}[w.signal]||'yellow');
 $('watchlist').innerHTML=c.symbols.map(s=>`<button class="${selected===s?'active':''}" data-stock="${s}">${s} <b class="dot ${{buy:'green',sell:'red',hold:'yellow',late:'blue'}[state.workers[s].signal]}"></b></button>`).join('');
 $('watchlist').querySelectorAll('button').forEach(x=>x.onclick=()=>selectStock(x.dataset.stock));
 chart('price-chart',r?.market_curve||[],'c');
 $('worker-status').textContent=w.status;$('env').textContent=b?Number(b.quote_environment.score).toFixed(2)+' / 3':'— / 3';$('tox').textContent=b?Number(b.toxic_flow.noul).toFixed(3):'—';$('env-meter').value=b?.quote_environment.score||0;$('tox-meter').value=b?.toxic_flow.noul||0;
 const batteryRows=[['Regime',b?.regime.choice],['Direction',b?.direction.choice],['Liquidity stress',b?Number(b.liquidity_stressed.noul).toFixed(2):null],['Inventory pressure',b?Number(b.inventory_pressure.score).toFixed(2)+'/3':null],['Execution health',b?Number(b.execution_health.score).toFixed(2)+'/3':null]];
 $('battery-rest').innerHTML=batteryRows.map(([k,v])=>`<dt>${k}</dt><dd>${esc(v||'—')}</dd>`).join('');
 $('battery-meta').textContent=b?`${w.battery.model} · ${w.battery.latency_ms}ms · ${Math.round(Date.now()/1000-w.battery.as_of)}s old · ENV confidence ${(b.quote_environment.confidence*100).toFixed(0)}%. Limited evidence: top-of-book only; no full depth.`:'Waiting for a real Jev judgment. ENV and TOX are model estimates; no fake battery in demo.';
 $('policy').textContent=w.policy?`${w.policy.kind} · ${(w.policy.size_scale*100).toFixed(0)}% size · ${w.policy.reason}`:'All seven judgments control entry, size and inventory reduction.';
 $('test-state').textContent=r?(r.eligible?'PASSED':'REVIEW'):'NO TEST YET';$('test-state').className='badge '+(r?.eligible?'green':'yellow');
 document.querySelector('.split').innerHTML=r?Object.entries(r.split).map(([k,v])=>`<span>${esc(v)} ${esc(k.toUpperCase())}</span>`).join(''):'<span>60% DISCOVERY</span><span>20% VALIDATION</span><span>20% HOLDOUT</span>';
 if(r){const h=r.holdout;$('test-result').innerHTML=`<div class="numbers"><div><small>HOLDOUT NET</small><strong class="${h.net_pnl>=0?'green':'red'}">${money(h.net_pnl)}</strong></div><div><small>MAX DRAWDOWN</small><strong>${h.max_drawdown_pct.toFixed(2)}%</strong></div><div><small>CLOSED TRADES</small><strong>${h.closed_trades}</strong></div></div><div class="footnote">${esc(r.source)} · ${esc(r.strategy.family)} · ${esc(r.version)} · ${esc(r.timeframe)}</div><ul>${r.reasons.map(x=>`<li>${esc(x)}</li>`).join('')}</ul>`;}
 else $('test-result').innerHTML='<div class="empty">Strategies are frozen before the final holdout.<br>Replaying a holdout cannot qualify a new version.</div>';
 $('version').textContent=state.active[selected]?'Active '+state.active[selected].version:'No active strategy';
 const back=$('trade-source').value==='backtest',trades=back?(r?.holdout.ledger||[]):state.trades.filter(t=>t.symbol===selected);
 $('pnl').textContent=money(trades.reduce((s,t)=>s+(t.net_pnl||0),0));$('fees').textContent=money(trades.reduce((s,t)=>s+(t.fee||0),0));$('fills').textContent=trades.length;
 chart('pnl-chart',back?(r?.holdout.curve||[]):state.equity,back?'pnl':'equity');
 $('trades').innerHTML=trades.slice(-50).reverse().map(t=>`<tr title="${esc(t.order_id||'Backtest fill')}"><td>${esc(t.filled_at?new Date(t.filled_at).toLocaleString():typeof t.t==='number'?new Date(t.t*1000).toLocaleTimeString():String(t.t).slice(0,10))}</td><td class="${t.side==='buy'?'green':'red'}">${esc(t.side.toUpperCase())}</td><td>${Number(t.qty).toFixed(4)}</td><td>${money(t.price)}</td><td>${money(t.fee)}${t.fee_source==='broker-reported'?'':'*'}</td><td>${money(t.net_pnl)}</td></tr>`).join('')||'<tr><td colspan="6">No fills recorded for this view.</td></tr>';
 const f=state.fees;$('fee-status').textContent=f?`Account reported fees: ${money(f.reported_total)} · Matched to Jevie: ${money(f.allocated_total)} · ${f.unallocated.length} unmatched records`:'Waiting for fee reconciliation';
 $('fee-records').textContent=JSON.stringify({unmatched:f?.unallocated||[],orders:[...new Map(state.trades.map(t=>[t.order_id,{order_id:t.order_id,symbol:t.symbol,side:t.side}])).values()]},null,2);
 const jobs=state.jobs.filter(j=>j.symbol===selected);const j=jobs.at(-1);$('job-status').textContent=j?`${j.kind} ${j.status} · ${j.id}${j.error?' · '+j.error:''}`:'Every claim needs a test.';
 $('connection-state').textContent=Object.entries(state.connections).map(([k,v])=>`${k}: ${v?'configured':'disconnected'}`).join(' · ');
 $('integration-state').textContent=`Hermes last successful reflection: ${state.integrations?.hermes_last_success?new Date(state.integrations.hermes_last_success*1000).toLocaleString():'none'} · OpenBot/AG-UI last authenticated request: ${state.integrations?.openbot_last_request?new Date(state.integrations.openbot_last_request*1000).toLocaleString():'none'}`;
 if(state.last_error)$('sync').textContent=state.last_error;
}
async function chat(){try{const rows=await api('/api/chat?symbol='+encodeURIComponent(selected));const stamp=selected+':'+rows.map(r=>r.id).join(',');if(stamp===chatLast)return;chatLast=stamp;
 $('chat').innerHTML=rows.map(r=>`<article class="message"><div class="message-head"><span>${esc(r.role)} ${r.meta.model?'· '+esc(r.meta.model):''}</span><time>${new Date(r.t*1000).toLocaleTimeString()}</time></div><pre>${esc(r.text)}</pre></article>`).join('')||'<div class="empty">Type an enabled ticker to research it.<br>Choose OpenRouter models in Connections first.</div>';$('chat').scrollTop=$('chat').scrollHeight;
 }catch(e){toast(e.message);}}
async function refresh(){try{state=await api('/api/state');if(!initialized)initForms();render();await chat();}catch(e){$('sync').textContent='Connection lost: '+e.message;}}
async function command(text){try{const d=await api('/api/command',{text,symbol:selected});toast(d.message||('job'in d?'Research started · '+d.job:'Command complete'));await refresh();}catch(e){toast(e.message);}}
$('chat-form').onsubmit=e=>{e.preventDefault();const v=$('command').value;$('command').value='';command(v);};
$('start').onclick=()=>command('/start');$('pause').onclick=()=>command('/pause');$('selected').onchange=e=>selectStock(e.target.value);$('trade-source').onchange=render;
document.querySelectorAll('[data-command]').forEach(b=>b.onclick=()=>command(b.dataset.command+' '+selected));
$('connections').onclick=()=>$('settings').showModal();$('close-settings').onclick=()=>$('settings').close();
$('load-models').onclick=async()=>{try{$('load-models').disabled=true;const models=await api('/api/models');$('model-list').innerHTML=models.map(m=>`<option value="${esc(m.id)}">${esc(m.name)}</option>`).join('');toast(models.length+' OpenRouter models loaded');}catch(e){toast(e.message);}finally{$('load-models').disabled=false;}};
$('save-models').onclick=async()=>{try{const models=Object.fromEntries([...document.querySelectorAll('[data-role]')].map(e=>[e.dataset.role,e.value.trim()]));await api('/api/config',{models,debate_rounds:Number($('debate-rounds').value),diverse_models:$('diverse-models').checked});toast('Models and discussion budget saved');$('settings').close();await refresh();}catch(e){toast(e.message);}};
$('fee-file').onchange=async e=>{try{const f=e.target.files[0];if(!f)return;if(f.size>180000)throw Error('Use a CSV smaller than 180 KB');const result=await api('/api/fees/import',{csv:await f.text()});toast(result.records+' fee records saved');await refresh();}catch(err){toast(err.message);}finally{e.target.value='';}};
$('sync-fees').onclick=()=>command('/fees');
$('save-workers').onclick=async()=>{try{const symbols=[...$('workers').querySelectorAll('input:checked')].map(x=>x.value);await api('/api/config',{symbols,auto_research:$('auto-research').checked});initialized=false;await refresh();toast('Worker selection saved');}catch(e){toast(e.message);}};
$('backtest').onclick=async()=>{try{$('backtest').disabled=true;await api('/api/config',{start:$('from').value,end:$('through').value,timeframe:$('timeframe').value,fee_bps:Number($('fee-bps').value),slippage_bps:Number($('slip-bps').value)});await command('/research '+selected);}catch(e){toast(e.message);}finally{$('backtest').disabled=false;}};
(async()=>{try{csrf=(await api('/api/bootstrap')).csrf;await refresh();setInterval(refresh,4000);}catch(e){toast(e.message);}})();
