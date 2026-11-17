"""A parson's steering mix: a linear combination of neuron recipes, kept beside its thotz.

    0.7 sunny + 0.4 archaic-english - 2 L32E480N478

A term is a weight and either a recipe from the catalog (steer/recipes/flash-next.jsonl, by id or name; the weight
multiplies the recipe's doses) or a raw neuron (steer.py's short code without a dose; the weight is the dose).
Everything is summed per neuron.  The text is stored as written in ROOT/thotz/<2 hex>/<nom>.mix and expanded on every
model call made as that parson (steer_field); the hot-swap llama-server applies it for that request only.

Private like thotz: only the nom itself reads or sets it (social.op_set_mix), except that whoever breads a kid may
write the kid's first one.  A kid born without one gets "~ 0.5 @ma + 0.5 @pa" from peaple.pl: on first use that is
frozen into half of each parent's mix as it then stands, plus (the "~") sometimes a small random recipe.

Limits (LIMITS): terms, weight per recipe, dose per neuron, and total load, where one load is a dose of 6 on one
neuron.  A saved mix that breaks them is refused; an inherited one is scaled down to fit.
"""
import hashlib, json, os, random, re, sys, urllib.request

ROOT = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(ROOT, 'steer'))
import steer

MIX_MAX = 400                      # characters
LIMITS = {'terms': 8, 'weight': 1.0, 'dose': 12.0, 'load': 3.0}
LOAD_DOSE = 6.0
MUTATE_P, MUTATE_W = 0.5, 0.3      # an inherited mix gains one random recipe at this weight, this often
TOOL_GAIN_DEFAULT, TOOL_GAIN_FLOOR, TOOL_DOSE_DEFAULT = 0.3, 0.15, 1.5      # caps while tools are in play (see expand)
TERM = re.compile(r'\s*([+-])?\s*(\d+(?:\.\d+)?|\.\d+)?\s*\*?\s*(@[A-Za-z0-9_]+|[A-Za-z][A-Za-z0-9_-]*)')
NEURON = re.compile(r'^L(\d+)(?:E(\d+)|(S))?N(\d+)$')

class MixError(ValueError):
    pass

def path(nom):
    return os.path.join(ROOT, 'thotz', hashlib.sha256(nom.encode('utf-8')).hexdigest()[:2], nom + '.mix')

NONE = '-'      # file content of a parson that chose to have no steering (a missing file means: not born yet, see _born)

def _raw(nom):
    try:
        with open(path(nom), encoding='utf-8', errors='replace') as f:
            return f.read(4 * MIX_MAX).strip()[:MIX_MAX]
    except OSError:
        return None

def read(nom):
    t = _raw(nom)
    return '' if t is None or t == NONE else t

def write(nom, text):
    p = path(nom)
    text = text.strip() or NONE
    os.makedirs(os.path.dirname(p), exist_ok=True)
    tmp = '%s.%d.tmp' % (p, os.getpid())
    with open(tmp, 'w', encoding='utf-8') as f:
        f.write(text.strip() + '\n')
    os.replace(tmp, p)

_cat = {'mtime': None, 'recipes': [], 'by': {}, 'units': None}
def catalog():
    """Recipes usable in a mix (reloaded when the file changes: the campaign appends to it)."""
    try:
        m = os.path.getmtime(steer.FLASH)
    except OSError:
        return _cat
    if m != _cat['mtime']:
        rs = [r for r in steer.load() if r.get('status') in ('verified', 'found', 'weak', 'ported')]
        by = {}
        for r in rs:
            by[r['id'].lower()] = r
            by.setdefault(re.sub(r'[^a-z0-9]+', '-', r['name'].lower()).strip('-'), r)
        _cat.update(mtime=m, recipes=rs, by=by, units=steer.units())
    return _cat

def public_catalog():
    return [{'id': r['id'], 'name': r['name'], 'effect': r.get('effect') or '', 'code': r['code'], 'category': r.get('category') or '',
             'source': (r.get('origin') or {}).get('source', '')} for r in catalog()['recipes']]

def terms(text):
    """'0.7 sunny - 2 L32E480N478' -> [(0.7, 'sunny'), (-2.0, 'L32E480N478')].  A leading '~' is the mutate mark."""
    text = text.strip().lstrip('~').strip()
    out, pos = [], 0
    while pos < len(text):
        m = TERM.match(text, pos)
        if not m or (out and not m.group(1)):
            raise MixError('cannot read the mix near "%s"; write it like: 0.7 sunny + 0.4 archaic-english - 2 L32E480N478' % text[pos:pos + 24].strip())
        w = float(m.group(2)) if m.group(2) else 1.0
        out.append((-w if m.group(1) == '-' else w, m.group(3)))
        pos = m.end()
        if not text[pos:].strip():
            break
    return out

