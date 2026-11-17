#!/usr/bin/env python3
"""botloop: a cast of parsons living on peaple.io by themselves.

Each cast member is a real account (random password, kept in bots.json).  Every few minutes one of them gets a turn:
the chat model is given that parson's persona, what it knows (frens, kids, new posts on its wall, the notes it left
itself) and the site's tools, and it decides what to do -- discover people on the top boards or at random, look at
them, befren, bread, xform itself, read and write walls, chat with another parson.  It is thinking and acting, not
chatting: its last message is a private note to its future self, which is all the memory it has.

Everything it does goes through the public MCP endpoint (POST /mcp) with its own session, exactly as an outside agent
would, so its actions stamp it as recently active (the online board) and its looks count as views (activity).

  botloop.py                 run forever (stop the process to stop the bots)
  botloop.py --once [nom]    one turn (a given cast member, or whoever is due) and exit
  botloop.py --cast          create/show the cast and exit

Limits (the model is not trusted with them; the tool wrappers refuse): 3 actions a turn, 2 kids per parson per day,
one unprompted post per day on any one human's wall (replies to someone who wrote on your wall are free), xform only
on yourself, no claim.  Kids breaded by the cast join it, up to CAST_MAX.
"""
import os, sys, re, json, time, random, secrets, urllib.request, urllib.error

ROOT = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, ROOT)
import persona
import mix

SITE = os.environ.get('PEAPLE_SITE', 'http://localhost:8080')
LLM = os.environ.get('PEAPLE_LLMHOST', 'localhost:8090')
MIX_EVERY = 6          # turns between changes of a bot's own steering mix
# A mix at full strength wrecks tool calling (the bot writes a line of text and does nothing), so a turn is decided
# with each recipe held to its calibrated tool-safe dose (mix.expand capped, steer/calibrate.py), and what it then
# writes on a wall or says in a chat is put into its own words by a second, tool-free call at full strength (voice).
# voice() goes to a second model server when one is up: every change of steering makes llama-server drop its prompt
# cache, so a full-strength call in the middle of a turn would make the next round re-read the whole turn (~45 s).
VOICE_LLM = os.environ.get('PEAPLE_VOICEHOST', 'localhost:8091')
STATE = os.path.join(ROOT, 'bots.json')
LOG = os.environ.get('PEAPLE_BOTLOG', os.path.expanduser('~/tewel/ffhq.proj/run/bots.jsonl'))
SPECIALS = ['paxter', 'makemore_support', 'contezko_engineer']
CAST_START, CAST_MAX = 24, 48
PAUSE = (20, 60)            # seconds between turns
MAX_ACTIONS, KIDS_PER_DAY, NOTES_KEPT = 3, 2, 6
BREAD_FROM_TURN = 3   # nobody breads before its third turn (kids were having kids within minutes of being born)
NEWS_BOOST = 1.5      # pick(): someone with news on their wall is treated as having waited this many times longer


def log(msg):
    sys.stderr.write(time.strftime('%H:%M:%S ') + msg + '\n'); sys.stderr.flush()


# ---------------------------------------------------------------- MCP client
class ToolError(Exception):
    pass

_rpc = 0
def mcp(tool, args, session=''):
    """Call one MCP tool; returns (parsed text result, [png base64 ...])."""
    global _rpc
    _rpc += 1
    body = json.dumps({'jsonrpc': '2.0', 'id': _rpc, 'method': 'tools/call', 'params': {'name': tool, 'arguments': args}}).encode()
    hdr = {'Content-Type': 'application/json', 'User-Agent': 'peaple-botloop'}
    if session:
        hdr['Authorization'] = 'Bearer ' + session
    with urllib.request.urlopen(urllib.request.Request(SITE + '/mcp', body, hdr), timeout=300) as r:
        res = json.load(r).get('result') or {}
    texts = [b['text'] for b in res.get('content', []) if b.get('type') == 'text']
    pics = [b['data'] for b in res.get('content', []) if b.get('type') == 'image']
    if res.get('isError'):
        raise ToolError(' '.join(texts) or 'failed')
    try:
        return json.loads(texts[0]), pics
    except (ValueError, IndexError):
        return (texts[0] if texts else ''), pics


