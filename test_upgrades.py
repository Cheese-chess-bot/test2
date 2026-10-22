import copy,json,os,tempfile,time,unittest,subprocess,threading
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock,patch
from jevie_core import QUESTIONS,Strategy,Store,asdict,demo_bars,signal,simulate
from jevie_engine import App,DEFAULT
from jevie_policy import compose_policy
from jevie_fees import normalize,import_csv,reconcile_view
from jevie_sandbox import StrategyProcess,available
from jevie_debate import make_candidates,validate_models,discuss
from jevie_clients import Alpaca

def battery():
    return {k:dict(type=q['type'],noul=.1,score=3,confidence=.9,choice={'regime':'trending','direction':'up'}.get(k,'neutral')) for k,q in QUESTIONS.items()}

class PolicyTests(unittest.TestCase):
    def test_each_judgment_changes_policy(self):
        self.assertTrue(compose_policy(battery())['allow_entry'])
        for name,change,field,expected in [
            ('quote_environment',dict(score=0),'allow_entry',False),
            ('toxic_flow',dict(noul=.7),'allow_entry',False),
            ('liquidity_stressed',dict(noul=.8),'allow_entry',False),
            ('regime',dict(choice='crisis'),'reduce_inventory',True),
            ('direction',dict(choice='down'),'allow_entry',False),
            ('inventory_pressure',dict(score=3),'reduce_inventory',True),
            ('execution_health',dict(score=0),'allow_entry',False)]:
            with self.subTest(judgment=name):
                a=battery();a['inventory_pressure']['score']=0;a[name].update(change)
                self.assertEqual(compose_policy(a,10)[field],expected)
    def test_env_uncertainty_reduces_size(self):
        a=battery();a['quote_environment'].update(score=1.5,confidence=.7)
        self.assertEqual(compose_policy(a)['size_scale'],.5)
        a['quote_environment']['confidence']=.2
        self.assertFalse(compose_policy(a)['allow_entry'])
    def test_bad_battery_fails_closed(self):
        a=battery();del a['execution_health']
        with self.assertRaises(ValueError):compose_policy(a)

@unittest.skipUnless(available(),'Linux libseccomp or Docker required')
class SandboxTests(unittest.TestCase):
    def test_custom_strategy_next_open_and_no_future(self):
        bars=demo_bars('NVDA',100)
        s=Strategy.parse(dict(family='python',warmup=3,python_code="def decide(bars, position, parameters):\n    return 'buy' if len(bars)%7<3 else 'sell'"))
        r=simulate(bars,s,fee_bps=0,slippage_bps=0)
        self.assertEqual(r['ledger'][0]['price'],bars[7]['o'])
        changed=copy.deepcopy(bars)
        for b in changed[60:]:
            for k in ('o','h','l','c'):b[k]*=3
        later=simulate(changed,s,fee_bps=0,slippage_bps=0)
        self.assertEqual([f for f in r['ledger'] if f['t']<bars[60]['t']],[f for f in later['ledger'] if f['t']<bars[60]['t']])
    def test_globals_do_not_persist(self):
        code="count=0\ndef decide(bars,position,parameters):\n    global count\n    count+=1\n    return 'buy' if count==1 else 'sell'"
        with StrategyProcess(code) as p:
            self.assertEqual(p.decide([],{}),'buy');self.assertEqual(p.decide([],{}),'buy')
    def test_actual_position_and_custom_warmup(self):
        s=Strategy.parse(dict(family='python',warmup=2,python_code="def decide(bars,position,parameters):\n    return 'sell' if position['qty']==12 else 'hold'"))
        self.assertEqual(signal(demo_bars('AMD',3),s,True,1,dict(qty=12,basis=1)),'sell')
    def test_no_files_even_after_builtin_escape(self):
        code="def decide(bars,position,parameters):\n    statistics.__builtins__['open']('/etc/passwd').read()\n    return 'buy'"
        with StrategyProcess(code) as p:
            with self.assertRaises(ValueError):p.decide([],{})
    def test_no_process_launch_even_after_import_escape(self):
        code="def decide(bars,position,parameters):\n    os=statistics.__builtins__['__import__']('os')\n    return 'buy' if os.system('true')==0 else 'hold'"
        with StrategyProcess(code) as p:self.assertEqual(p.decide([],{}),'hold')
    def test_no_network_syscall(self):
        code="def decide(bars,position,parameters):\n    ctypes=statistics.__builtins__['__import__']('ctypes')\n    libc=ctypes.CDLL(None)\n    return 'buy' if libc.socket(2,1,0)>=0 else 'hold'"
        with StrategyProcess(code) as p:self.assertEqual(p.decide([],{}),'hold')
    def test_infinite_loop_times_out(self):
        with StrategyProcess("def decide(bars,position,parameters):\n    while True: pass",timeout=.7) as p:
            start=time.monotonic()
            with self.assertRaises(ValueError):p.decide([],{})
            self.assertLess(time.monotonic()-start,4)
    def test_invalid_action_rejected(self):
        with StrategyProcess("def decide(bars,position,parameters):\n    return 'transfer-money'") as p:
            with self.assertRaises(ValueError):p.decide([],{})

