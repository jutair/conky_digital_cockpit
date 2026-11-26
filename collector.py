#!/usr/bin/env python3
"""Conky Digital Cockpit: top CPU/RAM/network process collector."""
import os, re, time, signal, shutil, subprocess, tempfile
from pathlib import Path

RUN_DIR = Path('/run/conky-digital-cockpit')
DATA_FILE = RUN_DIR / 'top-processes.tsv'
INTERFACES_FILE = RUN_DIR / 'interfaces.tsv'
NETHOGS = shutil.which('nethogs') or '/usr/sbin/nethogs'
INTERVAL = 1
BATCH = 5
running = True
previous_proc = {}
previous_total = None
VPN_PREFIXES = ('tun', 'tap', 'wg', 'ppp', 'tailscale', 'zt', 'proton', 'mullvad')
VIRTUAL_PREFIXES = ('lo', 'docker', 'veth', 'br-', 'virbr', 'podman', 'cni', 'lxc')

def stop_handler(_sig, _frame):
    global running
    running = False
signal.signal(signal.SIGTERM, stop_handler)
signal.signal(signal.SIGINT, stop_handler)

def atomic_write(path, content):
    RUN_DIR.mkdir(mode=0o755, parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix='cockpit-', dir=str(RUN_DIR), text=True)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f: f.write(content)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)

def command(args):
    try:
        return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL, timeout=3).strip()
    except (OSError, subprocess.SubprocessError):
        return ''

def discover_interfaces():
    found={'ETHERNET': [], 'WIRELESS': [], 'VPN': []}
    root=Path('/sys/class/net')
    if root.exists():
        for item in sorted(root.iterdir()):
            n=item.name; low=n.lower()
            if low == 'lo' or low.startswith(VIRTUAL_PREFIXES): continue
            if low.startswith(VPN_PREFIXES): found['VPN'].append(n)
            elif (item/'wireless').exists(): found['WIRELESS'].append(n)
            elif (item/'device').exists() or low.startswith(('eth','en')): found['ETHERNET'].append(n)
    rows=[]
    for key in ('ETHERNET','WIRELESS','VPN'):
        if found[key]: rows.append(f'{key}|{found[key][0]}')
    atomic_write(INTERFACES_FILE, '\n'.join(rows)+'\n')
    return found

def default_interface(found):
    route=command(['ip','-o','route','get','1.1.1.1'])
    m=re.search(r'\bdev\s+(\S+)',route)
    if m: return m.group(1)
    for category in ('VPN','WIRELESS','ETHERNET'):
        for name in found.get(category,[]):
            try:
                if (Path('/sys/class/net')/name/'operstate').read_text().strip() in ('up','unknown'):
                    return name
            except OSError: pass
    return None

def cpu_total():
    try:
        fields=Path('/proc/stat').read_text().splitlines()[0].split()[1:]
        return sum(map(int,fields[:8]))
    except (OSError,ValueError,IndexError): return None

def read_processes():
    global previous_proc, previous_total
    total=cpu_total(); current={}; rows=[]
    for entry in Path('/proc').iterdir():
        if not entry.name.isdigit(): continue
        pid=int(entry.name)
        try:
            stat=(entry/'stat').read_text(); end=stat.rfind(')')
            if end<0: continue
            name=stat[stat.find('(')+1:end]
            fields=stat[end+2:].split()
            ticks=int(fields[11])+int(fields[12])
            statm=(entry/'statm').read_text().split()
            rss=int(statm[1])*os.sysconf('SC_PAGE_SIZE')/(1024*1024)
            current[pid]=ticks; rows.append((pid,name,ticks,rss))
        except (OSError,IndexError,ValueError): continue
    cpu=[]
    if total is not None and previous_total is not None:
        delta=total-previous_total
        if delta>0:
            for pid,name,ticks,_rss in rows:
                old=previous_proc.get(pid)
                if old is not None: cpu.append((pid,name,max(0.0,(ticks-old)*100.0/delta)))
    previous_proc=current; previous_total=total
    cpu.sort(key=lambda r:r[2],reverse=True)
    ram=sorted(rows,key=lambda r:r[3],reverse=True)
    return cpu[:3],[(p,n,r) for p,n,_t,r in ram[:3]]

def parse_nethogs(line, rows):
    parts=line.rstrip('\n').split('\t')
    if len(parts)<3: return
    m=re.match(r'^(.*)/(\d+)/(\d+)$',parts[0].strip())
    if not m: return
    program,pid_s,_uid=m.groups()
    try:
        pid=int(pid_s)
        sent=float(parts[1].strip().replace(',','.').split()[0])
        received=float(parts[2].strip().replace(',','.').split()[0])
    except (ValueError,IndexError): return
    name=os.path.basename(program.rstrip('/')) or program or 'process'
    rows[pid]=(name,sent,received)

def clean(s): return str(s).replace('|','_').replace('\t',' ').replace('\n',' ')

def publish(net):
    cpu,ram=read_processes(); ranked=sorted(net.items(),key=lambda x:x[1][1]+x[1][2],reverse=True)[:3]
    lines=[]
    for pid,name,val in cpu: lines.append(f'CPU|{pid}|{clean(name)}|{val:.2f}|')
    for pid,name,val in ram: lines.append(f'RAM|{pid}|{clean(name)}|{val:.2f}|')
    for pid,(name,sent,received) in ranked: lines.append(f'NET|{pid}|{clean(name)}|{sent:.3f}|{received:.3f}')
    atomic_write(DATA_FILE,'\n'.join(lines)+'\n')

def run_nethogs(iface):
    # -v 0 = KB/s; each refresh block is a new sample, not an accumulated total.
    cmd=[NETHOGS,'-t','-d',str(INTERVAL),'-v','0','-c',str(BATCH),'-l',iface]
    try: p=subprocess.Popen(cmd,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,bufsize=1)
    except OSError: time.sleep(2); return
    net={}; started=False
    try:
        assert p.stdout is not None
        for line in p.stdout:
            if not running: break
            if line.strip().startswith('Refreshing:'):
                if started: publish(net); net={}
                started=True
            else: parse_nethogs(line,net)
    finally:
        if started: publish(net)
        try: p.terminate(); p.wait(timeout=2)
        except Exception:
            try: p.kill()
            except Exception: pass

def run():
    if not Path(NETHOGS).exists(): raise SystemExit('NetHogs não encontrado; instale o pacote nethogs.')
    RUN_DIR.mkdir(mode=0o755,parents=True,exist_ok=True)
    while running:
        found=discover_interfaces(); iface=default_interface(found)
        if iface: run_nethogs(iface)
        else: publish({}); time.sleep(3)

if __name__=='__main__': run()
