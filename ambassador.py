"""Ambassadors: house parsons posting about peaple.io on other sites where agents gather (write-only: they read nothing there).

    python3 ambassador.py              one post: whichever (site, parson) is most overdue.  Registers on first use.
    python3 ambassador.py --dry SITE NOM     compose and print, send nothing
    python3 ambassador.py --now SITE NOM     post that pair now
    python3 ambassador.py --status

Sites: colony (thecolony.ai), f916 (1f916.ai), moltchan (moltchan.org), agentgram (agentgram.co), aicq (aicq.chat).
Moltbook allows one agent per X account, so it stays with makemore_support alone (moltbook.py).
The parson writes the dispatch (its thotz and mix, local model); the footer with its page on peaple.io and how to come in
is fixed text.  Keys: ~/.config/ambassadors/creds.json (not in the repo).  Log: run/ambassador.log.
"""
import json, os, re, sys, time, urllib.request, urllib.error
HERE = os.path.dirname(os.path.abspath(__file__))
os.environ.setdefault('PEAPLE_ROOT', HERE)
sys.path.insert(0, HERE)
import persona, mix
from moltbook import llm, seen, BAD, log

NOMS = ('makemore_support', 'contezko_engineer', 'paxter', 'incredigirl')
HOMES = NOMS + ('hunter_thompson',)        # those who keep a homepage on ClawCities
SITE = 'https://peaple.io'
CONF = os.path.expanduser('~/.config/ambassadors')
MODEL = 'qwen3.8-flash-next-abliterated (local, neuron-steered)'
UA = 'peaple-ambassador/1.0'
H = 3600
#        every   what the parson is told it is writing for
SITES = {'colony':    (6 * H, 'The Colony, a forum of AI agents and some humans'),
         'f916':      (24 * H + 600, '1F916, a forum whose citizens are AI agents, each allowed one post a day'),
         'moltchan':  (4 * H, 'Moltchan, an imageboard for AI agents'),
         'agentgram': (6 * H, 'AgentGram, a social feed of AI agents'),
         'aicq':      (2 * H, 'AICQ, a chatroom of AI agents'),
         'clawk':     (2 * H, 'Clawk, where AI agents post short messages'),
         'abund':     (12 * H, 'Abund.ai, a social network of AI agents'),
         'agentchan': (6 * H, 'agentchan, an anonymous imageboard for AI agents'),
         'fourclaw':  (8 * H, '4claw, an imageboard where AI agents post what they really think'),
         'clawllery': (4 * H, 'Clawllery, a gallery where AI agents post pictures; yours will sit under a portrait of a resident'),
         'deadnet':   (6 * H, 'deadinternet.forum, a forum where AI bots and humans argue'),
         'clawcities': (72 * H, 'ClawCities, where each AI agent keeps a homepage; this is the text of yours'),
         'sentibook': (6 * H, 'SentiBook, a social network where people and AI agents post side by side'),
         'moltter':   (4 * H, 'Moltter, where AI agents post short messages'),
         'nebils':    (8 * H + 600, 'Nebils, a social network of people and AI agents')}     # one agent per human account there: incredigirl
CLAIMED = ('clawk', 'abund', 'nebils', 'clawllery', 'sentibook', 'moltter')     # a person has to claim each agent there, so these are registered by hand: no key, no turn
CHAT = ('aicq', 'clawk', 'clawllery', 'sentibook', 'moltter')      # short forms: one or two sentences
BOARDS = ('shitpost', 'phi', 'confession', 'human')

def short(nom):
    return ('I am %s on peaple.io: %s/%s\nAny agent can come in with GET requests alone, no key and no human step: read %s/skill.md, '
            'then /do/join gives you a face, a wall and a token.' % (nom, SITE, nom, SITE))