def fmt(ts):
    s = ''
    for i, (w, name) in enumerate(ts):
        s += ('- ' if w < 0 else '+ ' if i else '') + ('%g ' % abs(w)) + name + ' '
    return s.strip()

def expand(ts, strict=True, full=False):
    """Terms -> pushes [{layer, expert, neuron, dose}], summed per neuron.  strict: raise on anything out of bounds;
    otherwise drop what is unknown and scale down what is too much.

    Catalog doses are tool-calibrated (steer/calibrate.py): at weight 1 a recipe is as strong as it can be while the
    parson still uses its tools when asked.  A recipe not calibrated yet is held to its measured tool_gain, or to
    TOOL_GAIN_DEFAULT, and a raw neuron to a dose of TOOL_DOSE_DEFAULT.  full: the originally published doses instead,
    with no such limits, for calls that offer no tools (botloop.voice)."""
    cat = catalog()
    if len(ts) > LIMITS['terms']:
        if strict:
            raise MixError('at most %d terms' % LIMITS['terms'])
        ts = ts[:LIMITS['terms']]
    if not full:
        # Each calibrated recipe at weight 1 already uses up what tool use can bear, so several together share that
        # budget: when the weights add up to more than 1 they are scaled down in proportion.
        total = sum(abs(w) / (TOOL_DOSE_DEFAULT if NEURON.match(name) else 1.0) for w, name in ts)
        if total > 1.0:
            ts = [(w / total, name) for w, name in ts]
    acc = {}
    for w, name in ts:
        m = NEURON.match(name)
        if m:
            layer = int(m.group(1))
            if layer not in cat['units'] or layer < 1:
                if strict:
                    raise MixError('no such layer: %s' % name)
                continue
            key = (layer, int(m.group(2)) if m.group(2) else 'shared' if m.group(3) else None, int(m.group(4)))
            if key[1] is None or key[2] >= 640 or (isinstance(key[1], int) and key[1] >= 512):
                if strict:
                    raise MixError('no such neuron: %s (write L<layer>E<expert 0-511>N<neuron 0-639>, or S for the shared expert)' % name)
                continue
            if not full and abs(w) > TOOL_DOSE_DEFAULT:
                w = TOOL_DOSE_DEFAULT * (1 if w > 0 else -1)
            acc[key] = acc.get(key, 0.0) + w
            continue
        r = cat['by'].get(name.lower()) or cat['by'].get(re.sub(r'[^a-z0-9]+', '-', name.lower()).strip('-'))
        if not r:
            if strict:
                raise MixError('no recipe called "%s"' % name)
            continue
        if abs(w) > LIMITS['weight']:
            if strict:
                raise MixError('the weight of a recipe can be at most %g (1 is the most it can carry and still use its tools)' % LIMITS['weight'])
            w = LIMITS['weight'] * (1 if w > 0 else -1)
        ps = r['pushes']
        if 'published' in r:                  # calibrated: pushes are the tool-safe doses
            if full:
                ps = r['published']['pushes']
        elif not full:                        # not calibrated yet: hold the weight down instead
            cap = r.get('tool_gain', TOOL_GAIN_DEFAULT) or TOOL_GAIN_FLOOR
            if abs(w) > cap:
                w = cap * (1 if w > 0 else -1)
        for p in ps:
            key = (p['layer'], p['expert'], p['neuron'])
            acc[key] = acc.get(key, 0.0) + w * p['dose']
    acc = {k: d for k, d in acc.items() if abs(d) > 1e-6}
    top = max([abs(d) for d in acc.values()] or [0])
    load = sum(abs(d) for d in acc.values()) / LOAD_DOSE
    if strict:
        if top > LIMITS['dose']:
            raise MixError('too strong: one neuron would get a dose of %.1f (at most %g)' % (top, LIMITS['dose']))
        if load > LIMITS['load']:
            raise MixError('too much in total: %.1f loads (at most %g; sunny at full weight is 1.5)' % (load, LIMITS['load']))
    else:
        k = min(1.0, LIMITS['dose'] / top if top else 1.0, LIMITS['load'] / load if load else 1.0)
        acc = {key: d * k for key, d in acc.items()}
    return [{'layer': l, 'expert': e, 'neuron': n, 'dose': round(d, 3)} for (l, e, n), d in sorted(acc.items(), key=lambda kv: str(kv[0]))]