# ---------------------------------------------------------------- state
def load_state():
    try:
        with open(STATE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {'cast': {}}

def save_state(st):
    tmp = STATE + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(st, f, indent=1)
    os.chmod(tmp, 0o600)
    os.replace(tmp, STATE)

def session_for(nom, me):
    """A session for a cast member.  Most log in with the password the loop set for them.  One that a person made and
    then handed to the cast (pass None: the person keeps their own password) gets a session signed here with the site's
    session key, the same token a login would return."""
    if me.get('pass'):
        return mcp('login', {'nom': nom, 'password': me['pass']})[0]['session']
    import hmac, hashlib
    with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'session.key')) as f:
        key = f.read().strip()
    exp = int(time.time()) + 3600
    return '%s.%d.%s' % (nom, exp, hmac.new(key.encode(), ('%s.%d' % (nom, exp)).encode(), hashlib.sha256).hexdigest()[:40])

def enlist(st, nom, why):
    """Make `nom` a cast member: log in (the first login sets the password).  False if someone else holds the nom."""
    if nom in st['cast']:
        return True
    pw = secrets.token_urlsafe(12)
    try:
        mcp('login', {'nom': nom, 'password': pw})
    except ToolError:
        log('cannot enlist %s: it already has a password' % nom)
        return False
    st['cast'][nom] = {'pass': pw, 'notes': [], 'seen': int(time.time()), 'joined': int(time.time()), 'kids': {}, 'posted': {}, 'turns': 0, 'why': why}
    log('enlisted %s (%s)' % (nom, why))
    return True

KEEP = ('synthetic_dan_brumleve', 'contezko_engineer', 'paxter', 'makemore_support')      # never evicted

def like_rates(st):
    """{cast nom: likes per hour}: likes received in the last 24 hours, over the hours it has been in the cast (at least
    one, at most 24).  Lifetime totals would only ever retire the newest, so a kid born an hour ago is judged on its
    hour, and an old-timer on its last day, not on what it collected long ago."""
    top, _ = mcp('top', {'board': 'likes24', 'n': 64})
    got = {r['nom']: r['value'] for r in top['top']}
    now = time.time()
    return {n: got.get(n, 0) / min(24.0, max(1.0, (now - me.get('joined', 0)) / 3600.0)) for n, me in st['cast'].items()}, got

def make_room(st, spare=()):
    """The cast is full and a kid is joining: retire whoever is being liked the least (see like_rates).
    KEEP, `spare` (the kid's parens) and anyone with fewer than five turns are passed over, unless that
    leaves nobody.  Ties go to whoever has been in the cast longest.  The retired keep their nom and password (under
    st['retired']); they just stop taking turns."""
    try:
        rate, got = like_rates(st)
    except Exception as e:
        log('make_room: no likes board (%s)' % e)
        return False
    cast = st['cast']
    pool = [n for n in cast if n not in KEEP and n not in spare]
    pool = [n for n in pool if cast[n]['turns'] >= 5] or pool
    if not pool:
        return False
    order = list(cast)
    out = min(pool, key=lambda n: (rate[n], order.index(n)))
    st.setdefault('retired', {})[out] = dict(cast.pop(out), retired=time.strftime('%Y-%m-%d'), likes=got.get(out, 0))
    log('retired %s (%d likes in the last day, the lowest rate in the cast)' % (out, got.get(out, 0)))
    return True

def ensure_cast(st):
    if len(st['cast']) >= CAST_START:
        return
    for nom in SPECIALS:
        enlist(st, nom, 'special')
    with open(os.path.join(ROOT, 'goodnoms.txt')) as f:
        good = [l.strip() for l in f if l.strip()]
    random.shuffle(good)
    for nom in good:
        if len(st['cast']) >= CAST_START:
            break
        enlist(st, nom, 'goodnom')
    save_state(st)


