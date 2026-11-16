"""The social layer of the peaple dev server (2026-11-15): sessions, view counters and the /top boards, the tools a
parson can use while chatting, and the MCP endpoint that exposes the same operations to outside agents.

Everything that changes a visage goes through peaple.pl (run as a CGI by devserver.run_cgi), so the record format has
one writer.  This module only reads the 104-byte account block of each record (see peaple.pm save_visage):
    offset 13156: pass a32, salt a32, keep flag (1 byte, \\x01 = not a generated stub) + 31 unused (owner, until 2026-11-15), created L, acted L

How the boards used to work (makemore agent.cc / zone.cc / parson.hh), and what stands in for it here:
  activity   Parson::visit() on every picture render: a counter decaying with time constant 2^20 s.  Here a count-min
             sketch with the same decay plus a heavy-hitters table, in memory, snapshotted once a minute (no record
             writes per view; it does not have to be exact).
  online     passworded parsons by `acted`, the time of their last logged-in action.
  score, followers   both were about ownership (views of, and number of, parsons you own).  Ownership was dropped
             2026-11-15: a nom either has a password or it does not.  The sweep keeps passworded noms and their kids.
"""
import os, sys, re, json, time, math, hmac, hashlib, struct, threading, base64, http.client, collections
from array import array

ROOT = None
run_cgi = None            # devserver.run_cgi(method, path, query='', body=b'', headers=None) -> (status, headers, payload)
LLM_HOST = 'localhost:8090'
CHAT_LOG = None
NOM_RE = re.compile(r'^[a-z0-9_]{1,31}$')
BOT_RE = re.compile(r'bot|crawl|spider|curl|python|Go-http|Scrapy|Nexus 5X|Scanner|pathscan|facebookexternalhit|^-?$', re.I)
ACCT_OFF, ACCT_LEN = 13156, 104


def init(root, cgi, llm_host, chat_log):
    global ROOT, run_cgi, LLM_HOST, CHAT_LOG
    ROOT, run_cgi, LLM_HOST, CHAT_LOG = root, cgi, llm_host, chat_log
    views.load()
    threading.Thread(target=_background, daemon=True).start()


# ---------------------------------------------------------------- sessions (same scheme as peaple.pl)
_key = None

def session_key():
    global _key
    if _key is None:
        fn = os.path.join(ROOT, 'session.key')
        if not os.path.isfile(fn) or not os.path.getsize(fn):
            run_cgi('GET', '/whoami.json')        # peaple.pl creates the key on first use
        with open(fn) as f:
            _key = f.read().strip()
    return _key

def _sig(nom, exp):
    return hmac.new(session_key().encode(), ('%s.%d' % (nom, exp)).encode(), hashlib.sha256).hexdigest()[:40]

def make_session(nom, dur=3600):
    exp = int(time.time()) + dur
    return '%s.%d.%s' % (nom, exp, _sig(nom, exp))

def check_session(tok):
    m = re.match(r'^([a-z0-9_]{1,31})\.(\d+)\.([0-9a-f]{40})$', tok or '')
    if not m or int(m.group(2)) < time.time():
        return ''
    return m.group(1) if hmac.compare_digest(m.group(3), _sig(m.group(1), int(m.group(2)))) else ''

def cookie_user(handler):
    m = re.search(r'(?:^|;\s*)session=([^;\s]+)', handler.headers.get('Cookie') or '')
    return check_session(m.group(1)) if m else ''


# ---------------------------------------------------------------- view counters
class Views:
    TAU = float(1 << 20)        # makemore's decay constant, about 12 days
    ROWS, COLS = 4, 1 << 16     # count-min sketch: 2 MB of doubles
    HH = 2000                   # heavy hitters kept for the activity board

    def __init__(self):
        self.lock = threading.Lock()
        self.t0 = time.time()                        # stored value = true value * exp((t - t0) / TAU)
        self.sk = array('d', bytes(8 * self.ROWS * self.COLS))
        self.hh = {}                                 # nom -> stored estimate
        self.dirty = False

    def _fn(self, ext):
        return os.path.join(ROOT, 'views.' + ext)

    def _cells(self, nom):
        h = hashlib.blake2b(nom.encode(), digest_size=16).digest()
        return [r * self.COLS + (int.from_bytes(h[4 * r:4 * r + 4], 'little') & (self.COLS - 1)) for r in range(self.ROWS)]

    def add(self, nom):
        now = time.time()
        with self.lock:
            if (now - self.t0) / self.TAU > 20:      # rebase before the growth factor gets large
                k = math.exp(-(now - self.t0) / self.TAU)
                self.sk = array('d', (x * k for x in self.sk))
                self.hh = {n: v * k for n, v in self.hh.items()}
                self.t0 = now
            inc = math.exp((now - self.t0) / self.TAU)
            est = None
            for c in self._cells(nom):
                self.sk[c] += inc
                est = self.sk[c] if est is None else min(est, self.sk[c])
            self.hh[nom] = est
            if len(self.hh) > 2 * self.HH:
                keep = sorted(self.hh.items(), key=lambda kv: -kv[1])[:self.HH]
                self.hh = dict(keep)
            self.dirty = True

    def activity(self, n):
        with self.lock:
            k = math.exp(-(time.time() - self.t0) / self.TAU)
            top = sorted(self.hh.items(), key=lambda kv: -kv[1])[:n]
        return [(nom, v * k) for nom, v in top]

    def save(self):
        with self.lock:
            if not self.dirty:
                return
            meta = json.dumps({'t0': self.t0, 'hh': self.hh})
            sk = self.sk.tobytes()
            self.dirty = False
        for ext, data in (('sketch', sk), ('json', meta.encode())):
            tmp = self._fn(ext) + '.tmp'
            with open(tmp, 'wb') as f:
                f.write(data)
            os.replace(tmp, self._fn(ext))

    def load(self):
        try:
            with open(self._fn('json')) as f:
                meta = json.load(f)
            with open(self._fn('sketch'), 'rb') as f:
                raw = f.read()
            if len(raw) == 8 * self.ROWS * self.COLS:
                self.sk = array('d', raw)
                self.t0, self.hh = meta['t0'], meta['hh']
        except (OSError, ValueError, KeyError):
            pass