class FeeTests(unittest.TestCase):
    def fills(self):return [dict(order_id='b',symbol='NVDA',side='buy',qty=2,price=100,fee=.02),dict(order_id='b',symbol='NVDA',side='buy',qty=3,price=100,fee=.03),dict(order_id='s',symbol='NVDA',side='sell',qty=5,price=110,fee=.055)]
    def test_late_actual_entry_and_exit_fees_recompute_profit(self):
        fees=[normalize(dict(id='one',net_amount='-1',order_id='b')),normalize(dict(id='two',net_amount='-2',order_id='s'))]
        r=reconcile_view(self.fills(),fees,{})
        self.assertEqual([f['fee'] for f in r['trades']],[.4,.6,2]);self.assertAlmostEqual(r['trades'][-1]['net_pnl'],47)
    def test_account_charge_never_silently_attributed(self):
        fee=normalize(dict(id='one',net_amount='-9'))
        r=reconcile_view(self.fills(),[fee],{})
        self.assertEqual(r['allocated_total'],0);self.assertEqual(len(r['unallocated']),1)
        self.assertEqual(reconcile_view(self.fills(),[fee],{'one':'s'})['allocated_total'],9)
    def test_crypto_fee_not_assumed_usd(self):
        f=normalize(dict(id='crypto',activity_type='CFEE',qty='-0.01',currency='BTC'))
        self.assertIsNone(f['amount'])
    def test_csv_repeat_has_stable_identity_and_signed_rebate(self):
        text='date,net_amount,order_id\n2026-01-01,-0.1,b\n2026-01-02,0.05,s\n'
        a=import_csv(text);self.assertEqual(a,import_csv(text));self.assertEqual(a[1]['amount'],-.05)
    def test_nonfinite_fee_rejected(self):
        with self.assertRaises(ValueError):normalize(dict(id='bad',net_amount='NaN'))

class DebateTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.store=Store(Path(self.temp.name)/'state.sqlite')
        self.app=SimpleNamespace(store=self.store,router=Mock(),chat=Mock(),demo=False,config=copy.deepcopy(DEFAULT))
        self.proposal=json.dumps(dict(summary='test',strategy=asdict(Strategy())))
    def tearDown(self):self.store.db.close();self.temp.cleanup()
    def run_debate(self,ready):
        responses=[]
        for r in ready:responses.extend([self.proposal,self.proposal,'Address turnover and uncertainty',json.dumps(dict(index=0,ready=r,reason='test',next_experiment='change lookback'))])
        self.app.router.chat.side_effect=[(x,{}) for x in responses]
        cfg=copy.deepcopy(DEFAULT);cfg['debate_rounds']=len(ready)
        return make_candidates(self.app,'NVDA','j',cfg,{},demo_bars('NVDA',100),60,80)
    def test_revision_rounds_use_distinct_providers(self):
        result=self.run_debate([False,True]);self.assertTrue(result[3]);self.assertEqual(len(result[0]),4)
        calls=self.app.router.chat.call_args_list
        self.assertEqual(len({c.args[0] for c in calls}),4)
        self.assertIn('change lookback',json.dumps(calls[4].args))
    def test_budget_exhaustion_is_not_consensus(self):self.assertFalse(self.run_debate([False])[3])
    def test_duplicate_models_rejected(self):
        cfg=copy.deepcopy(DEFAULT);cfg['models']['critic']=cfg['models']['researcher']
        with self.assertRaises(ValueError):validate_models(cfg)
    def test_conversation_is_persistent(self):
        self.app.router.chat.return_value=('What about turnover?',{})
        discuss(self.app,'NVDA','Try shorter holding periods','j')
        discuss(self.app,'NVDA','Now compare the costs','k')
        self.assertEqual(len(self.store.events('discussion','NVDA')),10)
        self.assertIn('shorter holding',json.dumps(self.app.router.chat.call_args_list[4].args))