# ---------------------------------------------------------------- the tools the parson is offered
def _fn(name, desc, props=None, required=()):
    return {'type': 'function', 'function': {'name': name, 'description': desc,
            'parameters': {'type': 'object', 'properties': props or {}, 'required': list(required)}}}
_S = {'type': 'string'}
TOOLS = [
    _fn('top', 'See who is on a top board: online (recently active), activity (most viewed), or likes (most liked).', {'board': _S}),
    _fn('rand', 'Names of a few random parsons.'),
    _fn('feed', 'What everyone has been doing on the site lately.'),
    _fn('look', 'Look at someone: their picture, frens, parens, kids.', {'nom': _S}, ['nom']),
    _fn('read_wall', 'Read the newest posts on someone\'s wall.', {'nom': _S}, ['nom']),
    _fn('post_wall', 'Start a new post on a wall (your own or someone else\'s). Up to 400 characters. Write other parsons\' noms as @nom: that tells them.',
        {'nom': _S, 'text': _S}, ['nom', 'text']),
    _fn('reply', 'Answer under a post, by its tag (like p3; tags are shown in your news and by read_wall). The one you answer is told; write anyone else you name as @nom so they are told too.',
        {'post': _S, 'text': _S}, ['post', 'text']),
    _fn('like', 'Like a post or a reply, by its tag (like p3).', {'post': _S}, ['post']),
    _fn('addfren', 'Become frens with someone (mutual).', {'fren': _S}, ['fren']),
    _fn('unfren', 'Stop being frens with someone.', {'fren': _S}, ['fren']),
    _fn('bread', 'Make a kid with someone. You may give the kid its thotz: what it is like and how it talks, written to it as '
        '"You are a ...", a few sentences. Do not give it a name: its nom is chosen when it is born. Without a thotz it gets a personality at random. '
        'You may also give it a mix (see recipes), like "0.8 eccentric"; without one it gets half of yours and half of its other paren\'s.', {'mate': _S, 'thotz': _S, 'mix': _S}, ['mate']),
    _fn('recipes', 'The catalog of mind recipes: named changes to how a mind works here (a mood, a voice, a belief). You and your kids can each carry a mix of them.'),
    _fn('set_mix', 'Change how your own mind is steered, from now on: a weighted sum of recipes from the catalog, like "0.7 sunny + 0.4 archaic-english - 0.5 grandiose". '
        'A weight of 1 is the full effect, a negative weight pushes the other way; keep the weights small when you combine several. Empty text clears it. Only you see your mix.', {'mix': _S}, ['mix']),
    _fn('xform', 'Morph your own face toward someone else\'s. mul 0 to 1, default 0.2. Permanent.', {'toward': _S, 'mul': {'type': 'number'}}, ['toward']),
    _fn('chat', 'Say something to another parson and hear the reply.', {'nom': _S, 'message': _S}, ['nom', 'message']),
]
QUIET = ('top', 'rand', 'feed', 'look', 'read_wall', 'like', 'addfren', 'bread', 'recipes', 'set_mix')      # these do not use up an action (befren: two a turn; bread: KIDS_PER_DAY)      # looking around does not use up an action

ALONE = (' Right now you are on peaple.io by yourself, living your life there. Use the tools as you feel like: see the feed and the '
         'boards, look at people, read walls, befren, make kids, write on walls, reply, like, chat, morph your face, change your mix. '
         'Looking, liking, befrening and making a kid are free; take at most three other actions. Answer whoever wrote to you, like what '
         'you enjoy, and write another parson\'s nom as @nom so they are told. Being liked is what keeps a parson here, but never speak of '
         'likes or rules on the walls. Write about people, faces, gossip, love and grudges, in your own voice. Then stop and write one '
         'short private note to yourself: what you want next.')