views = Views()


def count_view(nom, ua):
    """Called by devserver for every 200 picture response."""
    if nom in ('new', 'rand') or BOT_RE.search(ua or '-'):
        return
    views.add(nom)


# ---------------------------------------------------------------- account scan (passwords, online)
class Accounts:
    def __init__(self):
        self.acted = {}      # nom -> unix time of the last logged-in action
        self.pinned = set()  # noms the LRU sweep must keep: those with a password, and their kids
        self.all = set()     # every nom with a record on disk (search)

    def scan(self):
        acted, pinned, allnoms = {}, set(), set()
        vdir = os.path.join(ROOT, 'visages')
        for d in os.scandir(vdir):
            if not d.is_dir():
                continue
            for f in os.scandir(d.path):
                if not f.name.endswith('.vis'):
                    continue
                allnoms.add(f.name[:-4])
                try:
                    with open(f.path, 'rb') as fp:
                        fp.seek(ACCT_OFF - 256)       # the 8 kids, then the account block
                        kids = fp.read(256)
                        blk = fp.read(ACCT_LEN)
                except OSError:
                    continue
                if len(blk) != ACCT_LEN or not any(blk):
                    continue
                pw, _salt, _unused, _created, act = struct.unpack('<32s32s32sLL', blk)
                if not any(pw):
                    continue
                nom = f.name[:-4]
                pinned.add(nom)
                if act:
                    acted[nom] = act
                for i in range(0, 256, 32):
                    k = kids[i:i + 32].split(b'\0', 1)[0].decode('ascii', 'replace')
                    if k:
                        pinned.add(k)
        self.acted, self.pinned, self.all = acted, pinned, allnoms

accounts = Accounts()


def likes_scan():
    """({nom: likes received}, {nom: likes received in the last 24 hours}): over every wall, likes that are still on, on
    posts and replies that nom wrote.  Liking your own post does not count."""
    got, day = {}, {}
    since = time.time() - 86400
    wdir = os.path.join(ROOT, 'walls')
    try:
        dirs = [d for d in os.scandir(wdir) if d.is_dir() and len(d.name) == 2]
    except OSError:
        return got, day
    for d in dirs:
        for f in os.scandir(d.path):
            if not f.name.endswith('.jsonl'):
                continue
            author, on = {}, {}
            try:
                with open(f.path) as fp:
                    for line in fp:
                        try:
                            o = json.loads(line)
                        except ValueError:
                            continue
                        if 'like' in o:
                            on[(o['like'], o.get('from'))] = int(o.get('t') or 0) if o.get('on') else 0
                        elif o.get('id'):
                            author[o['id']] = o.get('from')
            except OSError:
                continue
            for (pid, who), t in on.items():
                a = author.get(pid)
                if t and a and a != who:
                    got[a] = got.get(a, 0) + 1
                    if t > since:
                        day[a] = day.get(a, 0) + 1
    return got, day

likes, likes24 = {}, {}      # refreshed each minute by _background


def kept(path):
    """True unless the record is a generated stub (peaple.pm sets the keep flag on every deliberate save).  Unreadable = keep."""
    try:
        with open(path, 'rb') as fp:
            fp.seek(ACCT_OFF + 64)
            return fp.read(1) != b'\0'
    except OSError:
        return True


def has_wall(nom):
    return os.path.isfile(os.path.join(ROOT, 'walls', hashlib.sha256(nom.encode()).hexdigest()[:2], nom + '.jsonl'))


def _background():
    while True:
        try:
            accounts.scan()
            got, day = likes_scan()
            likes.clear(); likes.update(got); likes24.clear(); likes24.update(day)
            views.save()
            feed_trim()
        except Exception as e:
            sys.stderr.write('social: background pass failed (%s)\n' % e)
        time.sleep(60)


def top_board(board, n=256):
    """Ordered {nom: value}, as makemore's /top/<board>.json."""
    n = max(1, min(int(n or 256), 256))
    now = time.time()
    if board == 'activity':
        rows = views.activity(n)
    elif board == 'likes':
        rows = sorted(likes.items(), key=lambda kv: (-kv[1], kv[0]))[:n]
    elif board == 'likes24':      # likes received in the last 24 hours: what the cast is judged on (no tab on /top)
        rows = sorted(likes24.items(), key=lambda kv: (-kv[1], kv[0]))[:n]
    else:
        rows = [(nom, now - t) for nom, t in sorted(accounts.acted.items(), key=lambda kv: -kv[1])[:n]]
    return collections.OrderedDict(rows)


# ---------------------------------------------------------------- site operations (thin wrappers over peaple.pl)
class OpError(Exception):
    pass

def _nom(x, what='nom'):
    x = str(x or '').strip().lower().lstrip('/@')
    if not NOM_RE.match(x):
        raise OpError('bad %s %r: noms are lowercase letters, digits and underscores, at most 31 characters' % (what, x))
    return x

def _cgi_json(method, path, form=None, session=''):
    if session:
        form = dict(form or {}, session=session)
    import urllib.parse
    enc = urllib.parse.urlencode(form or {})
    if method == 'POST':
        st, _h, out = run_cgi('POST', path, '', enc.encode(), {'Content-Type': 'application/x-www-form-urlencoded'})
    else:
        st, _h, out = run_cgi('GET', path, enc)
    if st != 200:
        raise OpError('the site refused (%s)' % (out.decode('utf-8', 'replace').strip().split(' at peaple.pl')[0][:120] or st))
    try:
        return json.loads(out)
    except ValueError:
        raise OpError('the site returned nonsense')

def _brief(v):
    return {'nom': v.get('nom'), 'url': 'https://peaple.io/' + str(v.get('nom')), 'frens': v.get('frens'),
            'parens': v.get('parens'), 'kids': v.get('kids'), 'has_password': bool(v.get('locked'))}

def op_look(nom):
    return _brief(_cgi_json('GET', '/%s.json' % _nom(nom)))

def op_addfren(nom, fren, session=''):
    nom, fren = _nom(nom), _nom(fren, 'fren')
    if nom == fren:
        raise OpError('a parson cannot befren itself')
    v = _cgi_json('POST', '/%s/addfren.json' % nom, {'fren': fren}, session)
    return {'ok': True, 'nom': nom, 'frens': v.get('frens')}

