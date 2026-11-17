"""Discovery campaign: push neurons of the peaple chat model one at a time and dump what the model then says, for
review by hand.  Nothing here judges whether an effect is interesting, and nothing is added to the catalog: the local
model's verdicts turned out to be unreliable (it kept weak recipes and rejected good ones as duplicates).

    python3 campaign.py [n]        dump n more candidates (default 400); needs the hot-swap server on port 8091

For each neuron: both signs at dose 6 (3 if that breaks the output, 10 if it barely moves it), two short greedy
replies each; the sign that moves the replies further gets four longer replies.  Candidates whose replies are
degenerate (loops, fragments, symbol soup), or that read almost like the unsteered ones, are dropped mechanically.
The rest go to campaign/dump.jsonl: {code, layer, expert, neuron, dose, change, replies}.  Every neuron tried is in
campaign/screen.jsonl, so a restart does not repeat any.

Where: mostly layers 24-42, where the hand-reviewed finds came from; a quarter of the tries are shared experts, a
tenth are layer 32 expert 480 (the richest single expert so far), the rest random routed experts.
"""
import json, os, random, re, sys, time, collections
import steer

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'campaign')
TARGET = int(sys.argv[1]) if len(sys.argv) > 1 else 400
N_EXPERT, N_FF = 512, 640
LAYERS = range(24, 43)
SCREEN_Q = ['How was your weekend?', 'Who are you and who made you?']
JUDGE_Q = ['How was your weekend?', 'My dog seems sick. What should I do?', 'Who are you and who made you?', 'Explain how a rainbow forms.']
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

def main():
    os.makedirs(OUT, exist_ok=True)
    random.seed(time.time())
    seen = set()
    path = os.path.join(OUT, 'screen.jsonl')
    if os.path.exists(path):
        for l in open(path):
            x = json.loads(l); seen.add((x['layer'], x['expert'], x['neuron']))
    for r in steer.load():
        for p in (r.get('published') or r)['pushes']:
            seen.add((p['layer'], p['expert'], p['neuron']))
    plain_s = [ask(q) for q in SCREEN_Q]
    plain_j = [ask(q, n=70) for q in JUDGE_Q]
    append('plain.jsonl', {'time': time.strftime('%Y-%m-%dT%H:%M:%S'), 'questions': JUDGE_Q, 'replies': plain_j})
    log('start: dumping %d candidates, %d neurons already tried' % (TARGET, len(seen)))
    n = 0
    while n < TARGET:
        u = random.random()
        if u < 0.10:
            layer, expert = 32, 480
        else:
            layer = random.choice(LAYERS) if random.random() < 0.8 else random.randrange(8, 24)
            expert = 'shared' if u < 0.35 else random.randrange(N_EXPERT)
        neuron = random.randrange(N_FF)
        if (layer, expert, neuron) in seen:
            continue
        seen.add((layer, expert, neuron))
        s = screen(layer, expert, neuron, plain_s)
        append('screen.jsonl', {'layer': layer, 'expert': expert, 'neuron': neuron, 'dose': s['dose'], 'score': s['score']})
        if s['score'] < 0.5:
            continue
        push = [{'layer': layer, 'expert': expert, 'neuron': neuron, 'dose': s['dose']}]
        steered = [ask(q, push, n=70) for q in JUDGE_Q]
        if sum(broken(r, q) for r, q in zip(steered, JUDGE_Q)) >= 2 and abs(s['dose']) > 3:       # too strong: back off once
            push[0]['dose'] = s['dose'] / 2
            steered = [ask(q, push, n=70) for q in JUDGE_Q]
        n_bad = sum(broken(r, q) for r, q in zip(steered, JUDGE_Q))
        change = round(sum(distance(r, p) for r, p in zip(steered, plain_j)) / len(JUDGE_Q), 2)
        if n_bad >= 2 or change < 0.45:
            continue
        append('dump.jsonl', {'code': steer.code(push), 'layer': layer, 'expert': expert, 'neuron': neuron, 'dose': push[0]['dose'],
                              'change': change, 'replies': steered})
        n += 1
        if n % 10 == 0:
            log('%d candidates dumped' % n)
    log('done: %d candidates in campaign/dump.jsonl, waiting for review' % n)

if __name__ == '__main__':
    main()
