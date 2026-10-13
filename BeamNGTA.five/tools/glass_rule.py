import re, sys, glob, collections

def parse(text):
    text = re.sub(r'//[^\n]*', '', text); text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    tok = re.findall(r'"(?:\\.|[^"\\])*"|[\[\]{}]|[-+]?\d[\d.eE+-]*|[A-Za-z_$][\w$]*', text)
    pos = 0
    def val():
        nonlocal pos
        t = tok[pos]; pos += 1
        if t == '[':
            a = []
            while tok[pos] != ']': a.append(val())
            pos += 1; return a
        if t == '{':
            d = {}
            while tok[pos] != '}':
                k = val(); d[k] = val()
            pos += 1; return d
        if t[0] == '"': return t[1:-1]
        if t in ('true', 'false', 'null'): return {'true': True, 'false': False, 'null': None}[t]
        try: return float(t)
        except ValueError: return t
    return val()

def rows(section):
    opt = {}
    for r in section[1:]:
        if isinstance(r, dict): opt.update(r)
        elif isinstance(r, list):
            o = dict(opt)
            if r and isinstance(r[-1], dict): o.update(r[-1]); r = r[:-1]
            yield r, o

def glassy(name):
    n = name.lower().replace('backlight', 'rearwindow')
    if any(k in n for k in ('light', 'lamp', 'signal', 'mirror', 'flasher', 'beacon')): return False
    return any(k in n for k in ('glass', 'windshield', 'window', 'sunroof'))

partNodes = collections.defaultdict(set); ends = collections.defaultdict(set); carrier = collections.defaultdict(set); tris = []
for f in sorted(glob.glob(sys.argv[1] + '/*.jbeam')):
    try: data = parse(open(f, encoding='utf-8', errors='replace').read())
    except Exception as e: print('could not read', f, e); continue
    for part, p in data.items():
        if not isinstance(p, dict): continue
        for r, o in rows(p.get('flexbodies', [[]])):
            g = o.get('deformGroup')
            if g and r and isinstance(r[0], str) and glassy(g + ' ' + r[0]): carrier[g].add(part)
        for r, o in rows(p.get('nodes', [[]])):
            if r: partNodes[part].add(r[0])
        for r, o in rows(p.get('beams', [[]])):
            g = o.get('deformGroup')
            if g and len(r) >= 2:
                for gg in (g if isinstance(g, list) else [g]): ends[gg].update(r[:2])
        for r, o in rows(p.get('triangles', [[]])):
            if len(r) >= 3: tris.append((part, tuple(r[:3])))
for g in sorted(carrier):
    own = set().union(*(partNodes[p] for p in carrier[g])) & ends[g]
    corners = own if len(own) >= 3 else ends[g]
    hit = sorted({(p, t) for p, t in tris if all(n in corners for n in t)})
    print(g, sorted(carrier[g]), '-', len(corners), 'corners,', len({t for p, t in hit}), 'triangles')
    for p, t in hit: print('     ', p, t)
