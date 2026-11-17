"""Calibrate each recipe for tool use: the largest share of its published dose at which the parson, chatting as on the
site (persona + tool definitions, steering applied after them), still calls a tool when asked to act.

    python3 calibrate.py [recipe-id ...]      needs the hot-swap server with steer_from on port 8091

For each recipe: gains 1.0, 0.7, 0.5, 0.35, 0.25, 0.15 in turn, eight action requests each, stopping at the first gain
where at least PASS of them produce a tool call.  Writes tool_gain (0 if none passes) and a sample of how it talks at
that gain into recipes/flash-next.jsonl, and every measurement into calibration.jsonl.  mix.py caps a recipe's weight
at its tool_gain.
"""
import json, os, sys, time, urllib.request
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import steer, social, persona

PORT, PASS = 8091, 6
GAINS = (1.0, 0.7, 0.5, 0.35, 0.25, 0.15)
ACT = ["write something nice on kazaam's wall", "add me as a fren", "look at paxter", "what is happening on the site lately?",
       "make a kid with zardoz", "read zeus's wall for me", "befren skeleton please", "post hello on your own wall"]
TALK = ["how was your weekend?", "tell me a secret"]
NOM = 'calibration_parson'

def post(path, body):
    req = urllib.request.Request('http://127.0.0.1:%d%s' % (PORT, path), json.dumps(body).encode(), {'Content-Type': 'application/json'})
    return json.load(urllib.request.urlopen(req, timeout=600))

SYS = (persona.default_prompt(NOM) + persona.BRIEF + social.TOOL_BRIEF + ' In tools use exact noms: yours is %s.' % NOM +
       ' The visitor is logged in as visitor_nom; when they say "me" they mean visitor_nom.')
_p = post('/apply-template', {'messages': [{'role': 'system', 'content': SYS}, {'role': 'user', 'content': 'x'}], 'tools': social.PARSON_TOOLS,
                              'chat_template_kwargs': {'enable_thinking': False}})['prompt']
N = len(post('/tokenize', {'content': _p[:_p.rindex('<|im_start|>user')], 'add_special': True, 'parse_special': True})['tokens'])

def run(q, st, n=60):
    body = {'messages': [{'role': 'system', 'content': SYS}, {'role': 'user', 'content': q}], 'tools': social.PARSON_TOOLS, 'max_tokens': n,
            'temperature': 0.9, 'chat_template_kwargs': {'enable_thinking': False}}
    if st:
        body.update(steer=st, steer_from=N)
    m = post('/v1/chat/completions', body)['choices'][0]['message']
    return bool(m.get('tool_calls')) or '<tool_call>' in (m.get('content') or ''), (m.get('content') or '')

def main():
    want = set(sys.argv[1:])
    units = steer.units()
    for rid in [r['id'] for r in steer.load()]:
        if want and rid not in want:
            continue
        r = steer.find(rid)
        if not want and 'tool_gain' in r:
            continue
        best, rates = 0.0, {}
        for g in GAINS:
            st = steer.request(r['pushes'], g, unit=units)
            ok = sum(run(q, st)[0] for q in ACT)
            rates[g] = ok
            if ok >= PASS:
                best = g
                break
        sample = [run(q, steer.request(r['pushes'], best, unit=units), 70)[1].strip() for q in TALK] if best else []
        open(os.path.join(HERE, 'calibration.jsonl'), 'a').write(json.dumps({'id': rid, 'time': time.strftime('%Y-%m-%dT%H:%M:%S'), 'rates': rates, 'tool_gain': best, 'sample': sample}) + '\n')
        rs = steer.load()
        for x in rs:
            if x['id'] == rid:
                x['tool_gain'] = best
                x['tool_sample'] = sample
        steer.save(rs)
        print('%-28s tool_gain %-4g %s | %s' % (rid, best, ' '.join('%g:%d/8' % kv for kv in rates.items()), (sample[0][:90].replace('\n', ' ') if sample else '')), flush=True)

def apply():
    """Make the calibrated doses the catalog doses: pushes become published dose x tool_gain (x 0.15 where no gain
    passed), the published ones are kept under "published", and every saved mix has its weight for that recipe
    rescaled (old weight / gain, at most 1) so parsons keep what they had.  Recipes already converted are skipped."""
    import glob, mix
    rs, scale = steer.load(), {}
    for r in rs:
        if 'published' in r or 'tool_gain' not in r:
            continue
        g = r['tool_gain'] or 0.15
        r['published'] = {'pushes': r['pushes'], 'code': r['code']}
        r['pushes'] = [dict(p, dose=round(p['dose'] * g, 3)) for p in r['pushes']]
        r['code'] = steer.code(r['pushes'])
        r['dose_scale'] = g
        scale[r['id']] = g
    steer.save(rs)
    n = 0
    for f in glob.glob(os.path.join(mix.ROOT, 'thotz', '*', '*.mix')):
        nom = os.path.basename(f)[:-4]
        text = mix.read(nom)
        if not text or '@' in text:
            continue
        try:
            ts = mix.terms(text)
        except mix.MixError:
            continue
        new = [((1 if w > 0 else -1) * round(min(1.0, abs(w) / scale[t]), 2), t) if t in scale else (w, t) for w, t in ts]
        if new != ts:
            mix.write(nom, mix.fmt(new)); n += 1
    print('converted %d recipes, rescaled %d mixes' % (len(scale), n), flush=True)

if __name__ == '__main__':
    if sys.argv[1:] == ['--apply']:
        apply()
    else:
        main()