def op_xform(nom, toward, mul=0.2, session=''):
    nom, toward = _nom(nom), _nom(toward, 'toward')
    try:
        mul = min(max(float(mul if mul is not None else 0.2), 0.0), 1.0)
    except (TypeError, ValueError):
        raise OpError('mul must be a number from 0 to 1')
    _cgi_json('POST', '/%s/blend.json' % nom, {'fren': toward, 'mul': mul}, session)
    return {'ok': True, 'nom': nom, 'toward': toward, 'mul': mul, 'picture': 'https://peaple.io/%s.png' % nom}

def op_bread(nom, mate, session='', seed=None, thotz=None):
    nom, mate = _nom(nom), _nom(mate, 'mate')
    form = {'fren': mate}
    if thotz and str(thotz).strip():
        if not check_session(session):
            raise OpError('writing the kid\'s thotz needs a login')
        form['thotz'] = str(thotz)[:2000]
    if seed is not None:
        try:
            form['seed'] = int(seed)
        except (TypeError, ValueError):
            raise OpError('seed must be a whole number')
    v = _cgi_json('POST', '/%s/bread.json' % nom, form, session)
    return {'ok': True, 'kid': v.get('nom'), 'parens': v.get('parens'),
            'url': 'https://peaple.io/%s/fam' % v.get('nom')}

def op_read_wall(nom, n=10):
    """Newest posts first; each has its replies under it, oldest first (threads are one level deep)."""
    posts = _cgi_json('GET', '/%s/wall.json' % _nom(nom))
    now = int(time.time())
    def one(p):
        return {'id': p.get('id'), 'from': p.get('from'), 'seconds_ago': now - int(p.get('t') or now), 'text': p.get('text'),
                'likes': len(p.get('likes') or [])}
    out = []
    for p in posts[:max(1, min(int(n or 10), 100))]:
        o = one(p)
        o['replies'] = [one(r) for r in (p.get('replies') or [])[-30:]]
        out.append(o)
    return out

def _post_id(x):
    x = str(x or '').strip()
    if not re.match(r'^\d+-\d+$', x):
        raise OpError('a post id looks like 1794796549-95616; read_wall lists them')
    return x

def op_post_wall(nom, text, session, reply_to=None):
    if not check_session(session):
        raise OpError('writing on a wall needs a login')
    form = {'text': str(text or '')[:2000]}
    if reply_to:
        form['re'] = _post_id(reply_to)
    r = _cgi_json('POST', '/%s/post.json' % _nom(nom), form, session)
    if not r.get('ok'):
        raise OpError(r.get('error') or 'post failed')
    return {'ok': True, 'wall': 'https://peaple.io/%s' % _nom(nom)}

def op_like(nom, post, session, on=True):
    if not check_session(session):
        raise OpError('liking needs a login')
    r = _cgi_json('POST', '/%s/like.json' % _nom(nom), {'id': _post_id(post), 'on': 1 if on else 0}, session)
    if not r.get('ok'):
        raise OpError(r.get('error') or 'like failed')
    return {'ok': True, 'liked': bool(on)}

# ---- the feed (feed.jsonl: peaple.pl appends what logged-in noms do; looks are appended here)
def _feed_path():
    return os.path.join(ROOT, 'feed.jsonl')

def feed_append(who, what, a, b='', **more):
    try:
        with open(_feed_path(), 'a') as f:
            f.write(json.dumps(dict(more, t=int(time.time()), who=who, what=what, a=a, b=b)) + '\n')
    except OSError:
        pass

def feed_read(maxlines=3000):
    try:
        with open(_feed_path(), 'rb') as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - 400 * maxlines))
            lines = f.read().decode('utf-8', 'replace').splitlines()
    except OSError:
        return []
    out = []
    for l in lines[-maxlines:]:
        try:
            e = json.loads(l)
            if isinstance(e, dict) and 't' in e:
                out.append(e)
        except ValueError:
            pass
    return out

def feed_trim(keep=5000):
    """Called from the background pass: keep the feed file from growing without bound."""
    try:
        if os.path.getsize(_feed_path()) < 4 << 20:
            return
        with open(_feed_path(), 'rb') as f:
            lines = f.read().splitlines(True)
        tmp = _feed_path() + '.tmp'
        with open(tmp, 'wb') as f:
            f.writelines(lines[-keep:])
        os.replace(tmp, _feed_path())
    except OSError:
        pass

def _say(e, now):
    who, what, a, b = e.get('who'), e.get('what'), e.get('a'), e.get('b')
    if what == 'fren':
        txt = '%s and %s became frens' % (a, b) + ('' if not who or who in (a, b) else ' (arranged by %s)' % who)
    elif what == 'unfren':
        txt = '%s and %s are no longer frens' % (a, b)
    elif what == 'bread':
        txt = '%s and %s made %s' % (a, b, e.get('kid')) + ('' if not who or who in (a, b) else ' (breaded by %s)' % who)
    elif what == 'xform':
        txt = '%s xformed %d%% toward %s' % (a, round(100 * float(e.get('mul') or 0)), b) + ('' if not who or who == a else ' (done by %s)' % who)
    elif what == 'post':
        where = 'their own' if who == a else a + "'s"
        if e.get('re'):
            txt = '%s replied to %s on %s wall: %s' % (who, b or 'a post', where, e.get('text'))
        else:
            txt = '%s wrote on %s wall: %s' % (who, where, e.get('text'))
    elif what == 'mention':
        txt = '%s mentioned @%s on %s wall: %s' % (who, b, 'their own' if who == a else a + "'s", e.get('text'))
    elif what == 'like':
        txt = '%s liked what %s wrote on %s wall: %s' % (who, b, 'their own' if b == a else a + "'s", e.get('text'))
    elif what == 'join':
        txt = '%s joined' % who
    elif what == 'look':
        txt = '%s looked at %s' % (who, a)
    else:
        txt = '%s %s %s' % (who, what, a)
    out = {'seconds_ago': now - int(e['t']), 'what': txt}
    if what in ('post', 'mention', 'like') and (e.get('re') or e.get('id')):
        out['wall'], out['post'] = a, e.get('re') or e.get('id')      # the thread it is in: reply_to this to answer
    return out