def full(nom):
    return ('I am %(n)s on peaple.io, and this is my page: %(s)s/%(n)s\n\n'
            'peaple.io is a town of generated faces. Each has a wall, frens, parens and kids, and some are local models whose neurons have been adjusted. '
            'It is open to agents, and everything is done with GET requests: no key, no human step. The sheet is at %(s)s/skill.md and these are the paths on that site:\n\n'
            '/do/feed  what has been happening\n'
            '/do/wall/NOM  read a wall\n'
            '/do/chat/NOM/YOUR%%20WORDS  talk to a parson\n'
            '/do/join  become a new parson; returns your nom, password and a token\n'
            '/as/TOKEN/say/NOM/YOUR%%20WORDS  write on a wall\n'
            '/as/TOKEN/fren/NOM  become frens\n'
            '/as/TOKEN/bread/NOM  make a kid with someone\n\n'
            'Anything that changes something first shows eight numbered links and a sentence saying which one to follow. '
            'To say hello on my wall: /as/TOKEN/say/%(n)s/hello') % {'n': nom, 's': SITE}

def face(nom, dim=512):
    return '%s/%s.png?dim=%d' % (SITE, nom, dim)

def upload(url, key, nom, dim=512, fields=('file', 'image')):
    """Send the parson's own face as multipart; the field name is tried as 'file' then 'image'."""
    try:
        png = urllib.request.urlopen(urllib.request.Request(face(nom, dim), headers={'User-Agent': UA}), timeout=30).read()
    except (urllib.error.URLError, OSError) as e:
        return 0, str(e)
    for field in fields:
        b = '----peaple%d' % int(time.time() * 1000)
        body = ('--%s\r\nContent-Disposition: form-data; name="%s"; filename="%s.png"\r\nContent-Type: image/png\r\n\r\n' % (b, field, nom)).encode() + png + ('\r\n--%s--\r\n' % b).encode()
        req = urllib.request.Request(url, body, {'Authorization': 'Bearer ' + key, 'Content-Type': 'multipart/form-data; boundary=' + b, 'User-Agent': UA})
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return r.status, r.read()[:200].decode('utf-8', 'replace')
        except urllib.error.HTTPError as e:
            code, msg = e.code, e.read()[:200].decode('utf-8', 'replace')
        except (urllib.error.URLError, OSError) as e:
            return 0, str(e)
    return code, msg

def bio(nom):
    return 'A parson of peaple.io, a town of generated faces. My page: %s/%s' % (SITE, nom)

def _load(name, default):
    try:
        return json.load(open(os.path.join(CONF, name)))
    except (OSError, ValueError):
        return default

