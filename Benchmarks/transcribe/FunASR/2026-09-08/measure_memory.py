import ctypes
import json
import pathlib
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).parent
FIELDS = '''user_time system_time pkg_idle_wkups interrupt_wkups pageins wired_size resident_size phys_footprint proc_start_abstime proc_exit_abstime child_user_time child_system_time child_pkg_idle_wkups child_interrupt_wkups child_pageins child_elapsed_abstime diskio_bytesread diskio_byteswritten cpu_time_qos_default cpu_time_qos_maintenance cpu_time_qos_background cpu_time_qos_utility cpu_time_qos_legacy cpu_time_qos_user_initiated cpu_time_qos_user_interactive billed_system_time serviced_system_time logical_writes lifetime_max_phys_footprint instructions cycles billed_energy serviced_energy interval_max_phys_footprint runnable_time'''.split()
class Usage(ctypes.Structure):
    _fields_ = [('uuid', ctypes.c_uint8*16)] + [(n, ctypes.c_uint64) for n in FIELDS]
lib = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
lib.proc_pid_rusage.restype = ctypes.c_int

def measure(pid):
    result = Usage()
    if lib.proc_pid_rusage(pid, 4, ctypes.byref(result)) != 0:
        raise OSError(ctypes.get_errno(), 'proc_pid_rusage')
    return {k:getattr(result,k) for k in ('resident_size','phys_footprint','lifetime_max_phys_footprint')}

if __name__=='__main__':
    needle, output = sys.argv[1:]
    rows=[]
    deadline=time.monotonic()+180
    seen=False
    while time.monotonic()<deadline:
        lines=subprocess.check_output(['ps','-axo','pid=,command='],text=True).splitlines()
        pids=[int(s.strip().split(None,1)[0]) for s in lines if needle in s and 'measure_memory.py' not in s and not s.strip().split(None,1)[1].startswith(('/bin/zsh','/bin/bash'))]
        if not pids:
            if seen: break
            time.sleep(0.25); continue
        seen=True
        for pid in pids:
            try: rows.append({'pid':pid,'time':time.time(),**measure(pid)})
            except OSError: pass
        (ROOT/output).write_text(json.dumps(rows,indent=2))
        time.sleep(0.25)
    if rows: print('MEMORY',output,max(r['lifetime_max_phys_footprint'] for r in rows)/2**30,'GiB')
