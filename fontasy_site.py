#!/usr/bin/env python3
"""fontasy.io, served locally: the font pages and PNG endpoints from makemore's agent, on the tewel font model.

Routes (as the original):
  /                      -> redirect to a random generated font name
  /default               -> redirect to the theme cookie's font, else /they
  /<nom>                 -> fsy/index.html with $NOM and four related names $CNOM0..3
  /<nom>.png?txt=&dim=&fg=&bg=   text in that font (dim 8/16/32/64 -> 2dim x 3dim px per char)
  /<nom>.png?dim=        the whole glyph sheet (dim 4/8/16/32 -> 24*dim px square)
  /default.png, /random.png, /favicon.ico
usage: fontasy_site.py [port]   (default 8082)
"""
import sys, os, io, re, random, urllib.parse
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import devserver as fx          # fetch_sheet(), nom_vec(), STATIC_PHONTS, FONT_HOST
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from PIL import Image

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8082
FSY = os.environ.get('FONTASY_FSY', '/home/dan/makemore/fsy')
NOMS = [l.strip() for l in open(os.environ.get('FONTASY_NOMS', '/home/dan/datasets/fonts/fontnoms.txt')) if l.strip()]
VALID = re.compile(r'^[a-z][a-z0-9_]{0,31}$')


def gennom():
    a = random.choice(NOMS)
    return a if random.randrange(4) else a + '_' + random.choice(NOMS)


def gennom_rel(rel):
    r = rel
    if '_' in rel:
        r = rel.split('_', 1)[random.randrange(2)]
    if r != rel and random.randrange(32) == 0:
        return r
    b = random.choice(NOMS)
    while b == r:
        b = random.choice(NOMS)
    return r + '_' + b if random.randrange(2) else b + '_' + r


def parsecol(s, default):
    if not s:
        return default
    s = s.strip().lstrip('#')
    if s.lower().startswith('0x'):
        s = s[2:]
    try:
        v = int(s, 16)
    except ValueError:
        return default
    return ((v >> 16) & 255, (v >> 8) & 255, v & 255)


def colorize(img, fg, bg, fga=255, bga=255):
    """Phont::print semantics: ink = (255 - value) / 255 per channel; color = fg * ink + bg * (1 - ink),
    alpha = fga * ink + bga * (1 - ink) (ink averaged over channels). Opaque RGB unless an alpha is below 255."""
    import numpy as np
    a = np.asarray(img.convert('RGB'), dtype=np.float32) / 255.0
    ink = 1.0 - a
    out = np.array(fg, dtype=np.float32)[None, None, :] * ink + np.array(bg, dtype=np.float32)[None, None, :] * (1.0 - ink)
    out = out.clip(0, 255).astype('uint8')
    if fga >= 255 and bga >= 255:
        return Image.fromarray(out)
    k = ink.mean(axis=2)
    alpha = (fga * k + bga * (1.0 - k)).clip(0, 255).astype('uint8')
    return Image.fromarray(np.dstack([out, alpha]), 'RGBA')


