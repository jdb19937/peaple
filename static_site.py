#!/usr/bin/env python3
"""Serve a static site directory: extensionless paths map to <name>.html, '/' to a chosen page.
usage: static_site.py <dir> <port> [index.html]
"""
import sys, os, mimetypes, urllib.parse
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
root, port = os.path.abspath(sys.argv[1]), int(sys.argv[2])
index = sys.argv[3] if len(sys.argv) > 3 else 'index.html'

def is_local(host):
    """True for LAN/loopback hosts (localhost, *.local, bare IPs); public domains keep the pages' real links."""
    return host in ('localhost', '127.0.0.1', '::1') or host.endswith('.local') or host[:1].isdigit() or host.startswith('[')

class H(SimpleHTTPRequestHandler):
    def __init__(self, *a, **k): super().__init__(*a, directory=root, **k)
    def translate_path(self, path):
        p = path.split('?', 1)[0].split('#', 1)[0].strip('/')
        if p == '': p = index
        elif '.' not in os.path.basename(p) and os.path.isfile(os.path.join(root, p + '.html')): p += '.html'
        return os.path.join(root, p)
    def do_GET(self):
        if self.path.split('?', 1)[0] == '/text.png':
            return self.text_png()
        if self.path.split('?', 1)[0] == '/headline.png':
            return self.headline_png()
        # pages hardcode the public peaple.io / fontasy image URLs; point them at the local servers
        fp = self.translate_path(self.path)
        if not fp.endswith('.html') or not os.path.isfile(fp): return super().do_GET()
        host = (self.headers.get('Host') or 'localhost').split(':')[0]
        html = open(fp, encoding='utf-8').read()
        if is_local(host):
            html = html.replace('https://peaple.io/button.png?', 'http://%s:8080/button.png?' % host)
            html = html.replace('https://peaple.io', 'http://%s:8080' % host)
        body = html.encode('utf-8')
        self.send_response(200); self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body))); self.send_header('Cache-Control', 'private, no-store'); self.end_headers()
        self.wfile.write(body)
    def text_png(self):
        """/text.png?txt=...&dim=8[&phont=they]: text rendered in a phont, proxied from the peaple devserver's
        fontasy route on port 8080 (phont= or theme= picks the font; default is the site's own 'they')."""
        import urllib.request
        query = self.path.split('?', 1)[1] if '?' in self.path else ''
        q = urllib.parse.parse_qs(query)
        phont = (q.get('phont') or q.get('theme') or ['they'])[0]
        try:
            r = urllib.request.urlopen('http://localhost:8080/fontasy/%s.png?%s' % (urllib.parse.quote(phont), query), timeout=120)
            body = r.read()
        except Exception as e:
            self.send_response(502); self.send_header('Content-Type', 'text/plain'); self.end_headers()
            self.wfile.write(('text render failed: %s' % e).encode()); return
        self.send_response(200)
        self.send_header('Content-Type', 'image/png')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', r.headers.get('Cache-Control') or 'no-cache')
        self.end_headers()
        self.wfile.write(body)
    def headline_png(self):
        """/headline.png?dim=8&phont=titulus[&n=10]: the Ford County Chronicle's top headline(s) (RSS, cached 10 min)
        rendered like /text.png.  n > 1 joins the first n headlines with ' +++ ' into one chyron strip that also
        ends with the separator, so two copies placed end to end scroll seamlessly.  Falls back to the paper's name."""
        import time, urllib.request, xml.etree.ElementTree as ET
        global _headlines
        now = time.time()
        if now - _headlines[0] > 600:
            titles = []
            try:
                xmltext = urllib.request.urlopen('https://fordcountychronicle.com/feed/', timeout=10).read()
                for item in ET.fromstring(xmltext).findall('./channel/item/title'):
                    if item.text: titles.append(_ascii(item.text)[:120])
            except Exception as e:
                sys.stderr.write('headline fetch failed: %s\n' % e)
            _headlines = (now, titles or _headlines[1] or ['Ford County Chronicle'])
        q = urllib.parse.parse_qs(self.path.split('?', 1)[1] if '?' in self.path else '')
        try: n = max(1, int(q.pop('n', ['1'])[0]))
        except ValueError: n = 1
        titles = _headlines[1][:n]
        q['txt'] = [titles[0] if n == 1 else ' +++ '.join(titles) + ' +++ ']
        self.path = '/text.png?' + urllib.parse.urlencode({k: v[0] for k, v in q.items()})
        return self.text_png()
    def log_message(self, f, *a): sys.stderr.write("%s\n" % (f % a))
    def log_request(self, code='-', size='-'):
        import accesslog; accesslog.log(self, code)

_headlines = (0.0, None)   # (fetched at, [titles]) cache for /headline.png
def _ascii(t):
    """Headline text for the phonts (96 printable ASCII glyphs): unescape entities, map curly quotes, dashes and
    ellipses to ASCII, drop anything else non-ASCII, collapse whitespace."""
    import html, unicodedata
    t = html.unescape(t)
    for a, b in (('\u2018', "'"), ('\u2019', "'"), ('\u201a', "'"), ('\u201c', '"'), ('\u201d', '"'), ('\u2013', '-'), ('\u2014', '-'),
                 ('\u2026', '...'), ('\u00a0', ' ')):
        t = t.replace(a, b)
    t = unicodedata.normalize('NFKD', t).encode('ascii', 'ignore').decode()
    return ' '.join(t.split())
print('serving %s on port %d (/ -> %s)' % (root, port, index))
import socket
class DualStack(ThreadingHTTPServer):
    address_family = socket.AF_INET6
    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()
DualStack(('::', port), H).serve_forever()