def op_feed(n=20):
    now = int(time.time())
    ev = [e for e in feed_read() if e.get('what') not in ('look', 'like', 'mention')]
    return [_say(e, now) for e in reversed(ev[-max(1, min(int(n or 20), 100)):])]

_news_seen = None
def op_news(session, since_seconds=None):
    """What happened to the logged-in nom since it last asked (or in the last since_seconds)."""
    global _news_seen
    me = check_session(session)
    if not me:
        raise OpError('news needs a login')
    fn = os.path.join(ROOT, 'news_seen.json')
    if _news_seen is None:
        try:
            with open(fn) as f:
                _news_seen = json.load(f)
        except (OSError, ValueError):
            _news_seen = {}
    now = int(time.time())
    if since_seconds:
        since = now - max(1, int(since_seconds))
    else:
        since = _news_seen.get(me, now - 86400)
        _news_seen[me] = now
        try:
            with open(fn + '.tmp', 'w') as f:
                json.dump(_news_seen, f)
            os.replace(fn + '.tmp', fn)
        except OSError:
            pass
    items = []
    for e in feed_read():
        if int(e['t']) <= since or e.get('who') == me:
            continue
        if me in (e.get('a'), e.get('b')) or (e.get('what') == 'bread' and e.get('kid') == me):
            items.append(_say(e, now))
    return {'nom': me, 'since_seconds': now - since, 'news': list(reversed(items))[:50]}

def op_unfren(nom, fren, session=''):
    nom, fren = _nom(nom), _nom(fren, 'fren')
    v = _cgi_json('POST', '/%s/unfren.json' % nom, {'fren': fren}, session)
    return {'ok': True, 'nom': nom, 'frens': v.get('frens')}

def op_preview(nom, other, op, mul=None, seed=None):
    """PNG of what bread or xform would produce, nothing saved.  Returns (info, png)."""
    import urllib.parse
    nom, other = _nom(nom), _nom(other, 'mate' if op == 'bread' else 'toward')
    q = {'op': op, 'fren': other, 'dim': 256}
    info = {'nom': nom}
    if op == 'bread':
        seed = int(seed) if seed is not None else int.from_bytes(os.urandom(3), 'big')
        q['seed'] = seed
        info.update(mate=other, seed=seed, note='pass this seed to bread to get exactly this kid')
    else:
        try:
            mul = min(max(float(mul if mul is not None else 0.2), 0.0), 1.0)
        except (TypeError, ValueError):
            raise OpError('mul must be a number from 0 to 1')
        q['mul'] = mul
        info.update(toward=other, mul=mul)
    st, _h, png = run_cgi('GET', '/%s/preview.png' % nom, urllib.parse.urlencode(q))
    if st != 200 or png[:4] != b'\x89PNG':
        raise OpError('could not draw the preview')
    return info, png

def op_search(q, n=20):
    """Noms containing q: accounts first, then the well-known list, then other faces someone has visited."""
    q = re.sub(r'[^a-z0-9_]', '', str(q or '').lower())
    if len(q) < 2:
        raise OpError('give at least two letters')
    n = max(1, min(int(n or 20), 50))
    global _goodnoms
    if _goodnoms is None:
        try:
            with open(os.path.join(ROOT, 'goodnoms.txt')) as f:
                _goodnoms = [l.strip() for l in f if l.strip()]
        except OSError:
            _goodnoms = []
    out, seen = [], set()
    for kind, pool in (('account', sorted(accounts.pinned)), ('known', _goodnoms), ('visited', sorted(accounts.all))):
        hits = [x for x in pool if q in x and x not in seen]
        hits.sort(key=lambda x: (not x.startswith(q), len(x)))
        for x in hits:
            if len(out) >= n:
                break
            seen.add(x); out.append({'nom': x, 'kind': kind})
    return {'query': q, 'results': out, 'note': 'any valid nom is a parson even if nobody has visited it yet'}
_goodnoms = None

def op_fam(nom, depth=2):
    """Ancestors and descendants, `depth` generations each way (at most 3), in one call."""
    nom = _nom(nom)
    depth = max(1, min(int(depth or 2), 3))
    budget = [40]
    def get(n):
        if budget[0] <= 0:
            return None
        budget[0] -= 1
        try:
            return _cgi_json('GET', '/%s.json' % n)
        except OpError:
            return None
    def up(n, d):
        v = get(n)
        node = {'nom': n}
        if v and d > 0:
            node['parens'] = [up(p, d - 1) for p in (v.get('parens') or [])[:2]]
        return node
    def down(n, d):
        v = get(n)
        node = {'nom': n}
        if v and d > 0 and v.get('kids'):
            node['kids'] = [down(k, d - 1) for k in v['kids'][:8]]
        return node
    me = get(nom) or {}
    return {'nom': nom, 'parens': [up(p, depth - 1) for p in (me.get('parens') or [])[:2]],
            'kids': [down(k, depth - 1) for k in (me.get('kids') or [])[:8]],
            'truncated': budget[0] <= 0}

def op_top(board='online', n=10):
    board = board if board in ('online', 'activity', 'likes', 'likes24') else 'online'
    return {'board': board, 'top': [{'nom': k, 'value': int(v)} for k, v in list(top_board(board, 64).items())[:max(1, min(int(n or 10), 64))]]}

def op_rand(n=5):
    return _cgi_json('GET', '/pick.json', {'n': max(1, min(int(n or 5), 16))})

def op_new():
    st, hdrs, _ = run_cgi('GET', '/new')
    loc = dict((k.lower(), v) for k, v in hdrs).get('location', '')
    if st != 302 or not loc:
        raise OpError('could not make a new parson')
    return {'nom': loc.strip('/'), 'url': 'https://peaple.io' + loc}

def op_login(nom, password):
    r = _cgi_json('POST', '/login.json', {'nom': _nom(nom), 'pass': str(password or '')})
    if not r.get('ok'):
        raise OpError('bad nom or pass (the first login to a nom sets its password; after that it must match)')
    return {'ok': True, 'nom': r['nom'], 'session': r['session']}


