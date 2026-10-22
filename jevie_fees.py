"""Broker fee records, explicit attribution and retrospectively corrected P/L."""
import csv,hashlib,io,json,math

def normalize(record):
    if record.get('activity_type','FEE') not in ('FEE','CFEE'):return None
    if record.get('status','executed') not in ('executed','complete'):return None
    currency=record.get('currency','USD')
    amount=float(record.get('net_amount') or 0)
    if not math.isfinite(amount):raise ValueError('Fee amount must be finite')
    # A non-dollar crypto fee cannot be priced as USD without a conversion record.
    if currency!='USD' or (record.get('activity_type')=='CFEE' and float(record.get('qty') or 0)!=0 and amount==0):
        return dict(id=str(record['id']),amount=None,currency=currency,date=record.get('date',''),symbol=record.get('symbol',''),order_id=record.get('order_id',''),description='Non-USD fee requires a USD statement conversion')
    return dict(id=str(record['id']),amount=-amount,currency='USD',date=record.get('date',record.get('transaction_time','')),
                symbol=record.get('symbol',''),order_id=record.get('order_id',''),description=str(record.get('description',''))[:500])

def import_csv(text):
    rows=[]
    for r in csv.DictReader(io.StringIO(text)):
        if len(rows)>=2000:raise ValueError('Import at most 2,000 fee records')
        if 'net_amount' not in r:raise ValueError('CSV needs net_amount (negative for a charge), plus date and optional id, order_id, symbol, activity_type')
        r['id']=r.get('id') or 'statement-'+hashlib.sha256(json.dumps(r,sort_keys=True).encode()).hexdigest()[:24]
        fee=normalize(r)
        if fee:rows.append(fee)
    return rows

def reconcile_view(fills,fees,links):
    totals={};qty_totals={};known={x['order_id'] for x in fills};allocated=[];unallocated=[]
    for f in fills:qty_totals[f['order_id']]=qty_totals.get(f['order_id'],0)+f['qty']
    for fee in fees:
        oid=links.get(fee['id']) or fee.get('order_id')
        if oid in known and fee.get('amount') is not None:
            totals[oid]=totals.get(oid,0)+fee['amount'];allocated.append(fee)
        else:unallocated.append(fee)
    positions={};rows=[]
    for original in fills:
        f=dict(original);oid=f['order_id'];symbol=f['symbol'];q=f['qty'];price=f['price']
        f['estimated_fee']=f['fee']
        if oid in totals:f['fee']=totals[oid]*q/qty_totals[oid];f['fee_source']='broker-reported'
        p=positions.setdefault(symbol,dict(qty=0,basis=0,fees=0))
        if f['side']=='buy':
            p['basis']=(p['basis']*p['qty']+price*q)/(p['qty']+q);p['qty']+=q;p['fees']+=f['fee']
        else:
            used=min(q,p['qty']);cost=p['fees']*used/p['qty'] if p['qty'] else 0
            f['gross_pnl']=(price-p['basis'])*used;f['net_pnl']=f['gross_pnl']-cost-f['fee']
            p['qty']-=used;p['fees']-=cost
        rows.append(f)
    return dict(trades=rows,reported_total=sum(f['amount'] for f in fees if f.get('amount') is not None),
                allocated_total=sum(f['amount'] for f in allocated),unallocated=unallocated,
                note='Reported fees may arrive late. Unallocated account fees are not silently charged to a ticker. Remaining rows use estimates.')
