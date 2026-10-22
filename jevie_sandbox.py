"""Credential-free process boundary for model-written strategy mathematics."""
import ast,ctypes.util,json,os,queue,shutil,subprocess,sys,threading
from pathlib import Path

def validate_source(code):
    if not isinstance(code,str) or not 1<=len(code)<=24000:raise ValueError('Python strategy source must be 1–24,000 characters')
    tree=ast.parse(code)
    if not any(isinstance(n,ast.FunctionDef) and n.name=='decide' for n in tree.body):raise ValueError('Define decide(bars, position, parameters)')
    if len(list(ast.walk(tree)))>6000:raise ValueError('Strategy source is too large')
    return code

def available():return (sys.platform.startswith('linux') and bool(ctypes.util.find_library('seccomp'))) or bool(shutil.which('docker'))

class StrategyProcess:
    def __init__(self,code,parameters=None,timeout=2):
        validate_source(code);self.timeout=timeout;self.q=queue.Queue(maxsize=10)
        worker=str(Path(__file__).with_name('strategy_worker.py').resolve())
        if sys.platform.startswith('linux') and ctypes.util.find_library('seccomp'):
            cmd=[sys.executable,'-I','-S',worker]
        elif shutil.which('docker'):
            cmd=['docker','run','--rm','-i','--network','none','--read-only','--cap-drop=ALL','--security-opt','no-new-privileges',
                 '--pids-limit','16','--memory','256m','--cpus','1','--user','65534:65534','--mount',f'type=bind,src={worker},dst=/worker.py,readonly',
                 'python:3.12-slim','python','-I','-S','/worker.py','--docker']
        else:raise ValueError('Custom Python needs Linux libseccomp or Docker; execution is refused without isolation')
        self.p=subprocess.Popen(cmd,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,bufsize=1,
                                env={} if sys.platform.startswith('linux') else {'SYSTEMROOT':os.environ.get('SYSTEMROOT','')})
        def read():
            while True:
                try:line=self.p.stdout.readline(65537)
                except (OSError,ValueError):return
                try:self.q.put_nowait(line)
                except queue.Full:self.p.kill();return
                if not line:return
        threading.Thread(target=read,daemon=True).start()
        try:
            self._write({'code':code,'parameters':parameters or {}})
            if self._read().get('ready') is not True:raise ValueError('Sandbox did not initialize')
        except BaseException:self.close();raise
    def _write(self,value):
        raw=json.dumps(value,allow_nan=False)+'\n';errors=[]
        def write():
            try:self.p.stdin.write(raw);self.p.stdin.flush()
            except (BrokenPipeError,OSError,ValueError) as e:errors.append(e)
        writer=threading.Thread(target=write,daemon=True);writer.start();writer.join(self.timeout)
        if writer.is_alive():
            self.p.kill();writer.join(2);self.close()
            raise ValueError('Strategy sandbox exceeded its input time limit')
        if errors:raise ValueError('Sandbox terminated or refused the strategy') from None
    def _read(self):
        try:line=self.q.get(timeout=self.timeout)
        except queue.Empty:self.close();raise ValueError('Strategy sandbox exceeded its time limit') from None
        if not line or len(line)>65536:raise ValueError('Strategy sandbox failed or produced excessive output')
        try:return json.loads(line)
        except ValueError:raise ValueError('Strategy returned invalid output') from None
    def decide(self,bars,position):
        self._write({'bars':bars[-2000:],'position':position});r=self._read();action=r.get('action')
        if action not in ('buy','sell','hold'):raise ValueError('Invalid sandbox action')
        return action
    def close(self):
        if getattr(self,'p',None):
            if self.p.poll() is None:self.p.kill()
            self.p.wait(timeout=5)
            for pipe in (self.p.stdin,self.p.stdout):
                if pipe:pipe.close()
    def __enter__(self):return self
    def __exit__(self,*exc):self.close()
