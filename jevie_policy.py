"""Code-owned seven-answer policy, based on the supplied jev-loop thresholds.

This stock strategy runner is long/flat: QUOTE_WIDE means reduced entry size,
not a claim that it posts two-sided market-making quotes.
"""
from jevie_core import battery_validate

def compose_policy(answers,qty=0):
    a=battery_validate(answers); reasons=[];scale=1.;entry=True;reduce=False;kind='FULL_ENTRY'
    env=a['quote_environment'];tox=a['toxic_flow']['noul'];liq=a['liquidity_stressed']['noul']
    regime=a['regime'];direction=a['direction'];inv=a['inventory_pressure'];health=a['execution_health']
    if tox>.6:entry=False;kind='PULL_ENTRIES';reasons.append('TOX above 0.60')
    if liq>.7:entry=False;kind='LIQUIDITY_STRESS';reasons.append('Liquidity stress above 0.70')
    if env['score']<1 or env['confidence']<.5:
        entry=False;kind='STAND_DOWN';reasons.append('ENV below 1 or confidence below 0.50')
    elif not (env['score']>=2 and env['confidence']>.8):
        scale*=.5;reasons.append('Marginal ENV: half-size ceiling')
    if regime['choice']=='crisis' and regime['confidence']>=.6:
        entry=False;kind='CRISIS';reduce=bool(qty and regime['confidence']>=.8);reasons.append('Crisis regime')
    elif regime['choice']=='high_vol':scale*=.5;reasons.append('High-volatility size reduction')
    if direction['choice']=='down' and direction['confidence']>.55:
        entry=False;reasons.append('Confident downward bias')
    if qty and inv['score']>=2.5 and inv['confidence']>=.6:
        reduce=True;entry=False;kind='REDUCE_INVENTORY';reasons.append('Urgent inventory pressure')
    if health['score']<1:
        entry=False;kind='EXECUTION_DEGRADED';reasons.append('Execution health below 1')
    elif health['score']<2 or health['confidence']<.5:
        scale*=.5;reasons.append('Execution health size reduction')
    if entry and scale<1:kind='REDUCED_ENTRY'
    if not reasons:reasons=['All seven judgments permit normal strategy evaluation']
    return dict(kind=kind,allow_entry=entry,size_scale=scale if entry else 0.,reduce_inventory=reduce,
                cancel_entries=not entry,reason='; '.join(reasons))
