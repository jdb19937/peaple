#!/bin/sh
# One-time Cloudflare Tunnel setup, run AFTER `cloudflared tunnel login` has written ~/.cloudflared/cert.pem.
# Creates the tunnel "peaple", writes ~/.cloudflared/config.yml routing the public hostnames to the local
# site servers, points each hostname's DNS at the tunnel (replacing the stale A records), and starts the
# user-level systemd service so the tunnel comes up at login/boot.
set -e
CF=$HOME/.local/bin/cloudflared
[ -f $HOME/.cloudflared/cert.pem ] || { echo "run: cloudflared tunnel login   (opens a browser) first"; exit 1; }
$CF tunnel list | grep -q ' peaple ' || $CF tunnel create peaple
ID=$($CF tunnel list --name peaple --output json | python3 -c 'import sys,json; print(json.load(sys.stdin)[0]["id"])')
cat > $HOME/.cloudflared/config.yml <<CFG
tunnel: $ID
credentials-file: $HOME/.cloudflared/$ID.json
ingress:
  - hostname: peaple.io
    service: http://localhost:8080
  - hostname: www.peaple.io
    service: http://localhost:8080
  - hostname: fontasy.peaple.io
    service: http://localhost:8082
  - hostname: makemoresoftware.com
    service: http://localhost:8081
  - hostname: www.makemoresoftware.com
    service: http://localhost:8081
  - hostname: hotorbot.ai
    service: http://localhost:8083
  - hostname: www.hotorbot.ai
    service: http://localhost:8083
  - service: http_status:404
CFG
$CF tunnel ingress validate
for h in peaple.io www.peaple.io fontasy.peaple.io makemoresoftware.com www.makemoresoftware.com hotorbot.ai www.hotorbot.ai; do
  $CF tunnel route dns --overwrite-dns peaple $h || echo "DNS route for $h failed (zone not on Cloudflare yet?)"
done
systemctl --user daemon-reload
systemctl --user enable --now cloudflared
loginctl enable-linger $USER 2>/dev/null || echo "enable-linger needs a password; without it the tunnel only runs while you are logged in"
sleep 3; systemctl --user --no-pager status cloudflared | head -5
echo "tunnel $ID up; test: curl -sI https://peaple.io/ | head -1"
