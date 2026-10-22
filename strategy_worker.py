"""Isolated free-form strategy worker. Never run this inside the application process."""
import builtins,ctypes,json,math,os,resource,statistics,sys

def restrict():
    resource.setrlimit(resource.RLIMIT_AS,(256*1024*1024,256*1024*1024))
    resource.setrlimit(resource.RLIMIT_CPU,(20,20))
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    resource.setrlimit(resource.RLIMIT_FSIZE,(0,0))
    # All code is loaded before this point. No file opens, network, fork, exec,
    # ptrace, process signalling, mounts or privilege changes are permitted.
    libc=ctypes.CDLL('libc.so.6',use_errno=True)
    if libc.prctl(38,1,0,0,0)!=0:raise RuntimeError('Cannot enable no-new-privileges')
    lib=ctypes.CDLL('libseccomp.so.2',use_errno=True)
    lib.seccomp_init.restype=ctypes.c_void_p
    lib.seccomp_rule_add.argtypes=[ctypes.c_void_p,ctypes.c_uint32,ctypes.c_int,ctypes.c_uint]
    lib.seccomp_load.argtypes=[ctypes.c_void_p];lib.seccomp_release.argtypes=[ctypes.c_void_p]
    ctx=lib.seccomp_init(0x00050000|1) # default EPERM
    if not ctx:raise RuntimeError('Cannot construct syscall filter')
    for name in ('read','write','close','exit','exit_group','brk','mmap','mprotect','munmap','mremap',
                 'rt_sigaction','rt_sigprocmask','rt_sigreturn','futex','getpid','gettid','getrandom','clock_gettime','getrusage','sched_yield','sigaltstack'):
        nr=lib.seccomp_syscall_resolve_name(name.encode())
        if nr>=0 and lib.seccomp_rule_add(ctx,0x7fff0000,nr,0)!=0:raise RuntimeError('Cannot configure syscall filter')
    if lib.seccomp_load(ctx)!=0:raise RuntimeError('Cannot load syscall filter')
    lib.seccomp_release(ctx)

def main():
    init=json.loads(sys.stdin.readline(100000));source=init['code'];params=init.get('parameters',{})
    compiled=compile(source,'<strategy>','exec')
    if '--docker' not in sys.argv:restrict()
    else:
        resource.setrlimit(resource.RLIMIT_CPU,(20,20));resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    safe={k:getattr(builtins,k) for k in ('abs','all','any','bool','dict','enumerate','float','int','isinstance','len','list','map','max','min','range','reversed','round','set','sorted','str','sum','tuple','zip','Exception','ValueError')}
    print(json.dumps({'ready':True}),flush=True)
    for line in sys.stdin:
        # Live decisions and backtests both start with fresh strategy globals.
        namespace={'__builtins__':dict(safe),'math':math,'statistics':statistics}
        exec(compiled,namespace)
        fn=namespace.get('decide')
        if not callable(fn):raise ValueError('Strategy must define decide(bars, position, parameters)')
        request=json.loads(line);result=fn(request['bars'],request['position'],json.loads(json.dumps(params)))
        action=result.get('action') if isinstance(result,dict) else result
        if action not in ('buy','sell','hold'):raise ValueError('Invalid action')
        print(json.dumps({'action':action}),flush=True)
if __name__=='__main__':main()
