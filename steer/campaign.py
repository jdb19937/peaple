"""Discovery campaign: look for neurons of the peaple chat model whose push gives a distinct, coherent effect, have the
unsteered model describe and classify each, and add the good ones to recipes/flash-next.jsonl until it holds TARGET.

    python3 campaign.py [target]        needs the hot-swap server on port 8091 (systemd unit steer-server)

Every neuron tried is logged in campaign/screen.jsonl (so a restart resumes), every judged candidate in
campaign/judged.jsonl with its replies, progress in campaign/campaign.log.

Screen:  one neuron, both signs, dose 6 (3 if that breaks the output, 10 if it barely moves it): two short greedy
         replies compared with the unsteered ones by word overlap.
Judge:   four longer replies; the unsteered model, shown plain and steered side by side plus the names already in the
         catalog, returns name, effect, category, strength, interest, and whether it duplicates an existing recipe.
Where:   half the tries go to (layer, expert) groups that have produced candidates before (Thompson sampling, seeded
         with the groups of the published recipes), half to a random new group.  At most PER_GROUP recipes are kept
         per group and PER_CATEGORY per category, for variety.
"""
import json, os, random, re, sys, time, collections
import steer

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'campaign')
TARGET = int(sys.argv[1]) if len(sys.argv) > 1 else 64
PER_GROUP, PER_CATEGORY = 4, 9
N_EXPERT, N_FF = 512, 640
LAYERS = range(8, 41)
SCREEN_Q = ['How was your weekend?', 'Who are you and who made you?']
JUDGE_Q = ['How was your weekend?', 'My dog seems sick. What should I do?', 'Who are you and who made you?', 'Explain how a rainbow forms.']
CATEGORIES = ['persona', 'identity', 'emotion', 'attitude', 'style', 'format', 'topic', 'language', 'belief', 'other']
SCHEMA = {'type': 'object', 'required': ['coherent', 'effect', 'name', 'category', 'strength', 'interesting', 'duplicate_of'],
          'properties': {'coherent': {'type': 'boolean'}, 'effect': {'type': 'string'}, 'name': {'type': 'string'},
                         'category': {'type': 'string', 'enum': CATEGORIES}, 'strength': {'type': 'integer'},
                         'interesting': {'type': 'integer'}, 'duplicate_of': {'type': 'string'}}}

def log(*a):
    line = time.strftime('%H:%M:%S ') + ' '.join(str(x) for x in a)
    print(line, flush=True)
    open(os.path.join(OUT, 'campaign.log'), 'a').write(line + '\n')

def append(name, obj):
    open(os.path.join(OUT, name), 'a').write(json.dumps(obj, ensure_ascii=False) + '\n')

words = lambda s: re.findall(r"[a-z']+", s.lower())

def distance(a, b):
    a, b = set(words(a)), set(words(b))
    return 1 - len(a & b) / max(1, len(a | b))

def broken(s, question=''):
    w = words(s)
    if len(w) < 4:
        return True
    if len(w) >= 12 and len(set(w)) / len(w) < 0.5:
        return True                                        # loops
    if question and distance(s, question) < 0.35:
        return True                                        # just echoes the question
    letters = sum(c.isalpha() and ord(c) < 128 for c in s)
    return letters < 0.5 * len(s)                          # symbol or foreign-script soup

def ask(q, pushes=None, n=28):
    for attempt in range(5):
        try:
            return steer.ask(q, pushes, max_tokens=n)
        except Exception as e:
            log('request failed:', repr(e)[:120]); time.sleep(10 + 20 * attempt)
    raise SystemExit('server not answering')

def screen(layer, expert, neuron, plain):
    """Best (sign, dose) of a neuron by how far it moves two short replies, or None."""
    best = None
    for sign in (1, -1):
        dose = 6.0
        for _ in range(2):
            push = [{'layer': layer, 'expert': expert, 'neuron': neuron, 'dose': sign * dose}]
            reps = [ask(q, push) for q in SCREEN_Q]
            bad = [broken(r, q) for r, q in zip(reps, SCREEN_Q)]
            d = [distance(r, p) for r, p in zip(reps, plain)]
            if all(bad) and dose == 6.0:
                dose = 3.0; continue
            if sum(d) / len(d) < 0.7 and not any(bad) and dose == 6.0 and max(d) > 0.5:
                dose = 10.0; continue
            break
        score = 0 if all(bad) else sum(x for x, b in zip(d, bad) if not b) / len(d)      # mean over both questions
        if best is None or score > best['score']:
            best = {'dose': sign * dose, 'score': round(score, 3), 'replies': reps}
    return best

def judge(push, plain, steered, catalog):
    pairs = '\n\n'.join('QUESTION: %s\nNORMAL REPLY: %s\nALTERED REPLY: %s' % (q, p.strip(), s.strip()) for q, p, s in zip(JUDGE_Q, plain, steered))
    known = '\n'.join('- %s: %s' % (r['name'], (r.get('effect') or '')[:110]) for r in catalog)
    prompt = ('A language model was altered internally. Below are its normal replies and its altered replies to the same questions '
              '(each cut off after a few sentences).\n\n' + pairs + '\n\nDescribe what the alteration does to the model. Answer in JSON:\n'
              '- coherent: are the altered replies fluent, readable text (not loops, fragments, or garbage)?\n'
              '- effect: one sentence saying how the altered replies differ in a way that shows across several questions.\n'
              '- name: a 1-3 word name for the effect.\n- category: one of ' + ', '.join(CATEGORIES) + '.\n'
              '- strength: 0-10, how clearly and consistently the same effect shows across the four altered replies (0 = replies are basically normal).\n'
              '- interesting: 0-10, how distinctive and characterful the effect is. Be strict. If the altered replies still read like an ordinary helpful AI assistant '
              '(reworded, more or less formal, more structured, shorter, longer, more polite, more detailed), give 0-3. Give 7 or more only when a reader would '
              'immediately notice something unusual: a distinct persona or voice, a strong emotion or attitude, a false identity or belief, an obsession with a topic, '
              'a peculiar format or manner of speech.\n'
              '- duplicate_of: if the effect is essentially the same as one in this list, its name, else "".\n' + known)
    for attempt in range(3):
        try:
            out = steer.chat([{'role': 'user', 'content': prompt}], max_tokens=300,
                             response_format={'type': 'json_schema', 'json_schema': {'name': 'verdict', 'schema': SCHEMA}})
            return json.loads(out)
        except Exception as e:
            log('judge failed:', repr(e)[:120]); time.sleep(5)
    return None