def render(nom, txt, dim, fg, bg, fga=255, bga=255):
    sheet = fx.fetch_sheet(nom)
    side = sheet.size[0]
    u = side // 24
    cw, ch = 2 * u, 3 * u
    o = (side - 24 * u) // 2
    if txt == '':
        grid = sheet.crop((o, o, o + 24 * u, o + 24 * u)).resize((24 * dim, 24 * dim), Image.LANCZOS)
        return colorize(grid, fg, bg, fga, bga)
    cells = []
    for c in txt:
        code = ord(c)
        if code < 0x20 or code > 0x7E:
            code = 0x7F
        i = code - 0x20
        cells.append(sheet.crop((o + (i % 12) * cw, o + (i // 12) * ch, o + (i % 12 + 1) * cw, o + (i // 12 + 1) * ch)))
    strip = Image.new(sheet.mode, (cw * len(cells), ch), 255 if sheet.mode == 'L' else (255, 255, 255))
    for k, cell in enumerate(cells):
        strip.paste(cell, (k * cw, 0))
    strip = strip.resize((2 * dim * len(cells), 3 * dim), Image.LANCZOS)
    return colorize(strip, fg, bg, fga, bga)


class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, f, *a):
        sys.stderr.write("%s\n" % (f % a))

    def send(self, code, ctype, body, extra=()):
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def redirect(self, loc, extra=()):
        self.send_response(302)
        self.send_header('Location', loc)
        self.send_header('Content-Length', '0')
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()

    def cookie_theme(self):
        c = self.headers.get('Cookie') or ''
        m = re.search(r'(?:^|;\s*)theme=([a-z0-9_]+)', c)
        return m.group(1) if m else ''

    def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        q = urllib.parse.parse_qs(url.query)
        path = urllib.parse.unquote(url.path).strip('/')
        if path == 'favicon.ico':
            try:
                return self.send(200, 'image/x-icon', open(os.path.join(FSY, 'favicon.ico'), 'rb').read(), [('Cache-Control', 'max-age=86400')])
            except OSError:
                return self.send(404, 'text/plain', b'')
        fn, ext = (path.rsplit('.', 1) + ['html'])[:2] if '.' in path else (path, 'html')
        if fn == '':
            return self.redirect('/' + gennom())
        theme = self.cookie_theme()
        if ext == 'png':
            if fn == 'default':
                fn = theme if VALID.match(theme) and theme != 'default' else 'they'
                return self.redirect('/%s.png%s' % (fn, '?' + url.query if url.query else ''))
            cache = 86400
            if fn == 'random':
                fn = gennom(); cache = 0
            if not VALID.match(fn):
                return self.send(404, 'text/plain', b'no such font')
            txt = q.get('txt', [''])[0]
            dim = int(q.get('dim', ['32' if txt == '' else '32'])[0] or 32)
            if dim not in (4, 8, 16, 32, 64):
                return self.send(404, 'text/plain', b'bad dim')
            fg = parsecol(q.get('fg', [''])[0], (0, 0, 0))
            bg = parsecol(q.get('bg', [''])[0], (255, 255, 255))
            def alpha(name):
                v = q.get(name, ['FF'])[0].strip().lstrip('#')
                try: return max(0, min(255, int(v, 16)))
                except ValueError: return 255
            try:
                img = render(fn, txt, dim, fg, bg, alpha('fga'), alpha('bga'))
            except Exception as e:
                sys.stderr.write('render failed: %s\n' % e)
                return self.send(502, 'text/plain', b'font server unavailable')
            buf = io.BytesIO(); img.save(buf, 'PNG')
            return self.send(200, 'image/png', buf.getvalue(), [('Cache-Control', 'public, max-age=%d' % cache)] if cache else [('Cache-Control', 'no-store')])
        if fn == 'default':
            return self.redirect('/' + (theme if VALID.match(theme) and theme != 'default' else 'they'))
        if fn == 'index':
            return self.redirect('/' + gennom())
        if not VALID.match(fn):
            return self.send(404, 'text/plain', b'no such font')
        extra = []
        if q.get('settheme'):
            extra.append(('Set-Cookie', 'theme=%s; Path=/; Max-Age=31536000' % fn))
        html = open(os.path.join(FSY, 'index.html'), encoding='utf-8').read()
        for k in range(4):
            html = html.replace('$CNOM%d' % k, gennom_rel(fn))
        html = html.replace('$NOM', fn)
        return self.send(200, 'text/html; charset=utf-8', html.encode('utf-8'), extra)


if __name__ == '__main__':
    import socket
    class DualStack(ThreadingHTTPServer):
        address_family = socket.AF_INET6
        def server_bind(self):
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
            super().server_bind()
    print('fontasy.io on port %d (font model at %s, static phonts in %s)' % (PORT, fx.FONT_HOST, fx.STATIC_PHONTS))
    DualStack(('::', PORT), H).serve_forever()