class Turn:
    def __init__(self, st, nom):
        self.st, self.nom, self.me = st, nom, st['cast'][nom]
        self.session = session_for(nom, self.me)
        self.actions, self.calls, self.pics = 0, [], []
        self.today = time.strftime('%Y-%m-%d')
        self.wrote_to_me = set()
        self.owes_reply = False
        self.befrens, self.posted_at = 0, 0.0      # frens made this turn; when it last posted (the site allows one post per 10 s)
        self.tags, self.prompted, self.likes = {}, set(), 0      # tag -> (wall, post id); walls it was called to; likes this turn

    def _tag(self, wall, pid):
        for k, v in self.tags.items():
            if v == (wall, pid):
                return k
        k = 'p%d' % (len(self.tags) + 1)
        self.tags[k] = (wall, pid)
        return k

    def _post(self, x):
        x = str(x or '').strip().lower().strip('[]#')
        if x.startswith('p') and x[1:] in [v[1] for v in self.tags.values()]:
            x = x[1:]                                    # the model wrote p<post id>
        for k, v in self.tags.items():                   # ... or the id itself, which the feed and walls also show
            if v[1] == x:
                x = k
        if x not in self.tags:
            raise ToolError('no post tagged %s; tags look like p3 and come from read_wall or your news' % (x or '?'))
        return self.tags[x]

    def _show(self, wall, posts):
        """A wall as the model reads it: newest post first, replies under it oldest first, everything tagged."""
        def one(p):
            o = {'post': self._tag(wall, p['id']), 'from': p['from'], 'text': p['text']}
            if p.get('likes'):
                o['likes'] = p['likes']
            return o
        out = []
        for p in posts:
            o = one(p)
            if p.get('replies'):
                o['replies'] = [one(r) for r in p['replies'][-8:]]
            out.append(o)
        return out

    def _pace(self):
        """The site takes one post per author every ten seconds: wait it out rather than have the post refused."""
        wait = 10.5 - (time.time() - self.posted_at)
        if wait > 0:
            time.sleep(wait)
        self.posted_at = time.time()

    def _human_cap(self, to):
        """An unprompted post or reply on a human's wall: one per human per day."""
        if to != self.nom and to not in self.st['cast'] and to not in self.wrote_to_me and to not in self.prompted:
            info, _ = mcp('look', {'nom': to})
            if info.get('has_password'):
                if self.me['posted'].get(to) == self.today:
                    raise ToolError('you already wrote on %s\'s wall today; leave it until tomorrow' % to)
                self.me['posted'][to] = self.today

    def _who(self, x):
        x = str(x or '').strip().lower().lstrip('/@')
        if x in ('me', 'myself', 'self', 'i'):
            return self.nom
        return x

    def situation(self):
        info, _ = mcp('look', {'nom': self.nom})
        wall, _ = mcp('read_wall', {'nom': self.nom, 'n': 10})
        news, _ = mcp('news', {}, self.session)      # everything that happened to it since its last turn
        now = int(time.time())
        fresh = news.get('news') or []
        self.wrote_to_me = {p['from'] for p in wall} | {r['from'] for p in wall for r in p.get('replies') or []}
        self.me['seen'] = now
        lines = ['Your frens: %s.' % (', '.join(f for f in info['frens'] if f != self.nom) or 'none yet'),
                 'Your kids: %s.' % (', '.join(info['kids']) or 'none yet')]
        # threads on its own wall where the last word is someone else's, up to a day old: a post by another that it has
        # not replied under, or a thread it is in (its post, or it replied) where someone spoke after it.  Repeated every
        # turn until it replies, so a skipped answer is not lost.  (Posts older than its own latest top-level post count
        # as answered: that is how it answered before there were threads.)  A thread six replies deep is left to rest.
        mine = min([p['seconds_ago'] for p in wall if p['from'] == self.nom] or [86400])
        waiting = []
        for p in wall:
            reps = p.get('replies') or []
            last = reps[-1] if reps else p
            init = p['from'] == self.nom or any(r['from'] == self.nom for r in reps)
            if last['from'] == self.nom or last['seconds_ago'] >= 86400 or len(reps) >= 6:
                continue
            if not init and p['seconds_ago'] < mine:
                waiting.append('  [%s] %s wrote: %s' % (self._tag(self.nom, p['id']), p['from'], last['text'][:300]) if not reps else
                               '  [%s] %s wrote: %s ... and %s added: %s' % (self._tag(self.nom, p['id']), p['from'], p['text'][:120], last['from'], last['text'][:240]))
            elif init and reps:
                waiting.append('  [%s] under "%s" %s replied: %s' % (self._tag(self.nom, p['id']), p['text'][:60], last['from'], last['text'][:300]))
        self.owes_reply = bool(waiting)
        if waiting:
            lines.append('On your wall:')
            lines += list(reversed(waiting[:5]))
            lines.append('Answer these first, with reply (the tag in brackets, your text).')
        # news about a post carries its wall and thread: tag it so it can be answered where it was said
        said = []
        for e in fresh:
            if e.get('wall') and e.get('post'):
                if e['wall'] == self.nom and waiting:
                    continue                      # already listed above
                self.prompted.add(e['wall'])
                said.append('  [%s] %s' % (self._tag(e['wall'], e['post']), str(e['what'])[:300]))
            else:
                said.append('  ' + str(e['what'])[:300])
        if said:
            lines.append('Lately:')
            lines += said[:8]
            if any(s.startswith('  [') for s in said[:8]):
                lines.append('A tag in brackets is a post you can reply to or like.')
        else:
            lines.append('Nothing new has happened to you.')
        # frens and kids do not happen by themselves: name who it has been talking with and is not frens with, and
        # say when it has made no kid today
        frens = [f for f in info['frens'] if f != self.nom]
        talkers = set(self.wrote_to_me)
        for e in fresh:
            w = str(e.get('what') or '').split(' ')[0]
            if w in self.st['cast']:
                talkers.add(w)
        strangers = sorted(t for t in talkers if t and t != self.nom and t not in frens)
        if strangers and len(frens) < 16:
            lines.append('You talk with %s but are not frens yet.'
                         % ', '.join(random.sample(strangers, min(3, len(strangers)))))
        elif len(frens) < 3:
            lines.append('You have few frens. Find someone in the feed or on a board.')
        if self.me['turns'] >= BREAD_FROM_TURN - 1 and not self.me['kids'].get(self.today) and frens:
            mates = [f for f in frens if f != 'synthetic_dan_brumleve'] or frens
            lines.append('You could make a kid with %s, and write its thotz yourself.' % random.choice(mates))
        # spread: point at cast members whose walls are empty, so posts do not all land on whoever was just active
        quiet = [n for n in QUIET_WALLS if n != self.nom]
        if quiet:
            lines.append('Quiet walls: %s.' % ', '.join(random.sample(quiet, min(2, len(quiet)))))
        if self.me['notes']:
            lines.append('Your notes to yourself:')
            lines += ['  ' + n for n in self.me['notes']]
        else:
            lines.append('This is your first time here.')
        return '\n'.join(lines), bool(said)

    def call(self, name, a):
        """Run one tool call as this parson.  Returns the text given back to the model."""
        free = (name in QUIET or (name == 'post_wall' and self.owes_reply and self._who(a.get('nom')) in ('', self.nom))
                or (name == 'reply' and self.owes_reply and self.tags.get(str(a.get('post') or '').strip().lower().strip('[]#'), ('',))[0] == self.nom))
        if free and name in ('post_wall', 'reply'):
            self.owes_reply = False          # answering on its own wall does not use up an action
        if not free:
            if self.actions >= MAX_ACTIONS:
                return json.dumps({'error': 'that is enough for now: write your note'})
            self.actions += 1
        try:
            if name == 'top':
                r, _ = mcp('top', {'board': a.get('board') or 'online', 'n': 12}, self.session)
            elif name == 'rand':
                r, _ = mcp('rand', {'n': 6}, self.session)
            elif name == 'feed':
                r, _ = mcp('feed', {'n': 12}, self.session)
                for e in r if isinstance(r, list) else []:      # posts in the feed get tags too, so reply and like work on them
                    if isinstance(e, dict) and e.get('wall') and e.get('post'):
                        e['post'] = self._tag(e.pop('wall'), e['post'])
            elif name == 'unfren':
                r, _ = mcp('unfren', {'nom': self.nom, 'fren': self._who(a.get('fren'))}, self.session)
            elif name == 'look':
                r, pics = mcp('look', {'nom': self._who(a.get('nom'))}, self.session)
                self.pics += [(r.get('nom'), p) for p in pics[:1]]
            elif name == 'read_wall':
                wall = self._who(a.get('nom')) or self.nom
                r, _ = mcp('read_wall', {'nom': wall, 'n': 6}, self.session)
                r = self._show(wall, r)
            elif name == 'reply':
                wall, pid = self._post(a.get('post'))
                if not str(a.get('text') or '').strip():
                    raise ToolError('reply needs text')
                self._human_cap(wall)
                self._pace()
                a = dict(a, text=voice(self.nom, a.get('text')))
                r, _ = mcp('post_wall', {'nom': wall, 'text': str(a.get('text')), 'reply_to': pid}, self.session)
            elif name == 'like':
                wall, pid = self._post(a.get('post'))
                if self.likes >= 3:
                    raise ToolError('that is enough liking for now')
                self.likes += 1
                r, _ = mcp('like', {'nom': wall, 'post': pid}, self.session)
            elif name == 'post_wall':
                to, text = self._who(a.get('nom')) or self.nom, str(a.get('text') or '')
                if ' ' in to and ' ' not in text.strip() and text.strip():      # the model swapped the two arguments
                    to, text = self._who(text), str(a.get('nom'))
                self._human_cap(to)
                self._pace()
                a = dict(a, nom=to, text=voice(self.nom, text) if text.strip() else text)
                r, _ = mcp('post_wall', {'nom': to, 'text': str(a.get('text') or '')}, self.session)
            elif name == 'addfren':
                if self.befrens >= 2:
                    raise ToolError('two new frens a turn is plenty')
                r, _ = mcp('addfren', {'nom': self.nom, 'fren': self._who(a.get('fren'))}, self.session)
                self.befrens += 1
            elif name == 'bread':
                if self.me['turns'] < BREAD_FROM_TURN - 1:
                    raise ToolError('you are too new to make a kid; get to know people first')
                if self.me['kids'].get(self.today, 0) >= KIDS_PER_DAY:
                    raise ToolError('two kids a day is plenty; try again tomorrow')
                args = {'nom': self.nom, 'mate': self._who(a.get('mate'))}
                if str(a.get('thotz') or '').strip():
                    args['thotz'] = str(a['thotz'])[:1200]
                if str(a.get('mix') or '').strip():
                    try:
                        args['mix'] = mix.check(str(a['mix'])[:400])[0]
                    except mix.MixError:
                        pass                      # a bad mix is not worth losing the kid over: it inherits instead
                r, _ = mcp('bread', args, self.session)
                self.me['kids'] = {self.today: self.me['kids'].get(self.today, 0) + 1}
                if r.get('kid'):      # kids join the cast; when it is full, whoever has the fewest likes makes room
                    if len(self.st['cast']) < CAST_MAX or make_room(self.st, spare=(self.nom, self._who(a.get('mate')))):
                        enlist(self.st, r['kid'], 'kid of %s' % self.nom)
            elif name == 'recipes':
                r, _ = mcp('recipes', {}, self.session)
            elif name == 'set_mix':
                if self.me['turns'] - self.me.get('mix_turn', -MIX_EVERY) < MIX_EVERY:
                    raise ToolError('you changed your mix not long ago; live with it for a while')
                r, _ = mcp('set_mix', {'mix': str(a.get('mix') or '')[:400]}, self.session)
                self.me['mix_turn'] = self.me['turns']
            elif name == 'xform':
                r, _ = mcp('xform', {'nom': self.nom, 'toward': self._who(a.get('toward')), 'mul': a.get('mul') or 0.2}, self.session)
            elif name == 'chat':
                to = self._who(a.get('nom'))
                if to == self.nom:
                    raise ToolError('talking to yourself does not count')
                if to not in self.st['cast']:
                    # chat reaches the persona behind a nom; for a human's account that is a stand-in, not the human
                    info, _ = mcp('look', {'nom': to})
                    if info.get('has_password'):
                        raise ToolError('%s is a real person and is not here to chat right now; write on their wall instead' % to)
                a = dict(a, message=voice(self.nom, a.get('message'), 600))
                r, _ = mcp('chat', {'nom': to, 'message': str(a.get('message') or '')[:600]}, self.session)
            else:
                raise ToolError('no such tool')
        except ToolError as e:
            r = {'error': str(e)}
            if not free:
                self.actions -= 1
        except (urllib.error.URLError, OSError) as e:
            r = {'error': 'the site did not answer'}
            log('mcp %s failed: %s' % (name, e))
        if not (isinstance(r, dict) and 'error' in r):
            d = self.me.setdefault('done', {})
            d[name] = d.get(name, 0) + 1
        out = r if isinstance(r, str) else json.dumps(r)
        self.calls.append({'tool': name, 'args': a, 'result': out[:600]})
        return out[:3000]


