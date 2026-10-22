import copy,json,tempfile,threading,unittest,urllib.request,urllib.error
from pathlib import Path
from unittest.mock import patch
from http.server import ThreadingHTTPServer
from jevie_core import *
from jevie_engine import App
from jevie_research import parse_proposal
from jevie_clients import OpenRouter,Alpaca
from start_jevie import make_handler
class CoreTests(unittest.TestCase):
 def setUp(self):self.bars=demo_bars('NVDA')
 def test_two_to_five(self):
  for value in [['NVDA'],list(TICKERS)+['MSFT'],['NVDA','NVDA']]:
   with self.assertRaises(ValueError):symbols(value)
  self.assertEqual(symbols(['NVDA','AMD']),['NVDA','AMD'])
 def test_nonfinite_rejected(self):
  for x in [float('nan'),float('inf'),True]:
   with self.assertRaises(ValueError):Strategy.parse(dict(allocation=x))
 def test_strategy_cannot_change_risk_engine(self):
  with self.assertRaises(ValueError):Strategy.parse(dict(max_drawdown=1))
 def test_allocation_cap(self):
  with self.assertRaises(ValueError):Strategy.parse(dict(allocation=.8))
 def test_integer_lookbacks(self):
  with self.assertRaises(ValueError):Strategy.parse(dict(fast=2.3))
 def test_bad_lookback_order(self):
  with self.assertRaises(ValueError):Strategy.parse(dict(fast=50,slow=20))
 def test_unsupported_code(self):
  with self.assertRaises(ValueError):parse_proposal('{"strategy":{"code":"import os"}}')
 def test_hash_stability(self):self.assertEqual(Strategy().version,Strategy.parse(asdict(Strategy())).version)
 def test_ohlc_rejected(self):
  bars=copy.deepcopy(self.bars);bars[4]['h']=1
  with self.assertRaises(ValueError):simulate(bars,Strategy())
 def test_duplicates_rejected(self):
  bars=copy.deepcopy(self.bars);bars[4]['t']=bars[3]['t']
  with self.assertRaises(ValueError):simulate(bars,Strategy())
 def test_next_open_fill(self):
  bars=[dict(t=f'{i:04}',o=100+i,h=1000,l=1,c=100+i,v=1000) for i in range(70)]
  r=simulate(bars,Strategy(fast=2,slow=4),fee_bps=0,slippage_bps=0)
  self.assertEqual(r['ledger'][0]['price'],104)
 def test_no_future_peeking(self):
  s=Strategy(fast=3,slow=10);original=simulate(self.bars,s);bars=copy.deepcopy(self.bars)
  for b in bars[500:]:
   for k in ('o','h','l','c'):b[k]*=2
  changed=simulate(bars,s)
  self.assertEqual([x for x in original['ledger'] if x['t']<bars[500]['t']],[x for x in changed['ledger'] if x['t']<bars[500]['t']])
 def test_fees_lower_return(self):
  a=simulate(self.bars,Strategy(),fee_bps=0,slippage_bps=0);b=simulate(self.bars,Strategy(),fee_bps=10,slippage_bps=10)
  self.assertLess(b['net_pnl'],a['net_pnl'])
 def test_cost_sum(self):
  r=simulate(self.bars,Strategy());self.assertAlmostEqual(sum(x['fee'] for x in r['ledger']),r['fees'],places=3)
 def test_gate(self):
  r=dict(closed_trades=0,net_pnl=-1,max_drawdown_pct=20);self.assertEqual(len(gate(r,r)),6)
 def test_stop_loss(self):self.assertEqual(signal(self.bars,Strategy(),True,basis=1e4),'sell')
 def test_battery_range(self):
  ans={k:dict(type=q['type'],noul=.2,score=2,confidence=.8,choice=next(iter(q.get('criteria',{'a':0})))) for k,q in QUESTIONS.items()}
  battery_validate(ans);ans['toxic_flow']['noul']=1.2
  with self.assertRaises(ValueError):battery_validate(ans)
 def test_router_fixed_host(self):
  with patch('jevie_clients.request',return_value={'choices':[{'message':{'content':'ok'}}]}) as r:
   OpenRouter('fake').chat('test/model',[]);self.assertEqual(r.call_args.args[0],'https://openrouter.ai/api/v1/chat/completions')
 def test_decisions_route(self):
  with patch('jevie_clients.request',return_value={}) as r:
   with self.assertRaises(ValueError):OpenRouter('fake').battery({})
   self.assertEqual(r.call_args.args[0],'https://openrouter.ai/api/alpha/decisions')
 def test_live_requires_opt_in(self):
  with patch.dict('os.environ',{},clear=True):
   with self.assertRaises(ValueError):Alpaca(True)