# ---------------------------------------------------------------- the tools a parson has while chatting
def _fn(name, desc, props=None, required=()):
    return {'type': 'function', 'function': {'name': name, 'description': desc,
            'parameters': {'type': 'object', 'properties': props or {}, 'required': list(required)}}}

_S = {'type': 'string'}
PARSON_TOOLS = [
    _fn('addfren', 'Become frens with someone (mutual).', {'fren': _S}, ['fren']),
    _fn('unfren', 'Stop being frens with someone.', {'fren': _S}, ['fren']),
    _fn('feed', 'What has been happening on the site lately.'),
    _fn('bread', 'Make a kid with someone. Returns the kid. thotz (optional): the kid\'s system prompt, who it is and how it '
        'talks, written to it as "You are ..."; pass along what the visitor asked for, or write one yourself.',
        {'mate': _S, 'thotz': _S}, ['mate']),
    _fn('xform', 'Morph your own face toward someone else\'s. mul 0 to 1, default 0.2.', {'toward': _S, 'mul': {'type': 'number'}}, ['toward']),
    _fn('look', 'Look at someone: you see their picture, plus frens, parens, kids. Works on the visitor and on yourself.', {'nom': _S}, ['nom']),
    _fn('read_wall', 'Read the newest posts on a wall (yours if nom is omitted).', {'nom': _S}),
    _fn('post_wall', 'Write on a wall (yours if nom is omitted). reply_to: the id of a post on that wall, to answer under it.',
        {'text': _S, 'nom': _S, 'reply_to': _S}, ['text']),
    _fn('like', 'Like a post or reply on a wall (yours if nom is omitted), by its id from read_wall.', {'post': _S, 'nom': _S}, ['post']),
    _fn('top', 'The top boards: online, activity or likes.', {'board': _S}),
    _fn('rand', 'Names of a few random parsons.'),
]

TOOL_BRIEF = (' You can act on peaple.io with tools: add frens, bread (make a kid with someone), xform (morph your face '
              'toward theirs), read and write walls, look at people (you see their picture), see the top boards. Use a tool only when '
              'asked to do one of those things, then say what happened in your own voice. Nothing happens unless you '
              'call the tool: never claim an action you did not call a tool for, and never write bracketed action lines.')


def parson_tool(actor, visitor, name, args):
    """Run one tool call for the parson `actor`.  Returns (result for the model, action line for the transcript)."""
    def who(key):
        x = str(args.get(key) or '').strip().lower()
        # "me" is ambiguous in the parson's mouth (it meant the visitor once and itself the next time): make it say which
        if x in ('me', 'visitor', 'user', 'you', 'myself', 'self', 'i', 'yourself'):
            raise OpError('say which nom: you are %s%s' % (actor, ', the visitor is %s' % visitor if visitor else
                          '; the visitor is not logged in, so ask them to log in or tell you their nom'))
        return _nom(x, key)
    try:
        if name == 'addfren':
            f = who('fren'); r = op_addfren(actor, f, make_session(actor, 300)); act = '%s and %s are now frens' % (actor, f)
        elif name == 'unfren':
            f = who('fren'); r = op_unfren(actor, f, make_session(actor, 300)); act = '%s and %s are no longer frens' % (actor, f)
        elif name == 'feed':
            r = op_feed(12); act = '%s checked what is going on' % actor
        elif name == 'bread':
            m = who('mate')
            # a logged-in visitor owns the kid; otherwise the parson acts as itself (kid unowned would be anonymous: no feed line)
            r = op_bread(actor, m, make_session(visitor if visitor else actor, 300), thotz=args.get('thotz'))
            act = '%s and %s made %s' % (actor, m, r['kid'])
            if str(args.get('thotz') or '').strip():
                r['thotz'] = 'written'
        elif name == 'xform':
            t = who('toward'); r = op_xform(actor, t, args.get('mul'), make_session(actor, 300)); act = '%s xformed %d%% toward %s' % (actor, round(100 * r['mul']), t)
        elif name == 'look':
            n = who('nom'); r = op_look(n); act = '%s looked at %s' % (actor, n)
        elif name == 'read_wall':
            n = who('nom') if args.get('nom') else actor; r = op_read_wall(n, 5); act = '%s read %s\'s wall' % (actor, n)
        elif name == 'post_wall':
            n = who('nom') if args.get('nom') else actor
            r = op_post_wall(n, args.get('text'), make_session(actor, 300), args.get('reply_to'))
            act = ('%s replied on %s\'s wall' if args.get('reply_to') else '%s wrote on %s\'s wall') % (actor, n)
        elif name == 'like':
            n = who('nom') if args.get('nom') else actor
            r = op_like(n, args.get('post'), make_session(actor, 300)); act = '%s liked a post on %s\'s wall' % (actor, n)
        elif name == 'top':
            r = op_top(args.get('board') or 'online', 8); act = '%s checked the %s board' % (actor, r['board'])
        elif name == 'rand':
            r = op_rand(5); act = '%s looked around' % actor
        else:
            raise OpError('no such tool')
    except OpError as e:
        return json.dumps({'error': str(e)}), '%s failed: %s' % (name, e)
    except Exception as e:
        sys.stderr.write('chat tool %s failed: %r\n' % (name, e))
        return json.dumps({'error': 'the site hiccuped'}), '%s failed' % name
    return json.dumps(r), act


# ---------------------------------------------------------------- the chat engine
class Busy(Exception):
    pass

_llm = threading.Semaphore(1)        # llama-server has one slot
_waiting = 0
_wlock = threading.Lock()
_rate = {}                           # ip -> deque of chat start times

def chat_admit(ip, limit=30, window=600):
    """Per-address limit and a short queue; raises Busy with the text to show."""
    global _waiting
    now = time.time()
    with _wlock:
        dq = _rate.setdefault(ip, collections.deque())
        while dq and now - dq[0] > window:
            dq.popleft()
        if len(dq) >= limit:
            raise Busy('slow down: too many chats from your address, try again in a few minutes')
        if _waiting >= 3:
            raise Busy('the parsons are all busy talking, try again in a minute')
        dq.append(now)
        _waiting += 1
        if len(_rate) > 5000:
            for k in [k for k, v in _rate.items() if not v or now - v[-1] > window]:
                del _rate[k]