class LiveAndLedgerTests(unittest.TestCase):
    def test_official_openbot_agui_client(self):
        from setup_integrations import ROOT,bun_path
        from start_jevie import make_handler
        from http.server import ThreadingHTTPServer
        module=ROOT/'.integrations/openbot/server/node_modules/@ag-ui/client/dist/index.js'
        if not bun_path() or not module.exists():self.skipTest('Install official OpenBot dependencies to run the SDK integration test')
        with tempfile.TemporaryDirectory() as temp:
            a=App(temp,demo=True);server=ThreadingHTTPServer(('127.0.0.1',0),make_handler(a))
            thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
            try:
                code='import {HttpAgent} from '+json.dumps(str(module))+';\n'
                code+='const a=new HttpAgent({url:'+json.dumps(f'http://127.0.0.1:{server.server_port}/api/ag-ui')+',headers:{"x-openbot-agent-token":"fixture-only"},initialMessages:[{id:"message1",role:"user",content:"/help"}]});\n'
                code+='const result=await a.runAgent(); console.log(JSON.stringify(result));'
                with patch.dict(os.environ,{'JEVIE_AGENT_TOKEN':'fixture-only'}):
                    result=subprocess.run([bun_path(),'--eval',code],capture_output=True,text=True,timeout=20)
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertIn('/assignfee',result.stdout)
                self.assertIsNotNone(a.store.get('openbot_last_request'))
            finally:server.shutdown();server.server_close();thread.join();a.close();a.thread.join(2);a.store.db.close()
    def test_env_reaches_order_gate_and_stop_can_exit(self):
        from datetime import datetime,timezone
        with tempfile.TemporaryDirectory() as temp:
            a=App(temp,demo=True);a.stop.set();a.thread.join(2)
            try:
                a.running=True;a.broker=Mock();a.broker.quote.return_value=dict(bp=100,ap=100.1,t=datetime.now(timezone.utc).isoformat())
                a.broker.bars.return_value=demo_bars('NVDA');a.broker.asset.return_value=dict(tradable=True,status='active',fractionable=True)
                a.broker.order.side_effect=lambda order:dict(order,id='order',status='new',filled_qty='0',filled_avg_price='0')
                a.store.put('active:NVDA',dict(strategy=asdict(Strategy()),version='test',timeframe='1Day'))
                answers=battery();answers['quote_environment']['score']=0
                a.workers['NVDA']['battery']=dict(answers=answers,as_of=time.time())
                account=dict(equity=10000,cash=10000)
                with patch('jevie_engine.signal',return_value='buy'):
                    a.tick('NVDA',dict(is_open=True),account,[],[],0)
                    a.broker.order.assert_not_called()
                    answers['quote_environment']['score']=3
                    a.tick('NVDA',dict(is_open=True),account,[],[],0)
                    self.assertEqual(a.broker.order.call_args.args[0]['side'],'buy')
                a.store.put('pending:NVDA',None);a.store.put('position:NVDA',dict(qty=2,basis=200,entry_fees=0))
                answers['quote_environment']['score']=0
                a.tick('NVDA',dict(is_open=True),account,[dict(symbol='NVDA',qty='2',market_value='200')],[],0)
                self.assertEqual(a.broker.order.call_args.args[0]['side'],'sell')
            finally:a.close();a.store.db.close()
    def test_demo_never_calls_hermes(self):
        with tempfile.TemporaryDirectory() as temp:
            a=App(temp,demo=True)
            try:
                with patch('jevie_research.subprocess.run') as run:
                    with self.assertRaises(ValueError):a.research.learn('NVDA',{},'test')
                    run.assert_not_called()
            finally:a.close();a.thread.join(2);a.store.db.close()
    def test_live_has_separate_keys_and_endpoint(self):
        with patch.dict(os.environ,{'JEVIE_ENABLE_LIVE':'I_UNDERSTAND_LIVE_ORDERS','ALPACA_LIVE_API_KEY':'fake-live','ALPACA_LIVE_SECRET_KEY':'fake-secret'},clear=True):
            b=Alpaca(True)
            with patch('jevie_clients.request',return_value={}) as r:
                b.account();self.assertEqual(r.call_args.args[0],'https://api.alpaca.markets/v2/account')
    def test_fee_import_dedup(self):
        with tempfile.TemporaryDirectory() as temp:
            a=App(temp,demo=True)
            try:
                fee=normalize(dict(id='x',net_amount='-1'));a.save_fees([fee]);a.save_fees([fee])
                self.assertEqual(a.fees_view()['reported_total'],1)
                with self.assertRaises(ValueError):a.assign_fee('x','external-order')
            finally:a.close();a.thread.join(2);a.store.db.close()

if __name__=='__main__':unittest.main(verbosity=2)