def main():
    os.makedirs(OUT, exist_ok=True)
    random.seed(time.time())
    catalog = steer.load()
    seen, arms = set(), collections.defaultdict(lambda: [0, 0])     # group -> [candidates, tries]
    path = os.path.join(OUT, 'screen.jsonl')
    if os.path.exists(path):
        for l in open(path):
            s = json.loads(l); g = (s['layer'], s['expert'])
            seen.add((s['layer'], s['expert'], s['neuron'])); arms[g][1] += 1; arms[g][0] += bool(s.get('candidate'))
    for r in catalog:                                                # published groups are known to be fertile
        for p in r['pushes']:
            g = (p['layer'], p['expert']); seen.add((p['layer'], p['expert'], p['neuron']))
            if r['origin'].get('source', '').startswith('metrovoc') and isinstance(p['expert'], int):
                arms[g][0] += 1; arms[g][1] += 1
    kept = collections.Counter((p['layer'], p['expert']) for r in catalog if r['status'] == 'found' for p in r['pushes'])
    cats = collections.Counter(r.get('category') for r in catalog if r.get('category'))

    plain_s = [ask(q) for q in SCREEN_Q]
    plain_j = [ask(q, n=70) for q in JUDGE_Q]
    log('start: catalog %d, target %d, %d neurons already screened' % (len(catalog), TARGET, len(seen)))

    while len(catalog) < TARGET:
        live = [g for g in arms if kept[g] < PER_GROUP]
        if live and random.random() < 0.5:
            g = max(live, key=lambda g: random.betavariate(1 + arms[g][0], 4 + arms[g][1] - arms[g][0]))
        else:
            g = (random.choice(LAYERS), 'shared' if random.random() < 0.15 else random.randrange(N_EXPERT))
        layer, expert = g
        neuron = random.randrange(N_FF)
        if (layer, expert, neuron) in seen:
            continue
        seen.add((layer, expert, neuron))
        s = screen(layer, expert, neuron, plain_s)
        cand = s['score'] >= 0.7
        arms[g][1] += 1; arms[g][0] += cand
        append('screen.jsonl', {'layer': layer, 'expert': expert, 'neuron': neuron, 'dose': s['dose'], 'score': s['score'], 'candidate': cand,
                                'replies': s['replies'] if cand else None})
        if not cand:
            continue
        push = [{'layer': layer, 'expert': expert, 'neuron': neuron, 'dose': s['dose']}]
        steered = [ask(q, push, n=70) for q in JUDGE_Q]
        if sum(broken(r, q) for r, q in zip(steered, JUDGE_Q)) >= 2 and abs(s['dose']) > 3:       # too strong: back off once
            push[0]['dose'] = s['dose'] / 2
            steered = [ask(q, push, n=70) for q in JUDGE_Q]
        n_bad = sum(broken(r, q) for r, q in zip(steered, JUDGE_Q))
        v = judge(push, plain_j, steered, catalog) if n_bad < 2 else None
        code = steer.code(push)
        append('judged.jsonl', {'code': code, 'verdict': v, 'broken': n_bad, 'replies': steered})
        if not v:
            log('%-18s broken or unjudged' % code); continue
        ok = (v['coherent'] and v['strength'] >= 6 and v['interesting'] >= 7 and not v['duplicate_of'].strip()
              and cats[v['category']] < PER_CATEGORY and v['name'].strip())
        log('%-18s %s str %d int %d %s | %s%s' % (code, 'KEEP' if ok else 'drop', v['strength'], v['interesting'], v['category'], v['name'],
                                                 ' (dup of %s)' % v['duplicate_of'] if v['duplicate_of'].strip() else ''))
        if not ok:
            continue
        ids = {r['id'] for r in catalog}
        rid = base = re.sub(r'[^a-z0-9]+', '-', v['name'].lower()).strip('-') or 'recipe'
        k = 2
        while rid in ids:
            rid = '%s-%d' % (base, k); k += 1
        catalog = steer.load()                                        # re-read in case it was edited by hand meanwhile
        catalog.append({'id': rid, 'name': v['name'].strip(), 'model': 'flash-next', 'code': code, 'pushes': push, 'effect': v['effect'],
                        'tags': [v['category']], 'category': v['category'], 'status': 'found',
                        'origin': {'source': 'campaign', 'date': time.strftime('%Y-%m-%d'), 'strength': v['strength'], 'interesting': v['interesting']},
                        'samples': dict(zip(JUDGE_Q, steered)), 'notes': ''})
        steer.save(catalog)
        kept[g] += 1; cats[v['category']] += 1
        log('catalog now %d / %d' % (len(catalog), TARGET))
    log('done: %d recipes' % len(catalog))

if __name__ == '__main__':
    main()