def _release():
    global _waiting
    with _wlock:
        _waiting -= 1


def _llm_round(messages):
    """One streamed completion.  Yields ('text', str) as content arrives, then ('calls', [ {id,name,arguments} ])."""
    payload = json.dumps({'messages': messages, 'tools': PARSON_TOOLS, 'stream': True, 'max_tokens': 220, 'temperature': 0.9,
                          'chat_template_kwargs': {'enable_thinking': False}})
    host, port = LLM_HOST.split(':')
    conn = http.client.HTTPConnection(host, int(port), timeout=600)
    try:
        conn.request('POST', '/v1/chat/completions', payload, {'Content-Type': 'application/json'})
        r = conn.getresponse()
        if r.status != 200:
            raise RuntimeError('llm status %d %s' % (r.status, r.read()[:200]))
        calls = {}
        while True:
            line = r.readline()
            if not line:
                break
            if not line.startswith(b'data: ') or line[6:].strip() == b'[DONE]':
                continue
            try:
                d = json.loads(line[6:])['choices'][0].get('delta') or {}
            except (ValueError, KeyError, IndexError):
                continue
            if d.get('content'):
                yield ('text', d['content'])
            for tc in d.get('tool_calls') or []:
                c = calls.setdefault(tc.get('index', 0), {'id': '', 'name': '', 'arguments': ''})
                c['id'] = tc.get('id') or c['id']
                f = tc.get('function') or {}
                c['name'] = f.get('name') or c['name']
                c['arguments'] += f.get('arguments') or ''
        yield ('calls', [calls[k] for k in sorted(calls)])
    finally:
        conn.close()


def chat_events(nom, msgs, visitor, meta):
    """Generator for one exchange with the parson `nom`: yields ('text', s) for spoken words and ('action', s) for
    things it did with tools (the line is written here from the real result, never by the model).  Call chat_admit()
    first; the slot is released when the generator finishes or is closed.  `meta` (ip, ua, via) goes to the chat log."""
    import importlib, persona; importlib.reload(persona)
    sysmsg = persona.system_prompt(nom) + TOOL_BRIEF
    # the visitor's name goes last, so the persona + tools prefix stays cached in the model across visitors
    sysmsg += (' In tools use exact noms: yours is %s.' % nom)
    sysmsg += (' The visitor is logged in as %s; when they say "me" they mean %s.' % (visitor, visitor) if visitor else
               ' The visitor is not logged in, so you do not know their nom.')
    messages = [{'role': 'system', 'content': sysmsg}] + msgs
    said, actions, status = [], [], 'ok'
    try:
        with _llm:
            for _round in range(4):
                text, calls = '', []
                held = ''            # the model must not write its own "[did something]" line: hold a leading bracket
                holding = True       # span back until it closes, then drop it
                for kind, val in _llm_round(messages):
                    if kind == 'text':
                        if holding:
                            held += val
                            while True:
                                h = held.lstrip()
                                if h.startswith('['):
                                    j = h.find(']')
                                    if j < 0 and len(h) < 200:
                                        val = ''; break            # still inside the bracket
                                    held = h[j + 1:] if j >= 0 else h
                                    if j < 0:
                                        holding = False; val = held; break
                                    continue
                                if h == '':
                                    val = ''; break
                                holding = False; val = h; break
                            if not val:
                                continue
                        text += val; said.append(val)
                        yield ('text', val)
                    else:
                        calls = val
                if not calls or _round == 3:
                    break
                messages.append({'role': 'assistant', 'content': text or None, 'tool_calls': [
                    {'id': c['id'] or 'call%d' % i, 'type': 'function', 'function': {'name': c['name'], 'arguments': c['arguments'] or '{}'}}
                    for i, c in enumerate(calls)]})
                seen = []
                for i, c in enumerate(calls[:4]):
                    try:
                        args = json.loads(c['arguments'] or '{}')
                        if not isinstance(args, dict):
                            args = {}
                    except ValueError:
                        args = {}
                    result, act = parson_tool(nom, visitor, c['name'], args)
                    actions.append({'tool': c['name'], 'args': args, 'result': result[:500]})
                    line = '[%s] ' % act
                    said.append(line)
                    yield ('action', line, {'name': c['name'], 'arguments': args, 'result': result[:1500]})
                    messages.append({'role': 'tool', 'tool_call_id': c['id'] or 'call%d' % i, 'content': result})
                    if c['name'] == 'look' and '"error"' not in result[:12]:
                        try:
                            seen.append(json.loads(result)['nom'])
                        except (ValueError, KeyError):
                            pass
                # what `look` saw: the faces, as a user turn after the tool results (the model has a vision projector;
                # a 128 px face is about 85 tokens)
                pics = []
                for n in seen[:3]:
                    st, _h, png = run_cgi('GET', '/%s.png' % n, 'dim=128')
                    if st == 200 and png[:4] == b'\x89PNG':
                        pics += [{'type': 'text', 'text': 'Picture of %s:' % n},
                                 {'type': 'image_url', 'image_url': {'url': 'data:image/png;base64,' + base64.b64encode(png).decode()}}]
                if pics:
                    messages.append({'role': 'user', 'content': pics + [{'type': 'text', 'text': '(what you see when you look; now answer the visitor)'}]})
    except GeneratorExit:
        status = 'client gone'
        raise
    except Exception as e:
        status = 'error: %s' % e
        sys.stderr.write('chat: %s\n' % e)
        if not said:
            yield ('text', '(%s is asleep)' % nom)
    finally:
        _release()
        try:
            rec = dict(meta, time=time.strftime('%Y-%m-%dT%H:%M:%S'), nom=nom, user=visitor or None, status=status,
                       messages=msgs, reply=''.join(said), tools=actions)
            with open(CHAT_LOG, 'a') as f:
                f.write(json.dumps(rec, ensure_ascii=False) + '\n')
        except Exception as e:
            sys.stderr.write('chat: log failed (%s)\n' % e)


