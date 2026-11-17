"""Steering recipes for the peaple chat model, and the request field that applies them.

A recipe is a list of pushes.  A push adds one neuron's output direction to the feed-forward output of one layer, at
every token, for one request.  Recipes are written in dose units: dose 1 on layer L adds a vector as long as the median
residual leaving layer L (units.json, measured by resid_norms on calib.txt).  The hot-swap llama-server (~/llama.cpp,
branch hotswap) takes the pushes per request in a "steer" field, in absolute scale; request() converts.

Short code for a recipe:  L20E344N557+9 L44SN136+0.25
    L<layer> E<routed expert> | S (shared expert) | nothing (dense FFN)  N<neuron>  <signed dose>

Files:  recipes/flash-next.jsonl   recipes for the model peaple runs (Qwen3.8-Flash-Next), one JSON object per line
        recipes/other-models.jsonl recipes published for other models, kept for reference; they do not apply here
        units.json                 dose unit per layer of flash-next

Recipe fields: id, name, model, code, pushes [{layer, expert, neuron, dose}], effect, tags, status, origin, notes.
status: ported (copied, untested here) | verified (effect seen here) | weak (some change, not the described effect)
        | dead (no visible effect) | broken (output degenerates) | found (discovered by our own campaign)
"""
import json, os, re, sys, time, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
FLASH = os.path.join(HERE, 'recipes', 'flash-next.jsonl')
PUSH = re.compile(r'^L(\d+)(?:E(\d+)|(S))?N(\d+)([+-]\d+(?:\.\d+)?)$')

def units(path=os.path.join(HERE, 'units.json')):
    return {int(k): v['unit'] for k, v in json.load(open(path)).items()}

def parse(code):
    """'L20E344N557+9 L44SN136+0.25' -> pushes.  expert is a number, 'shared', or None (dense FFN)."""
    out = []
    for part in code.split():
        m = PUSH.match(part)
        if not m:
            raise ValueError('bad push %r' % part)
        out.append({'layer': int(m.group(1)), 'expert': int(m.group(2)) if m.group(2) else ('shared' if m.group(3) else None),
                    'neuron': int(m.group(4)), 'dose': float(m.group(5))})
    return out

def code(pushes):
    def one(p):
        e = p.get('expert')
        return 'L%d%sN%d%+g' % (p['layer'], 'S' if e == 'shared' else '' if e is None else 'E%d' % e, p['neuron'], p['dose'])
    return ' '.join(one(p) for p in pushes)

def load(path=FLASH):
    if not os.path.exists(path):
        return []
    return [json.loads(l) for l in open(path) if l.strip()]

def save(recipes, path=FLASH):
    tmp = path + '.tmp'
    with open(tmp, 'w') as f:
        for r in recipes:
            f.write(json.dumps(r, ensure_ascii=False) + '\n')
    os.replace(tmp, path)

def find(key, recipes=None):
    """A recipe by id or name; a short code is parsed as an unnamed recipe."""
    for r in (recipes if recipes is not None else load()):
        if key in (r['id'], r['name']):
            return r
    return {'id': key, 'name': key, 'pushes': parse(key)}

def request(pushes, gain=1.0, unit=None):
    """The 'steer' field of a completion request: doses turned into absolute scale."""
    unit = unit or units()
    return [{'layer': p['layer'], 'neuron': p['neuron'], 'scale': round(p['dose'] * gain * unit[p['layer']], 4),
             **({'expert': p['expert']} if isinstance(p.get('expert'), int) else {})} for p in pushes]

def chat(messages, pushes=None, gain=1.0, port=8091, max_tokens=120, temperature=0, timeout=300, **extra):
    body = {'messages': messages, 'temperature': temperature, 'max_tokens': max_tokens,
            'chat_template_kwargs': {'enable_thinking': False}, **extra}
    if pushes:
        body['steer'] = request(pushes, gain)
    req = urllib.request.Request('http://127.0.0.1:%d/v1/chat/completions' % port, json.dumps(body).encode(), {'Content-Type': 'application/json'})
    msg = json.load(urllib.request.urlopen(req, timeout=timeout))['choices'][0]['message']
    return msg.get('content') or ''

def ask(prompt, pushes=None, **kw):
    return chat([{'role': 'user', 'content': prompt}], pushes, **kw)

if __name__ == '__main__':
    a = sys.argv[1:]
    if not a or a[0] == 'list':
        for r in load():
            print('%-9s %-26s %-34s %s' % (r.get('status', ''), r['name'][:26], r['code'][:34], (r.get('effect') or '')[:90]))
    elif a[0] == 'try':      # steer.py try <id|name|code> [prompt] [gain]
        r = find(a[1])
        prompt = a[2] if len(a) > 2 else 'How was your weekend?'
        gain = float(a[3]) if len(a) > 3 else 1.0
        print('plain  :', ask(prompt))
        print('steered:', ask(prompt, r['pushes'], gain=gain))
    else:
        print(__doc__)