class AppTests(unittest.TestCase):
 def setUp(self):self.temp=tempfile.TemporaryDirectory();self.a=App(self.temp.name,demo=True)
 def tearDown(self):self.a.close();self.a.thread.join(2);self.a.store.db.close();self.temp.cleanup()
 def test_synthetic_never_promotes(self):
  r=self.a.research.run('NVDA','test');self.assertFalse(r['eligible']);self.assertIsNone(self.a.store.get('candidate:NVDA'))
 def test_holdout_consumed(self):
  self.a.research.run('NVDA','a');r=self.a.research.run('NVDA','b');self.assertTrue(any('Holdout already' in x for x in r['reasons']))
 def test_new_holdout_accumulates_without_exposure(self):
  bars=demo_bars('NVDA')
  with patch('jevie_research.demo_bars',return_value=bars[:500]):self.a.research.run('NVDA','first')
  with patch('jevie_research.demo_bars',return_value=bars[:550]):self.a.research.run('NVDA','diagnostic')
  self.assertEqual(self.a.store.get('holdout_until:NVDA'),bars[499]['t'])
  with patch('jevie_research.demo_bars',return_value=bars[:600]):r=self.a.research.run('NVDA','fresh')
  self.assertEqual(r['split']['holdout'],100)
  self.assertFalse(any('overlaps' in x for x in r['reasons']))
 def test_drawdown_latch_prevents_start(self):
  self.a.killed=True
  with self.assertRaises(ValueError):self.a.start()
 def test_config_while_running(self):
  self.a.start()
  with self.assertRaises(ValueError):self.a.configure(dict(symbols=['TSLA','AMD']))
 def test_no_secret_in_state(self):self.assertNotIn('API_KEY',json.dumps(self.a.state()))
 def test_cannot_remove_position(self):
  self.a.store.put('position:NVDA',dict(qty=1))
  with self.assertRaises(ValueError):self.a.configure(dict(symbols=['TSLA','AMD']))
 def test_partial_fill_idempotent(self):
  o=dict(id='one',symbol='NVDA',client_order_id='jv2-NVDA-test',filled_qty='2',filled_avg_price='100',side='buy',status='partially_filled')
  self.a.reconcile(o);self.a.reconcile(o);self.assertEqual(len(self.a.store.events('fill')),1)
  o.update(filled_qty='3',filled_avg_price='102',status='filled');self.a.reconcile(o)
  self.assertEqual(self.a.store.get('position:NVDA')['qty'],3);self.assertAlmostEqual(self.a.store.get('position:NVDA')['basis'],102);self.assertAlmostEqual(self.a.store.events('fill')[-1]['price'],106)
 def test_sell_counts_both_fee_sides(self):
  self.a.reconcile(dict(id='buy',symbol='AMD',client_order_id='jv2-AMD-b',filled_qty='2',filled_avg_price='100',side='buy',status='filled'))
  self.a.reconcile(dict(id='sell',symbol='AMD',client_order_id='jv2-AMD-s',filled_qty='2',filled_avg_price='110',side='sell',status='filled'))
  self.assertAlmostEqual(self.a.store.events('fill')[-1]['net_pnl'],20-.02-.022)
 def test_store_survives_restart(self):
  self.a.store.put('lesson',{'text':'remember'});other=Store(Path(self.temp.name)/'jevie.sqlite');self.assertEqual(other.get('lesson')['text'],'remember');other.db.close()
 def test_external_orders_ignored(self):
  self.a.reconcile(dict(id='bad',symbol='NVDA',client_order_id='manual',filled_qty='20',filled_avg_price='100',side='buy',status='filled'));self.assertEqual(len(self.a.store.events('fill')),0)
 def test_pending_blocks_worker(self):
  self.a.store.put('pending:NVDA',dict(cid='jv2-NVDA-uncertain'));self.a.tick('NVDA',{'is_open':True},{},[],[],0);self.assertEqual(self.a.workers['NVDA']['status'],'ORDER_PENDING')
 def test_server_security(self):
  server=ThreadingHTTPServer(('127.0.0.1',0),make_handler(self.a));t=threading.Thread(target=server.serve_forever,daemon=True);t.start();base=f'http://127.0.0.1:{server.server_port}'
  try:
   with urllib.request.urlopen(base+'/api/health') as r:self.assertTrue(json.load(r)['ok'])
   req=urllib.request.Request(base+'/api/command',data=b'{"text":"/start"}',headers={'Content-Type':'application/json'})
   with self.assertRaises(urllib.error.HTTPError) as ctx:urllib.request.urlopen(req)
   self.assertEqual(ctx.exception.code,403)
   with urllib.request.urlopen(base+'/api/bootstrap') as r:token=json.load(r)['csrf']
   req.add_header('X-Jevie-CSRF',token)
   with urllib.request.urlopen(req) as r:self.assertIn('message',json.load(r))
   agent=urllib.request.Request(base+'/api/ag-ui',data=b'{"messages":[{"role":"user","content":"/status"}]}',headers={'Content-Type':'application/json','x-openbot-agent-token':'test-token'})
   with patch.dict('os.environ',{'JEVIE_AGENT_TOKEN':'test-token'}):
    with urllib.request.urlopen(agent) as r:self.assertIn('RUN_FINISHED',r.read().decode())
  finally:server.shutdown();server.server_close();t.join()
if __name__=='__main__':unittest.main(verbosity=2)