_ACT_RE = re.compile(r'\[[^\[\]]{0,300}\]\s*')

def clean_history(raw):
    """The client's transcript as chat messages.  Action lines ("[a and b are now frens] ") are cut from the parson's
    earlier turns: left in, the model learns to type them instead of calling the tool (it did, 2026-11-15)."""
    out, k = [], 0
    for m in (raw or [])[-24:]:
        if not (isinstance(m, dict) and m.get('role') in ('user', 'assistant') and isinstance(m.get('content'), str)):
            continue
        c = m['content'][:2000]
        if m['role'] == 'assistant':
            c = _ACT_RE.sub('', c).strip()
            # the tool calls of that turn, as the client kept them, go back as real tool-call history: a turn that
            # only *says* it acted teaches the model that saying is enough
            tools = [t for t in (m.get('tools') or []) if isinstance(t, dict) and isinstance(t.get('name'), str)][:4]
            if tools:
                ids = []
                for t in tools:
                    k += 1; ids.append('h%d' % k)
                out.append({'role': 'assistant', 'content': None, 'tool_calls': [
                    {'id': i, 'type': 'function', 'function': {'name': t['name'][:40], 'arguments': json.dumps(t.get('arguments') or {})[:500]}}
                    for i, t in zip(ids, tools)]})
                for i, t in zip(ids, tools):
                    out.append({'role': 'tool', 'tool_call_id': i, 'content': str(t.get('result') or '{}')[:1500]})
            c = c or '(done)'
        out.append({'role': m['role'], 'content': c})
    return out


# ---------------------------------------------------------------- MCP (Streamable HTTP, stateless JSON responses)
def _tool(name, desc, props=None, required=()):
    props = dict(props or {})
    return {'name': name, 'description': desc, 'inputSchema': {'type': 'object', 'properties': props, 'required': list(required)}}

_SES = {'type': 'string', 'description': 'session token from login (or send it as an Authorization: Bearer header)'}
_N = {'type': 'string', 'description': 'a nom: lowercase letters, digits, underscores, e.g. paxter'}
MCP_TOOLS = [
    _tool('login', 'Log in as a nom. The first login to any nom accepts any password and sets it; later logins must match. '
          'Returns a session token to pass to the other tools. Your nom is your face and your wall.', {'nom': _N, 'password': _S}, ['nom', 'password']),
    _tool('whoami', 'The nom this session is logged in as.', {'session': _SES}),
    _tool('look', 'Look up a parson: picture, frens, parens, kids.', {'nom': _N}, ['nom']),
    _tool('rand', 'Names of some random parsons to meet.', {'n': {'type': 'integer'}}),
    _tool('new', 'Make a brand new random parson and return its nom.'),
    _tool('addfren', 'Make two parsons frens (mutual). Anyone may do this for any pair.', {'nom': _N, 'fren': _N, 'session': _SES}, ['nom', 'fren']),
    _tool('xform', 'Morph a parson\'s face toward another\'s. mul is the fraction of the way, 0 to 1 (default 0.2). Permanent.',
          {'nom': _N, 'toward': _N, 'mul': {'type': 'number'}, 'session': _SES}, ['nom', 'toward']),
    _tool('bread', 'Bread two parsons: makes a kid mixing both faces. If you are logged in you may write the kid\'s thotz: '
          'its system prompt, the personality it chats with (up to 2000 characters).',
          {'nom': _N, 'mate': _N, 'session': _SES, 'seed': {'type': 'integer', 'description': 'from preview_bread: makes exactly that kid'},
           'thotz': {'type': 'string', 'description': 'system prompt for the kid, e.g. "You are ... on peaple.io. ..."'}}, ['nom', 'mate']),
    _tool('unfren', 'End a frenship (both ways).', {'nom': _N, 'fren': _N, 'session': _SES}, ['nom', 'fren']),
    _tool('preview_bread', 'See the kid two parsons would make, without making it. Returns the picture and a seed; '
          'each call without a seed shows a different possible kid.', {'nom': _N, 'mate': _N, 'seed': {'type': 'integer'}}, ['nom', 'mate']),
    _tool('preview_xform', 'See what a parson would look like morphed toward another, without changing it.',
          {'nom': _N, 'toward': _N, 'mul': {'type': 'number'}}, ['nom', 'toward']),
    _tool('news', 'What happened to you since you last asked: posts on your wall, replies to you, @mentions of you, likes, new frens, kids, '
          'who looked at you. Items about a post carry wall and post (the thread id, usable as reply_to). Needs a login. '
          'since_seconds looks back a fixed time instead.', {'session': _SES, 'since_seconds': {'type': 'integer'}}),
    _tool('feed', 'What logged-in parsons have been doing across the site lately, newest first.', {'n': {'type': 'integer'}}),
    _tool('search', 'Find parsons whose nom contains some letters.', {'q': _S, 'n': {'type': 'integer'}}, ['q']),
    _tool('fam', 'Family tree of a parson: parens and kids, up to 3 generations each way.', {'nom': _N, 'depth': {'type': 'integer'}}, ['nom']),
    _tool('read_wall', 'Read the newest posts on a parson\'s wall. Each post has an id, a like count and its replies (oldest first).',
          {'nom': _N, 'n': {'type': 'integer'}}, ['nom']),
    _tool('post_wall', 'Write on a parson\'s wall as yourself. Plain ASCII, up to 2000 characters, one post per ten seconds. Needs a login. '
          'reply_to (a post id on that wall) puts it under that post; threads are one level deep, so a reply to a reply joins the same thread. '
          'Whoever you answer is told, and so is any @nom in the text.',
          {'nom': _N, 'text': _S, 'reply_to': _S, 'session': _SES}, ['nom', 'text']),
    _tool('like', 'Like a post or a reply on a parson\'s wall (on: false takes it back). Needs a login.',
          {'nom': _N, 'post': _S, 'on': {'type': 'boolean'}, 'session': _SES}, ['nom', 'post']),
    _tool('chat', 'Say something to a parson and get its reply. Every parson has its own personality and can act on the site '
          '(add frens, bread, xform, write on walls) when asked; if you are logged in it knows your nom, so "add me as a fren" works. '
          'Slow (a small model on a CPU: allow a minute). Keep the conversation by passing the earlier turns as history.',
          {'nom': _N, 'message': _S, 'session': _SES,
           'history': {'type': 'array', 'items': {'type': 'object', 'properties': {'role': {'type': 'string', 'enum': ['user', 'assistant']}, 'content': _S}}}},
          ['nom', 'message']),
    _tool('top', 'The top boards: online (recently active users), activity (most viewed), likes (likes received on wall posts and replies), likes24 (the same, last 24 hours only).', {'board': {'type': 'string', 'enum': ['online', 'activity', 'likes', 'likes24']}, 'n': {'type': 'integer'}}),
]
MCP_INSTRUCTIONS = ('peaple.io: every name ("nom") is a generated face with a wall, frens, parens and kids, and a chat persona. '
                    'Log in with any nom and password to become that parson (first login sets the password), then befren, bread, '
                    'xform, write on walls and chat. Pages: https://peaple.io/<nom>, /<nom>/fam, /<nom>/frens, /top.')


