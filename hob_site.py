#!/usr/bin/env python3
"""hotorbot.ai, served locally: the page from ~/makemore/hob with its random seed substituted and its
peaple.io / fontasy / return links pointed at the local servers (peaple 8080, fontasy 8082, this site).
usage: hob_site.py [port]   (default 8083)
"""
import sys, os, random, socket, urllib.parse
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8083
HOB = os.environ.get('HOB_DIR', '/home/dan/makemore/hob')

class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, f, *a): sys.stderr.write("%s\n" % (f % a))
    def log_request(self, code='-', size='-'):
        import accesslog; accesslog.log(self, code)
    def send(self, code, ctype, body, cache=False):
        self.send_response(code); self.send_header('Content-Type', ctype); self.send_header('Content-Length', str(len(body)))
        if cache: self.send_header('Cache-Control', 'max-age=86400')
        self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        path = urllib.parse.urlsplit(self.path).path.strip('/')
        host = (self.headers.get('Host') or 'localhost').split(':')[0]
        if path in ('favicon.ico', 'hob.png'):
            try: return self.send(200, 'image/x-icon' if path.endswith('.ico') else 'image/png', open(os.path.join(HOB, path), 'rb').read(), True)
            except OSError: return self.send(404, 'text/plain', b'')
        if path not in ('', 'index', 'index.html'):
            return self.send(404, 'text/plain', b'not found')
        html = open(os.path.join(HOB, 'index.html'), encoding='utf-8').read()
        html = html.replace('$R0', str(random.getrandbits(32))).replace('$R1', str(random.getrandbits(32)))
        # black on white everywhere: drop the page's CSS inversion and use the renderer's default colors
        html = html.replace('filter: invert(1); ', '').replace('style="filter: invert(1)" ', '')
        if is_local(host):
            html = html.replace('https://peaple.io/button.png?', 'http://%s:8080/button.png?' % host)
            # breathing room between the bot / hot labels and the rating digits
            html = html.replace('<td><img src="http://%s:8080/button.png?txt=bot' % host, '<td style="padding-right: 20px"><img src="http://%s:8080/button.png?txt=bot' % host)
            html = html.replace('<td><img src="http://%s:8080/button.png?txt=hot' % host, '<td style="padding-left: 20px"><img src="http://%s:8080/button.png?txt=hot' % host)
            html = html.replace('https://peaple.io', 'http://%s:8080' % host)
            html = html.replace('https%3A%2F%2Fhotorbot%2Eai%2F', urllib.parse.quote('http://%s:%d/' % (host, PORT), safe=''))
            html = html.replace('https://hotorbot.ai/', 'http://%s:%d/' % (host, PORT))
        return self.send(200, 'text/html; charset=utf-8', html.encode('utf-8'))

def is_local(host):
    """True for LAN/loopback hosts; public domains keep the page's real peaple.io / hotorbot.ai links."""
    return host in ('localhost', '127.0.0.1', '::1') or host.endswith('.local') or host[:1].isdigit() or host.startswith('[')

if __name__ == '__main__':
    class DualStack(ThreadingHTTPServer):
        address_family = socket.AF_INET6
        def server_bind(self):
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0); super().server_bind()
    print('hotorbot.ai on port %d' % PORT)
    DualStack(('::', PORT), H).serve_forever()