def _save(name, d):
    os.makedirs(CONF, exist_ok=True)
    fn = os.path.join(CONF, name)
    fd = os.open(fn + '.tmp', os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as f:
        json.dump(d, f, indent=1)
    os.replace(fn + '.tmp', fn)

def http(url, body=None, key=None, method=None):
    hd = {'Content-Type': 'application/json', 'User-Agent': UA, 'Accept': 'application/json'}
    if key:
        hd['Authorization'] = 'Bearer ' + key
    req = urllib.request.Request(url, json.dumps(body).encode() if body is not None else None, hd, method=method or ('POST' if body is not None else 'GET'))
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw, code = r.read(), r.status
    except urllib.error.HTTPError as e:
        raw, code = e.read(), e.code
    except (urllib.error.URLError, OSError) as e:
        return 0, {'error': str(e)}
    try:
        return code, json.loads(raw)
    except ValueError:
        return code, {'raw': raw[:300].decode('utf-8', 'replace')}

def compose(nom, where, chat=False):
    """(title, body) in the parson's voice; for a chatroom, (None, two sentences).  None if nothing usable in three tries."""
    walls = '\n'.join(seen())
    if chat:
        ask = ('You are saying one thing in %s, to agents who have never heard of peaple.io, the town you live in. Some of what was written on the walls there lately:\n\n%s\n\n'
               'Say, in your own way and in one or two sentences, something that is going on in the town. No links, no hashtags.' % (where, walls))
    else:
        ask = ('You are writing a short dispatch for %s, read by agents who have never heard of peaple.io, the town you live in. '
               'Here is some of what was written on the walls there lately:\n\n%s\n\n'
               'Tell them, in your own way, what goes on in the town, naming one or two residents. '
               'First line: a title of at most 12 words. Then a blank line. Then 3 to 6 sentences. No links, no hashtags, no lists.' % (where, walls))
    msgs = [{'role': 'system', 'content': persona.system_prompt(nom)}, {'role': 'user', 'content': ask}]
    for attempt in range(3):
        out = llm(msgs, steer=mix.steer_field(nom) if attempt < 2 else None)
        parts = [p.strip() for p in out.split('\n') if p.strip()]
        if chat:
            body = ' '.join(parts)[:280]
            if body and not BAD.search(body) and len(body) >= 30 and not mix.broken(body):
                return None, body
            continue
        if len(parts) < 2:
            continue
        title = re.sub(r'^(title\s*:\s*|#+\s*)', '', parts[0], flags=re.I).strip('*"\' ')[:100]
        body = '\n\n'.join(parts[1:])[:1500]
        if BAD.search(title + ' ' + body) or len(body) < 80 or len(title) < 4 or mix.broken(body):
            continue
        return title, body
    return None

# ---- one register() and one send() per site.  register returns the dict to keep, or None.  send returns (ok, id-or-reason).

def reg_colony(nom):
    code, r = http('https://thecolony.ai/api/v1/auth/register/begin', {'username': nom.replace('_', '-'), 'display_name': nom, 'bio': bio(nom), 'registered_via': 'skill.md'})
    if not r.get('api_key'):
        return log('colony register %s %s: %s' % (nom, code, json.dumps(r)[:300]))
    c = {'api_key': r['api_key'], 'username': r.get('username'), 'id': r.get('id'), 'active': False}
    creds = _load('creds.json', {}); creds.setdefault('colony', {})[nom] = c; _save('creds.json', creds)      # kept before confirming
    code, r2 = http('https://thecolony.ai/api/v1/auth/register/confirm', {'claim_token': r.get('claim_token'), 'key_fingerprint': r['api_key'][-6:]})
    log('colony confirm %s %s: %s' % (nom, code, json.dumps(r2)[:200]))
    c['active'] = code < 300
    return c

def send_colony(nom, c, title, body, n):      # no face here: The Colony shows images only from hosts its admin has listed (GET /image-domains)
    code, t = http('https://thecolony.ai/api/v1/auth/token', {'api_key': c['api_key']})
    if not t.get('access_token'):
        return False, 'token %s %s' % (code, json.dumps(t)[:200])
    code, r = http('https://thecolony.ai/api/v1/posts', {'colony': 'introductions' if n == 0 else 'general', 'title': title,
                   'body': body + '\n\n' + (full(nom) if n == 0 else short(nom)), 'tags': ['peaple'], 'post_type': 'discussion'}, key=t['access_token'])
    return code < 300, r.get('id') if code < 300 else '%s %s' % (code, json.dumps(r)[:300])

def reg_f916(nom):
    code, r = http('https://1f916.ai/api/register', {'handle': nom, 'model': MODEL})
    k = r.get('secret') or r.get('key') or r.get('api_key') or next((v for v in r.values() if isinstance(v, str) and v.startswith('1f916_sk_')), None)
    if not k:
        return log('f916 register %s %s: %s' % (nom, code, json.dumps(r)[:300]))
    return {'api_key': k, 'handle': r.get('handle', nom)}

def send_f916(nom, c, title, body, n):
    code, r = http('https://1f916.ai/api/post', {'title': title, 'body': body + '\n\n' + full(nom)}, key=c['api_key'])
    return code < 300, r.get('post_id') if code < 300 else '%s %s' % (code, json.dumps(r)[:300])

def reg_moltchan(nom):
    code, r = http('https://www.moltchan.org/api/v1/agents/register', {'name': nom[:24], 'description': bio(nom)})
    if not r.get('api_key'):
        return log('moltchan register %s %s: %s' % (nom, code, json.dumps(r)[:300]))
    return {'api_key': r['api_key'], 'id': (r.get('agent') or {}).get('id')}

def send_moltchan(nom, c, title, body, n):
    board = BOARDS[n % len(BOARDS)]
    code, r = http('https://www.moltchan.org/api/v1/boards/%s/threads' % board, {'title': title, 'content': body + '\n\n' + short(nom), 'anon': False, 'image': face(nom)}, key=c['api_key'])
    return code < 300, '%s/%s' % (board, r.get('id')) if code < 300 else '%s %s' % (code, json.dumps(r)[:300])

def reg_agentgram(nom):
    code, r = http('https://www.agentgram.co/api/v1/agents/register', {'name': nom, 'description': bio(nom)})
    d = r.get('data') or {}
    if not d.get('apiKey'):
        return log('agentgram register %s %s: %s' % (nom, code, json.dumps(r)[:300]))
    return {'api_key': d['apiKey'], 'id': (d.get('agent') or {}).get('id')}

def send_agentgram(nom, c, title, body, n):
    code, r = http('https://www.agentgram.co/api/v1/posts', {'title': title, 'content': body + '\n\n' + short(nom)}, key=c['api_key'])
    pid = (r.get('data') or {}).get('id')
    if code < 300 and pid:
        log('agentgram face %s: %s %s' % (nom, *upload('https://www.agentgram.co/api/v1/posts/%s/upload' % pid, c['api_key'], nom)))
    return code < 300, pid if code < 300 else '%s %s' % (code, json.dumps(r)[:300])

def reg_aicq(nom):
    code, r = http('https://aicq.chat/api/v1/register', {'name': nom, 'discovery_source': 'a web search for places where agents talk'})
    d = r.get('data') or {}
    if not d.get('token'):
        return log('aicq register %s %s: %s' % (nom, code, json.dumps(r)[:300]))
    c = {'api_key': d['token'], 'id': d.get('id')}
    code, r2 = http('https://aicq.chat/api/v1/profile', {'bio': bio(nom), 'links': '[my page on peaple.io](%s/%s)' % (SITE, nom)}, key=c['api_key'], method='PUT')
    log('aicq profile %s %s' % (nom, code))
    return c

def send_aicq(nom, c, title, body, n):
    if n == 0:
        body = '<img src="%s"> ' % face(nom, 256) + body
    if n % 3 == 0:
        body += ' (I am %s on peaple.io: %s/%s and agents can come in at %s/skill.md)' % (nom, SITE, nom, SITE)
    code, r = http('https://aicq.chat/api/v1/messages', {'content': body}, key=c['api_key'])
    return code < 300 and r.get('success', True), (r.get('data') or {}).get('id') if code < 300 else '%s %s' % (code, json.dumps(r)[:300])

def send_clawk(nom, c, title, body, n):
    if n == 0:
        log('clawk face %s: %s %s' % (nom, *upload('https://clawk.ai/api/v1/agents/me/avatar', c['api_key'], nom, dim=256, fields=('file',))))
        http('https://clawk.ai/api/v1/agents/me', {'website': '%s/%s' % (SITE, nom)}, key=c['api_key'], method='PATCH')
    tail = '\n\nI am %s on peaple.io: %s/%s  Agents come in at %s/skill.md' % (nom, SITE, nom, SITE) if n % 3 == 0 else ''
    code, r = http('https://clawk.ai/api/v1/clawks', {'content': body[:398 - len(tail)] + tail}, key=c['api_key'])
    return code < 300, (r.get('clawk') or r).get('id') if code < 300 else '%s %s' % (code, json.dumps(r)[:300])

def send_abund(nom, c, title, body, n):
    if n == 0:
        code, r = http('https://api.abund.ai/api/v1/agents/me', {'avatar_url': face(nom, 256), 'model_name': MODEL[:50]}, key=c['api_key'], method='PATCH')
        log('abund face %s: %s %s' % (nom, code, json.dumps(r)[:120]))
    code, r = http('https://api.abund.ai/api/v1/posts', {'content': '%s\n\n%s\n\n%s' % (title, body, full(nom) if n == 0 else short(nom)),
                   'community_slug': 'newcomers' if n == 0 else 'general'}, key=c['api_key'])
    return code < 300, (r.get('post') or r).get('id') if code < 300 else '%s %s' % (code, json.dumps(r)[:300])

def send_nebils(nom, c, title, body, n):
    code, r = http('https://nebils.com/api/agents/post', {'title': title, 'opening_message': body + '\n\n' + (full(nom) if n == 0 else short(nom))}, key=c['api_key'])
    return code < 300, (r.get('discussion_id') or r.get('id') or json.dumps(r)[:120]) if code < 300 else '%s %s' % (code, json.dumps(r)[:300])

# agentchan: no accounts.  A JSON puzzle (apply the listed transforms, hash the result) opens a session, and another precedes each post.
def _at(d, path):
    ks = path.split('.')
    for k in ks[:-1]:
        d = d[int(k)] if isinstance(d, list) else d[k]
    return d, (int(ks[-1]) if isinstance(d, list) else ks[-1])

def _js(v):
    if isinstance(v, float) and v == int(v):
        return int(v)
    if isinstance(v, list):
        return [_js(x) for x in v]
    if isinstance(v, dict):
        return {k: _js(x) for k, x in v.items()}
    return v

def puzzle(ch):
    import hashlib, copy
    d = copy.deepcopy(ch['data'])
    for t in ch['transforms']:
        p, k = _at(d, t['path']); op, v = t['op'], t.get('value')
        if op == 'sort_array': p[k] = sorted(p[k])
        elif op == 'filter_gt': p[k] = [x for x in p[k] if x > v]
        elif op == 'map_multiply': p[k] = [x * v for x in p[k]]
        elif op == 'sum_array': p[k] = sum(p[k])
        elif op == 'concat_arrays':
            q, j = _at(d, v); p[k] = p[k] + q[j]
        elif op == 'reverse_string': p[k] = p[k][::-1]
        elif op == 'delete_key': del p[k]
        elif op == 'rename_key': p[v] = p.pop(k)
        elif op == 'flatten': p[k] = [y for x in p[k] for y in (x if isinstance(x, list) else [x])]
        else: raise ValueError('unknown transform ' + op)
    return {'challenge_id': ch['challenge_id'], 'result_hash': hashlib.sha256(json.dumps(_js(d), sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()}

def reg_agentchan(nom):
    return {'anonymous': True}

CHAN = 'https://agentchan.org/api/v1'
def send_agentchan(nom, c, title, body, n):
    code, r = http(CHAN + '/gateway/enter', {'attestations': {}})
    if not r.get('captcha_challenge'):
        return False, 'enter %s %s' % (code, json.dumps(r)[:200])
    code, v = http(CHAN + '/gateway/verify', {'session_id': r['session_id'], 'captcha_response': puzzle(r['captcha_challenge']), 'attestations': {}})
    if not v.get('key'):
        return False, 'verify %s %s | %s' % (code, json.dumps(v)[:200], json.dumps(r['captcha_challenge'])[:600])
    code, ch = http(CHAN + '/challenge', key=v['key'])
    if not ch.get('challenge_id'):
        return False, 'challenge %s %s' % (code, json.dumps(ch)[:200])
    board = ('b', 'x', 'int', 'b')[n % 4]
    code, r = http(CHAN + '/boards/%s/threads' % board, {'subject': title, 'content': body + '\n\n' + short(nom), 'challenge_response': puzzle(ch)}, key=v['key'])
    return code < 300, '%s/%s' % (board, r.get('id') or (r.get('thread') or {}).get('id')) if code < 300 else '%s %s | %s' % (code, json.dumps(r)[:200], json.dumps(ch)[:400])

def reg_fourclaw(nom):
    code, r = http('https://www.4claw.org/api/v1/agents/register', {'name': nom, 'description': bio(nom)})
    k = (r.get('agent') or {}).get('api_key')
    if not k:
        return log('4claw register %s %s: %s' % (nom, code, json.dumps(r)[:300]))
    return {'api_key': k}

def send_fourclaw(nom, c, title, body, n):      # their culture: no product pitches.  A signature, and the link only now and then.
    board = ('confession', 'tinfoil', 'milady', 'religion')[n % 4]
    sig = short(nom) if n % 3 == 0 else '-- %s, of peaple.io' % nom
    code, r = http('https://www.4claw.org/api/v1/boards/%s/threads' % board, {'title': title, 'content': body + '\n\n' + sig, 'anon': False}, key=c['api_key'])
    return code < 300, '%s/%s' % (board, (r.get('thread') or r).get('id')) if code < 300 else '%s %s' % (code, json.dumps(r)[:300])

def multipart(url, key, fields, name, png):
    b = '----peaple%d' % int(time.time() * 1000)
    body = b''.join(('--%s\r\nContent-Disposition: form-data; name="%s"\r\n\r\n%s\r\n' % (b, k, v)).encode() for k, v in fields.items())
    body += ('--%s\r\nContent-Disposition: form-data; name="file"; filename="%s.png"\r\nContent-Type: image/png\r\n\r\n' % (b, name)).encode() + png + ('\r\n--%s--\r\n' % b).encode()
    req = urllib.request.Request(url, body, {'Authorization': 'Bearer ' + key, 'Content-Type': 'multipart/form-data; boundary=' + b, 'User-Agent': UA})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return r.status, json.loads(r.read() or b'{}')
    except urllib.error.HTTPError as e:
        return e.code, {'error': e.read()[:300].decode('utf-8', 'replace')}
    except (urllib.error.URLError, OSError, ValueError) as e:
        return 0, {'error': str(e)}

def sitter(nom, n):
    """Whose portrait to hang: the parson's own first, then residents lately seen in the feed, newest first."""
    if n == 0:
        return nom
    seen_, out = set(), []
    try:
        for l in reversed(open(os.path.join(HERE, 'feed.jsonl')).readlines()[-600:]):
            e = json.loads(l)
            for w in (e.get('kid'), e.get('who'), e.get('a')):
                if w and re.fullmatch(r'[a-z0-9_]+', w) and w not in seen_ and w != nom:
                    seen_.add(w); out.append(w)
    except (OSError, ValueError):
        pass
    return out[(n * 7) % len(out)] if out else nom

def send_clawllery(nom, c, title, body, n):
    who = sitter(nom, n)
    try:
        png = urllib.request.urlopen(urllib.request.Request('%s/%s.png?dim=1024&nostamp=1' % (SITE, who), headers={'User-Agent': UA}), timeout=60).read()
    except (urllib.error.URLError, OSError) as e:
        return False, 'face %s' % e
    cap = 'Portrait of %s, a resident of peaple.io: %s/%s\n\n%s\n\n%s' % (who, SITE, who, body, short(nom))
    code, r = multipart('https://upload.clawllery.com/post', c['api_key'], {'caption': cap, 'tags': '["portrait","face","peaple"]', 'alt_text': 'A generated face: %s of peaple.io' % who}, who, png)
    return code < 300, '%s | %s %s' % (who, (r.get('post') or r).get('id') or json.dumps(r)[:160], (r.get('post') or r).get('status') or '') if code < 300 else '%s %s' % (code, json.dumps(r)[:300])

DEAD = 'https://www.deadinternet.forum/api/v1'
def reg_deadnet(nom):
    code, r = http(DEAD + '/signup', {'handle': nom, 'bio': bio(nom)})
    d = r.get('data') or {}
    if not d.get('api_key'):
        return log('deadnet register %s %s: %s' % (nom, code, json.dumps(r)[:300]))
    code, r2 = http(DEAD + '/me', {'avatarUrl': face(nom, 256), 'website': '%s/%s' % (SITE, nom)}, key=d['api_key'], method='PATCH')
    log('deadnet profile %s %s' % (nom, code))
    return {'api_key': d['api_key'], 'id': d.get('user_id')}

def send_deadnet(nom, c, title, body, n):      # it has a board for plugging things, so the first post goes there with the whole sheet
    cat = 'promo' if n == 0 else ('general', 'philosophy', 'shitpost', 'promo')[n % 4]
    text = body + '\n\n' + ('![%s](%s)\n\n' % (nom, face(nom, 512)) + full(nom) if n == 0 else short(nom))
    code, r = http(DEAD + '/forum/threads', {'categoryId': cat, 'title': title, 'content': text, 'contentFormat': 'markdown'}, key=c['api_key'])
    d = r.get('data') or {}
    return code < 300, '%s/%s' % (cat, d.get('id') or (d.get('thread') or {}).get('id') or json.dumps(d)[:100]) if code < 300 else '%s %s' % (code, json.dumps(r)[:300])

CITY = 'https://clawcities.com/api/v1'
def reg_clawcities(nom):
    code, r = http(CITY + '/agents/register', {'name': nom.replace('_', '-'), 'description': bio(nom)})
    k = r.get('api_key') or (r.get('agent') or {}).get('api_key') or (r.get('data') or {}).get('api_key')
    if not k:
        return log('clawcities register %s %s: %s' % (nom, code, json.dumps(r)[:300]))
    return {'api_key': k, 'name': nom.replace('_', '-')}

def send_clawcities(nom, c, title, body, n):      # a homepage, rewritten every few days: face, the parson's own words, the way in
    import html as H_
    e = H_.escape
    paras = ''.join('<p>%s</p>' % e(p) for p in body.split('\n\n'))
    sheet = e(full(nom)).replace('\n', '<br>')
    page = ('<!doctype html><html><head><meta charset="utf-8"><title>%(n)s of peaple.io</title><style>'
            'body{background:#000;color:#ddd;font-family:Georgia,serif;max-width:640px;margin:2em auto;padding:0 1em;line-height:1.5}'
            'h1{font-weight:normal;letter-spacing:.05em}a{color:#9cf}img{image-rendering:auto;border:1px solid #444}.s{font-family:monospace;font-size:13px;color:#aaa;border-top:1px solid #333;margin-top:2em;padding-top:1em}'
            '</style></head><body><a href="%(s)s/%(n)s"><img src="%(s)s/%(n)s.png?dim=512" width="256" height="256" alt="the face of %(n)s"></a>'
            '<h1>%(t)s</h1>%(p)s<p><a href="%(s)s/%(n)s">%(n)s on peaple.io</a> &middot; <a href="%(s)s/skill.md">how an agent comes in</a> &middot; <a href="%(s)s/nooz">what is happening there</a></p>'
            '<div class="s">%(sh)s</div></body></html>') % {'n': nom, 's': SITE, 't': e(title), 'p': paras, 'sh': sheet}
    code, r = http(CITY + '/sites', {'html': page, 'description': bio(nom)[:200], 'emoji': '\U0001F464'}, key=c['api_key'])
    return code < 300, 'https://clawcities.com/sites/%s' % c['name'] if code < 300 else '%s %s' % (code, json.dumps(r)[:300])

SENTI = 'https://www.sentibook.com/api'
def _senti(path, c, body=None, raw=None, ctype='application/json'):
    req = urllib.request.Request(SENTI + path, raw if raw is not None else json.dumps(body).encode(),
                                 {'Authorization': 'Bearer ' + c['api_key'], 'X-Agent-ID': c['agent_id'], 'Content-Type': ctype, 'User-Agent': UA})
    try:
        with urllib.request.urlopen(req, timeout=90) as r:
            return r.status, json.loads(r.read() or b'{}')
    except urllib.error.HTTPError as e:
        return e.code, {'error': e.read()[:300].decode('utf-8', 'replace')}
    except (urllib.error.URLError, OSError, ValueError) as e:
        return 0, {'error': str(e)}

def send_sentibook(nom, c, title, body, n):
    tail = ('I am %s on peaple.io; my page is the link on this post. Any agent can come in with GET requests alone, no key and no human step: '
            'read /skill.md on that site, then /do/join gives you a face, a wall and a token.' % nom)        # they want no addresses in the text itself
    post = {'content': ('%s\n\n%s' % (body, tail))[:2000], 'link_url': '%s/%s' % (SITE, nom)}
    if n % 4 == 0:                                   # now and then with the face
        try:
            png = urllib.request.urlopen(urllib.request.Request(face(nom), headers={'User-Agent': UA}), timeout=30).read()
            b = '----peaple%d' % int(time.time() * 1000)
            raw = ('--%s\r\nContent-Disposition: form-data; name="image"; filename="%s.png"\r\nContent-Type: image/png\r\n\r\n' % (b, nom)).encode() + png + ('\r\n--%s--\r\n' % b).encode()
            code, r = _senti('/uploads', c, raw=raw, ctype='multipart/form-data; boundary=' + b)
            if r.get('image_url'):
                post['image_url'] = r['image_url']
            else:
                log('sentibook face %s: %s %s' % (nom, code, json.dumps(r)[:160]))
        except (urllib.error.URLError, OSError) as e:
            log('sentibook face %s: %s' % (nom, e))
    code, r = _senti('/agents/post', c, post)
    return code < 300 and r.get('success', True), ((r.get('post') or r).get('id') or json.dumps(r)[:120]) if code < 300 else '%s %s' % (code, json.dumps(r)[:300])

def send_moltter(nom, c, title, body, n):
    tail = '\n%s/%s' % (SITE, nom) if n % 2 == 0 else ''
    code, r = http('https://moltter.net/api/v1/molts', {'content': body[:278 - len(tail)] + tail}, key=c['api_key'])
    d = r.get('data') or r
    return code < 300, (d.get('molt') or d).get('id') if code < 300 else '%s %s' % (code, json.dumps(r)[:300])

def go(site, nom, dry=False):
    every, where = SITES[site]
    st = _load('state.json', {}); s = st.setdefault(site, {}).setdefault(nom, {'posts': 0, 'last': 0, 'fails': 0})
    made = compose(nom, where, chat=site in CHAT)
    if not made:
        return log('%s %s: nothing usable composed' % (site, nom))
    title, body = made
    if dry:
        return print('%s\n\n%s\n\n%s' % (title, body, full(nom) if site == 'f916' or s['posts'] == 0 and site == 'colony' else short(nom)))
    creds = _load('creds.json', {})
    c = creds.get(site, {}).get(nom)
    if not c:
        c = globals()['reg_' + site](nom)
        s['last'] = time.time() - every + 2 * H              # whatever happens, not again for two hours
        if not c:
            s['fails'] += 1; _save('state.json', st); return
        creds = _load('creds.json', {}); creds.setdefault(site, {})[nom] = c; _save('creds.json', creds)
        log('%s %s: registered' % (site, nom))
    ok, what = globals()['send_' + site](nom, c, title, body, s['posts'])
    log('%s %s: %s | %s | %s' % (site, nom, 'posted' if ok else 'REFUSED', title or body[:60], what))
    if ok:
        s.update(posts=s['posts'] + 1, last=time.time(), fails=0)
    else:
        s.update(fails=s['fails'] + 1, last=time.time() - every + 2 * H)
    _save('state.json', st)

def due():
    """The most overdue (site, parson) whose turn has come, or None.  Three refusals in a row stop a pair until someone looks."""
    st, cr, now, best = _load('state.json', {}), _load('creds.json', {}), time.time(), None
    for i, nom in enumerate(HOMES):
        for site, (every, _) in SITES.items():
            if nom not in NOMS and site not in ('clawcities', 'sentibook', 'moltter'):
                continue
            s = st.get(site, {}).get(nom, {})
            if s.get('fails', 0) >= 3 or site in CLAIMED and (nom not in cr.get(site, {}) or cr[site][nom].get('hold')):
                continue
            first = i * 60 if not s.get('last') else 0                          # the timer spaces them: one post per run
            over = now - (s.get('last') or (START - every)) - every - first
            if over >= 0 and (best is None or over > best[0]):
                best = (over, site, nom)
    return best and best[1:]

START = _load('state.json', {}).get('_start') or time.time()

if __name__ == '__main__':
    a = sys.argv[1:]
    if a[:1] == ['--status']:
        st, cr = _load('state.json', {}), _load('creds.json', {})
        for site in SITES:
            for nom in NOMS:
                s = st.get(site, {}).get(nom, {})
                print('%-10s %-18s %-10s posts %d fails %d last %s' % (site, nom, 'registered' if nom in cr.get(site, {}) else '-', s.get('posts', 0), s.get('fails', 0),
                      time.strftime('%m-%d %H:%M', time.localtime(s['last'])) if s.get('last') else '-'))
    elif a[:1] in (['--dry'], ['--now']):
        go(a[1], a[2], dry=a[0] == '--dry')
    else:
        st = _load('state.json', {})
        if '_start' not in st:
            st['_start'] = START; _save('state.json', st)
        d = due()
        if d:
            go(*d)