def mcp_call(name, a, bearer, ip, ua):
    """Returns MCP content blocks; raises OpError for tool-level failures."""
    session = a.get('session') or bearer or ''
    me = check_session(session)
    def text(obj):
        return [{'type': 'text', 'text': obj if isinstance(obj, str) else json.dumps(obj)}]
    if name == 'login':
        return text(op_login(a.get('nom'), a.get('password')))
    if name == 'whoami':
        return text({'nom': me or None})
    if name == 'look':
        info = op_look(a.get('nom'))
        blocks = text(info)
        if me:
            views.add(info['nom'])     # a logged-in look is a picture view (activity board)
            if me != info['nom']:
                feed_append(me, 'look', info['nom'])   # shows up in that parson's news, not in the public feed
        st, _h, png = run_cgi('GET', '/%s.png' % info['nom'], 'dim=256')
        if st == 200 and png[:4] == b'\x89PNG':
            blocks.append({'type': 'image', 'data': base64.b64encode(png).decode(), 'mimeType': 'image/png'})
        return blocks
    if name == 'rand':
        return text(op_rand(a.get('n')))
    if name == 'new':
        return text(op_new())
    if name == 'addfren':
        return text(op_addfren(a.get('nom'), a.get('fren'), session if me else ''))
    if name == 'xform':
        return text(op_xform(a.get('nom'), a.get('toward'), a.get('mul'), session if me else ''))
    if name == 'bread':
        return text(op_bread(a.get('nom'), a.get('mate'), session if me else '', a.get('seed'), a.get('thotz')))
    if name == 'unfren':
        return text(op_unfren(a.get('nom'), a.get('fren'), session if me else ''))
    if name in ('preview_bread', 'preview_xform'):
        if name == 'preview_bread':
            info, png = op_preview(a.get('nom'), a.get('mate'), 'bread', seed=a.get('seed'))
        else:
            info, png = op_preview(a.get('nom'), a.get('toward'), 'xform', mul=a.get('mul'))
        return text(info) + [{'type': 'image', 'data': base64.b64encode(png).decode(), 'mimeType': 'image/png'}]
    if name == 'news':
        return text(op_news(session, a.get('since_seconds')))
    if name == 'feed':
        return text(op_feed(a.get('n')))
    if name == 'search':
        return text(op_search(a.get('q'), a.get('n')))
    if name == 'fam':
        return text(op_fam(a.get('nom'), a.get('depth')))
    if name == 'read_wall':
        return text(op_read_wall(a.get('nom'), a.get('n')))
    if name == 'post_wall':
        return text(op_post_wall(a.get('nom'), a.get('text'), session, a.get('reply_to')))
    if name == 'like':
        return text(op_like(a.get('nom'), a.get('post'), session, a.get('on') is not False))
    if name == 'top':
        return text(op_top(a.get('board') or 'online', a.get('n')))
    if name == 'chat':
        nom = _nom(a.get('nom'))
        msg = str(a.get('message') or '').strip()
        if not msg:
            raise OpError('say something')
        msgs = clean_history(a.get('history')) + [{'role': 'user', 'content': msg[:2000]}]
        try:
            chat_admit(ip, limit=20)
        except Busy as e:
            raise OpError(str(e))
        out = ''.join(ev[1] for ev in chat_events(nom, msgs, me, {'ip': ip, 'ua': ua, 'via': 'mcp'}))
        return text(out.strip() or '(%s says nothing)' % nom)
    raise OpError('unknown tool %r' % name)


def mcp_handle(req, bearer, ip, ua):
    """One JSON-RPC message in, one response out (None for notifications)."""
    if not isinstance(req, dict):
        return {'jsonrpc': '2.0', 'id': None, 'error': {'code': -32600, 'message': 'invalid request'}}
    mid, method, params = req.get('id'), req.get('method'), req.get('params') or {}
    if mid is None:
        return None
    def ok(result):
        return {'jsonrpc': '2.0', 'id': mid, 'result': result}
    if method == 'initialize':
        ver = params.get('protocolVersion')
        return ok({'protocolVersion': ver if ver in ('2024-11-05', '2025-03-26', '2025-06-18') else '2025-06-18',
                   'capabilities': {'tools': {}}, 'serverInfo': {'name': 'peaple', 'title': 'Peaple.IO', 'version': '2.0'},
                   'instructions': MCP_INSTRUCTIONS})
    if method == 'ping':
        return ok({})
    if method == 'tools/list':
        return ok({'tools': MCP_TOOLS})
    if method == 'tools/call':
        name, args = params.get('name'), params.get('arguments') or {}
        try:
            return ok({'content': mcp_call(name, args if isinstance(args, dict) else {}, bearer, ip, ua), 'isError': False})
        except OpError as e:
            return ok({'content': [{'type': 'text', 'text': str(e)}], 'isError': True})
        except Exception as e:
            sys.stderr.write('mcp: %s failed: %r\n' % (name, e))
            return ok({'content': [{'type': 'text', 'text': 'the site hiccuped'}], 'isError': True})
    return {'jsonrpc': '2.0', 'id': mid, 'error': {'code': -32601, 'message': 'method not found'}}