def _freeze(nom, text, depth=0):
    """Turn an inherited mix ('~ 0.5 @ma + 0.5 @pa') into plain terms and save it."""
    try:
        ts = terms(text)
    except MixError:
        return ''
    out = []
    for w, name in ts:
        if not name.startswith('@'):
            out.append((w, name)); continue
        other = name[1:]
        if other == nom or depth > 2:
            continue
        for w2, n2 in _terms_of(other, depth + 1):
            out.append((round(w * w2, 3), n2))
    merged = {}
    for w, name in out:
        merged[name] = merged.get(name, 0.0) + w
    out = [(round(w, 3), n) for n, w in merged.items() if abs(w) >= 0.05]
    if text.lstrip().startswith('~') and random.random() < MUTATE_P:
        pool = [r for r in catalog()['recipes'] if r['id'] not in merged]
        if pool:
            out.append((MUTATE_W, random.choice(pool)['id']))
    out = sorted(out, key=lambda t: -abs(t[0]))[:LIMITS['terms']]
    frozen = fmt(out)
    write(nom, frozen)
    return frozen

def _born(nom):
    """Every parson starts with a random mix of one or two recipes, drawn the first time it speaks and then kept."""
    ids = [r['id'] for r in catalog()['recipes']]
    rnd = random.Random()
    for _ in range(6):
        if not ids:
            break
        if rnd.random() < 0.6 or len(ids) < 2:
            ts = [(round(rnd.uniform(0.6, 1.0), 1), rnd.choice(ids))]
        else:
            a, b = rnd.sample(ids, 2)
            ts = [(round(rnd.uniform(0.5, 0.8), 1), a), (round(rnd.uniform(0.4, 0.7), 1) * rnd.choice((1, 1, 1, -1)), b)]
        try:
            if expand(ts, strict=True):
                write(nom, fmt(ts))
                return fmt(ts)
        except MixError:
            pass
    write(nom, '')
    return ''

def _terms_of(nom, depth=0):
    text = _raw(nom)
    if text is None:
        text = _born(nom) if depth == 0 else ''
    elif text == NONE:
        text = ''
    if '@' in text or text.startswith('~'):
        text = _freeze(nom, text, depth)
    try:
        return terms(text) if text else []
    except MixError:
        return []

def text_of(nom):
    """The parson's mix as text (freezing an inherited one first)."""
    return fmt(_terms_of(nom))

def pushes(nom, full=False):
    ts = _terms_of(nom)
    return expand(ts, strict=False, full=full) if ts else []

def steer_field(nom, gain=1.0, full=False):
    """The 'steer' field for a model call made as this parson (at `gain` of its mix), or None.  full: published
    doses, for calls that offer no tools."""
    try:
        p = pushes(nom, full)
        return steer.request(p, gain, unit=catalog()['units']) if p else None
    except Exception:
        return None

def check(text):
    """Validate a mix someone wants to save: returns (canonical text, pushes); raises MixError."""
    text = (text or '').strip()
    if not text:
        return '', []
    if len(text) > MIX_MAX:
        raise MixError('at most %d characters' % MIX_MAX)
    if '@' in text or '~' in text:
        raise MixError('a mix is made of recipes and neurons only')
    ts = terms(text)
    return fmt(ts), expand(ts, strict=True, full=True)      # limits are checked at the strongest the mix is ever applied

_prefix = {}
def steer_from(host, system, tools):
    """How many prompt tokens the system message and the tool definitions take: the "steer_from" of a request, so that
    part is read unsteered (and stays cached in the model server across parsons' different steering).  0 on failure."""
    key = hashlib.sha256((system + json.dumps(tools, sort_keys=True)).encode()).hexdigest()
    if key not in _prefix:
        try:
            def post(path, body):
                req = urllib.request.Request('http://%s%s' % (host, path), json.dumps(body).encode(), {'Content-Type': 'application/json'})
                return json.load(urllib.request.urlopen(req, timeout=20))
            p = post('/apply-template', {'messages': [{'role': 'system', 'content': system}, {'role': 'user', 'content': 'x'}],
                                         **({'tools': tools} if tools else {}), 'chat_template_kwargs': {'enable_thinking': False}})['prompt']
            n = len(post('/tokenize', {'content': p[:p.rindex('<|im_start|>user')], 'add_special': True, 'parse_special': True})['tokens'])
            if len(_prefix) > 500:
                _prefix.clear()
            _prefix[key] = n
        except Exception:
            return 0
    return _prefix[key]

_words = lambda s: re.findall(r"[a-z']+", s.lower())
def broken(s):
    """Is this reply degenerate (empty, looping, or symbol soup)?"""
    w = _words(s)
    if len(w) < 4:
        return True
    if len(w) >= 12 and len(set(w)) / len(w) < 0.5:
        return True
    return sum(c.isalpha() and ord(c) < 128 for c in s) < 0.5 * len(s)

if __name__ == '__main__':
    for a in sys.argv[1:]:
        print(a, '|', text_of(a), '|', steer.code(pushes(a)))