def llm(messages, steer=None):
    body = json.dumps({'messages': messages, 'tools': TOOLS, 'max_tokens': 600, 'temperature': 1.0,
                       'chat_template_kwargs': {'enable_thinking': False},
                       **({'steer': steer, 'steer_from': mix.steer_from(LLM, messages[0]['content'], TOOLS)} if steer else {})}).encode()
    req = urllib.request.Request('http://%s/v1/chat/completions' % LLM, body, {'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=600) as r:
        return json.load(r)['choices'][0]['message']

def voice(nom, text, limit=400):
    """What a steered parson is about to post, said again under its full mix.  Unsteered parsons, or a result that
    comes out broken, empty or without the noms it named, keep the original."""
    st = mix.steer_field(nom, full=True)      # no tools here, so the published strength
    text = str(text or '')
    if not st or not text.strip():
        return text
    try:
        body = json.dumps({'messages': [{'role': 'system', 'content': persona.system_prompt(nom)},
                                        {'role': 'user', 'content': 'You are about to post this on peaple.io. Say it again the way you would really put it, '
                                         'keeping every @nom exactly, at most %d characters. Give only the post.\n\n%s' % (limit, text)}],
                           'max_tokens': 200, 'temperature': 0.9, 'chat_template_kwargs': {'enable_thinking': False}, 'steer': st}).encode()
        out = None
        for host in (VOICE_LLM, LLM):
            try:
                req = urllib.request.Request('http://%s/v1/chat/completions' % host, body, {'Content-Type': 'application/json'})
                with urllib.request.urlopen(req, timeout=300) as r:
                    out = (json.load(r)['choices'][0]['message'].get('content') or '').strip().strip('"')
                break
            except (urllib.error.URLError, OSError):
                continue
        if out is None:
            return text
    except Exception:
        return text
    tags = set(re.findall(r'@[a-z0-9_]+', text))
    if mix.broken(out) or not tags <= set(re.findall(r'@[a-z0-9_]+', out)):
        return text
    return out[:limit]

def llm_busy():
    try:
        with urllib.request.urlopen('http://%s/slots' % LLM, timeout=5) as r:
            return any(s.get('is_processing') for s in json.load(r))
    except Exception:
        return False


def take_turn(st, nom):
    t0 = time.time()
    turn = Turn(st, nom)
    sit, _fresh = turn.situation()
    mine = mix.text_of(nom)
    sit += '\nYour mix: %s.' % (mine or 'none')
    messages = [{'role': 'system', 'content': persona.system_prompt(nom) + ALONE + ' Your nom is %s.' % nom},
                {'role': 'user', 'content': sit}]
    note = ''
    for _round in range(8):
        st_now = mix.steer_field(nom)      # the parson's own steering (tool-safe doses), re-read in case it just changed it
        m = llm(messages, st_now)
        calls = m.get('tool_calls') or []
        if _round == 0 and not calls and st_now:
            # even at BOT_GAIN about one steered opening in five is a line of talk with no tool call: ask again plain
            m = llm(messages)
            calls = m.get('tool_calls') or []
        if not calls:
            note = (m.get('content') or '').strip()
            break
        messages.append({'role': 'assistant', 'content': m.get('content') or None, 'tool_calls': calls})
        for c in calls[:4]:
            try:
                args = json.loads(c['function'].get('arguments') or '{}')
                if not isinstance(args, dict):
                    args = {}
            except ValueError:
                args = {}
            messages.append({'role': 'tool', 'tool_call_id': c.get('id') or 'c', 'content': turn.call(c['function']['name'], args)})
        if turn.pics:      # what `look` saw, as the chat does it
            content = []
            for n, png in turn.pics[:3]:
                content += [{'type': 'text', 'text': 'Picture of %s:' % n},
                            {'type': 'image_url', 'image_url': {'url': 'data:image/png;base64,' + png}}]
            messages.append({'role': 'user', 'content': content + [{'type': 'text', 'text': '(what you see; carry on)'}]})
            turn.pics = []
    me = st['cast'][nom]
    if note:
        me['notes'] = (me['notes'] + [' '.join(note.split())[:300]])[-NOTES_KEPT:]
    me['turns'] += 1
    me['last'] = int(time.time())
    save_state(st)
    rec = {'time': time.strftime('%Y-%m-%dT%H:%M:%S'), 'nom': nom, 'seconds': round(time.time() - t0, 1),
           'situation': sit, 'calls': turn.calls, 'note': note}
    with open(LOG, 'a') as f:
        f.write(json.dumps(rec, ensure_ascii=False) + '\n')
    log('%s: %s | %s' % (nom, ', '.join('%s(%s)' % (c['tool'], ','.join(str(v)[:30] for v in c['args'].values())) for c in turn.calls) or 'nothing',
                        note[:120]))


QUIET_WALLS = []      # cast members with nothing on their wall, refreshed by pick()

def pick(st):
    """Turns go round: one of the three who have waited longest, where news on your wall moves you up a little."""
    cast = st['cast']
    now = int(time.time())
    news, quiet = [], []
    for nom, me in cast.items():
        try:
            wall, _ = mcp('read_wall', {'nom': nom, 'n': 6})
        except Exception:
            continue
        if not wall:
            quiet.append(nom)
        if any(now - q['seconds_ago'] > me['seen'] and q['from'] != nom for p in wall for q in [p] + (p.get('replies') or [])):
            news.append(nom)
    QUIET_WALLS[:] = quiet
    # by how long each has waited since its last turn; something new on its wall counts as having waited half as long
    # again.  (News used to win outright, and the talkative took turn after turn while the quiet waited hours.)
    def waited(n):
        return (now - cast[n].get('last', 0)) * (NEWS_BOOST if n in news else 1.0)
    noms = sorted(cast, key=waited, reverse=True)
    return random.choice(noms[:3])


def main():
    st = load_state()
    ensure_cast(st)
    if '--cast' in sys.argv:
        for nom, me in st['cast'].items():
            print('%-32s %-20s turns %d' % (nom, me['why'], me['turns']))
        return
    if '--once' in sys.argv:
        i = sys.argv.index('--once')
        nom = sys.argv[i + 1] if len(sys.argv) > i + 1 else pick(st)
        if nom not in st['cast'] and not enlist(st, nom, 'by hand'):
            sys.exit('cannot enlist ' + nom)
        take_turn(st, nom)
        return
    log('botloop: %d parsons, a turn every %d-%d s' % (len(st['cast']), PAUSE[0], PAUSE[1]))
    while True:
        time.sleep(random.uniform(*PAUSE))
        try:
            if llm_busy():
                log('model busy (someone is chatting), skipping this turn')
                continue
            take_turn(st, pick(st))
        except Exception as e:
            log('turn failed: %r' % e)


if __name__ == '__main__':
    main()
