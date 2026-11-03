"""Shared access log for the site servers: one line per response in ~/tewel/ffhq.proj/run/access.log:
    <iso time> <client ip> <host> "<method> <path>" <status> "<user agent>"
Behind the Cloudflare tunnel the real client IP arrives in CF-Connecting-IP (X-Forwarded-For as fallback)."""
import time, os
PATH = os.path.expanduser('~/tewel/ffhq.proj/run/access.log')
def client_ip(handler):
    h = handler.headers
    return (h.get('CF-Connecting-IP') or (h.get('X-Forwarded-For') or '').split(',')[0].strip() or handler.client_address[0])
def log(handler, code='-'):
    try:
        h = handler.headers
        line = '%s %s %s "%s %s" %s "%s"\n' % (time.strftime('%Y-%m-%dT%H:%M:%S'), client_ip(handler), (h.get('Host') or '-').split(':')[0],
            handler.command, handler.path[:200], code, (h.get('User-Agent') or '-')[:160].replace('"', "'"))
        with open(PATH, 'a') as f: f.write(line)
    except Exception:
        pass
