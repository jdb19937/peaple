#!/usr/bin/perl

BEGIN {
  our $rootdir = $ENV{PEAPLE_ROOT} // "/var/www/html/perl";
}

use lib $rootdir;
use lib "$rootdir/lib";
use peaple;
use html;
use math;

our $peaple;
BEGIN {
  our $peaple = new peaple;
}

use CGI;
use JSON;

$CGI::LIST_CONTEXT_WARN = 0;
my $cgi = new CGI;
my $json = new JSON;

my $path = $ENV{PATH_INFO};
$path =~ s#^/+##;

# ---- sessions: "<nom>.<expiry>.<hmac>" in the `session` cookie (or a session= parameter, for the MCP server and the
# chat relay in devserver.py, which share $rootdir/session.key).  Login is makemore's: a nom with no password accepts
# any password and keeps it (cmd_be.cc); the nom then owns itself.
use Digest::SHA qw(hmac_sha256_hex sha256_hex);
my $session_key;
sub session_key {
  return $session_key if defined $session_key;
  my $fn = "$rootdir/session.key";
  if (!-s $fn) {
    open(my $ur, '<', '/dev/urandom') or die; read($ur, my $k, 32); close($ur);
    my $tmp = "$fn.$$.tmp";
    open(my $fp, '>', $tmp) or die "$tmp: $!"; print $fp unpack('H*', $k); close($fp);
    chmod 0600, $tmp;
    link($tmp, $fn); unlink($tmp);   # link fails if another request won the race; either way read what is there
  }
  open(my $fp, '<', $fn) or die "$fn: $!";
  $session_key = <$fp>; close($fp);
  chomp $session_key;
  $session_key
}
sub make_session {
  my ($nom, $dur) = @_;
  my $exp = int(time) + $dur;
  "$nom.$exp." . substr(hmac_sha256_hex("$nom.$exp", session_key()), 0, 40)
}
sub check_session {
  my $s = shift // '';
  $s =~ /^([a-z0-9_]{1,31})\.(\d+)\.([0-9a-f]{40})$/ or return '';
  my ($nom, $exp, $sig) = ($1, $2, $3);
  return '' if $exp < time;
  return '' unless $sig eq substr(hmac_sha256_hex("$nom.$exp", session_key()), 0, 40);
  $nom
}
sub print_json {
  my ($json, @hdr) = @_;
  print "Content-Type: text/json\r\n";
  print "$_\r\n" for @hdr;
  print "Content-Length: " . length($json) . "\r\n";
  print "\r\n";
  print $json;
}

# ---- walls: $rootdir/walls/<2 hex of sha256(nom)>/<nom>.jsonl, one JSON object per post, append-only (deletes rewrite).
# Outside the visage store, so the LRU sweep never touches them.
sub wall_path {
  my $wnom = shift;
  my $wd = "$rootdir/walls";
  -d $wd or mkdir($wd);
  my $d = "$wd/" . substr(sha256_hex($wnom), 0, 2);
  -d $d or mkdir($d);
  "$d/$wnom.jsonl"
}
sub wall_raw {   # every line of a wall, decoded, oldest first: posts, replies ("re": post id) and likes ("like": id, "on": 1/0)
  my $wnom = shift;
  my $fn = "$rootdir/walls/" . substr(sha256_hex($wnom), 0, 2) . "/$wnom.jsonl";
  open(my $fp, '<', $fn) or return ();
  my $js = JSON::PP->new;
  my @o;
  while (my $l = <$fp>) {
    my $o = eval { $js->decode($l) };
    push @o, $o if ref($o) eq 'HASH';
  }
  close($fp);
  @o
}
sub wall_read {   # top-level posts newest first, at most 100, as JSON text without the ip field; each carries
                  # likes (noms) and replies (oldest first, one level deep, each with its own likes)
  my $wnom = shift;
  my (@top, %kids, %likes);
  for my $o (wall_raw($wnom)) {
    delete $o->{ip};
    if (defined $o->{like}) {
      if ($o->{on}) { $likes{$o->{like}}{$o->{from}} = 1 } else { delete $likes{$o->{like}}{$o->{from}} }
    } elsif (defined $o->{re}) {
      push @{$kids{$o->{re}}}, $o;
    } else {
      push @top, $o;
    }
  }
  @top = reverse @top;
  splice(@top, 100) if @top > 100;
  my $js = JSON::PP->new->canonical(1);
  map {
    my $p = $_;
    # (likes of your own post, possible before 2026-11-15, are not shown or counted)
    $p->{likes} = [grep { $_ ne $p->{from} } sort keys %{$likes{$p->{id}} || {}}];
    $p->{replies} = [map { my $r = $_; $r->{likes} = [grep { $_ ne $r->{from} } sort keys %{$likes{$r->{id}} || {}}]; $r } @{$kids{$p->{id}} || []}];
    $js->encode($p)
  } @top
}

# ---- thotz: a nom's own system prompt, $rootdir/thotz/<2 hex of sha256(nom)>/<nom>.txt (persona.py reads it).
# Private: only the nom itself reads or writes it, except that whoever breads a kid may write the kid's first one.
sub thotz_path { my $n = shift; "$rootdir/thotz/" . substr(sha256_hex($n), 0, 2) . "/$n.txt" }
sub thotz_read {
  require Encode;
  open(my $fp, '<', thotz_path(shift)) or return '';
  local $/;
  my $t = Encode::decode('UTF-8', scalar(<$fp>) // '');
  close($fp);
  $t =~ s/\s+$//;
  $t
}
sub thotz_write {   # (nom, raw bytes from the form) -> error or undef.  Empty text removes the file: the hashed personality returns.
  my ($n, $raw) = @_;
  require Encode;
  my $text = eval { Encode::decode('UTF-8', $raw // '', Encode::FB_CROAK()) };
  defined $text or return 'not UTF-8';
  $text =~ s/\r\n?/\n/g;
  $text =~ s/[^\n\t\x20-\x7e\x{a0}-\x{10ffff}]//g;
  $text =~ s/^\s+|\s+$//g;
  $text = substr($text, 0, 2000);
  my $tfn = thotz_path($n);
  if ($text eq '') {
    unlink($tfn);
    return undef;
  }
  -d "$rootdir/thotz" or mkdir("$rootdir/thotz");
  my $td = "$rootdir/thotz/" . substr(sha256_hex($n), 0, 2);
  -d $td or mkdir($td);
  open(my $fp, '>', "$tfn.$$.tmp") or return "$tfn: $!";
  print $fp Encode::encode('UTF-8', $text), "\n";
  close($fp);
  rename("$tfn.$$.tmp", $tfn) or return 'rename failed';
  undef
}

# ---- the feed: $rootdir/feed.jsonl, one line per thing a logged-in nom did (fren, unfren, bread, xform, post, join).
# Someone not logged in is recorded with an empty `who` (since 2026-11-15; before that they were left out).  devserver.py (social.py) reads it for the MCP feed and news tools,
# appends `look` events itself, and trims it.
sub clip {   # the first n characters, with ... when something was left off
  my ($t, $n) = @_;
  length($t) > $n ? substr($t, 0, $n) . '...' : $t
}
sub feed_event {
  my ($who, $what, $a, $b, %more) = @_;
  my $line = JSON::PP->new->canonical(1)->encode(+{ t => int(time), who => $who, what => $what, a => $a, b => $b, %more });
  if (open(my $fp, '>>', "$rootdir/feed.jsonl")) {
    print $fp "$line\n";
    close($fp);
  }
}

my $user = '';
{
  my $tok = $cgi->param('session') // $cgi->url_param('session');
  if (!defined($tok) && ($ENV{HTTP_COOKIE} // '') =~ /(?:^|;\s*)session=([^;\s]+)/) {
    $tok = $1;
  }
  $user = check_session($tok);
}
# a logged-in POST is an action: stamp the user's `acted` (the "online" board on /top)
if ($user ne '' && ($ENV{REQUEST_METHOD} // '') eq 'POST') {
  my $uvis = $peaple->load_visage($user);
  if ($uvis) {
    $uvis->{acted} = int(time);
    $peaple->save_visage($uvis);
  }
}
$html::user = $user;
# the font selector in the header sets a `phont` cookie: every button and label drawn in mork by default follows it
if (($ENV{HTTP_COOKIE} // '') =~ /(?:^|;\s*)phont=(mork|they|ahoy|titulus)(?:;|$)/) {
  $html::phont = $1;
}
$html::header = html::header($user);

my %routenom = map { $_ => 1 } qw(new rand top nooz edit login logout mcp fontasy extra pick whoami button);

if ($path eq 'login.json') {
  my $lnom = lc($cgi->param('nom') // '');
  my $pass = $cgi->param('pass') // '';
  my $ok = 0;
  my $session = '';
  if ($lnom =~ /^[a-z0-9_]{1,31}$/ && !$routenom{$lnom} && length($pass) > 0 && length($pass) <= 256) {
    my $vis = $peaple->load_visage($lnom);
    if ($vis && $vis->check_pass($pass)) {
      feed_event($lnom, 'join', $lnom, '') unless $vis->has_pass;
      $vis->set_pass($pass) unless $vis->has_pass;
      $vis->{acted} = int(time);
      $peaple->save_visage($vis);
      $ok = 1;
      $session = make_session($lnom, 30 * 86400);
    }
  }
  my $out = encode_json(+{ ok => $ok, ($ok ? (nom => $lnom, session => $session) : (error => 'bad nom or pass')) });
  print_json($out, $ok ? ("Set-Cookie: session=$session; Path=/; Max-Age=2592000; HttpOnly; SameSite=Lax") : ());
  exit 0;
}

if ($path eq 'logout') {
  my $ret = $ENV{HTTP_REFERER} // '/';
  $ret = '/' unless $ret =~ m#^https?://[^/]+(/[\x21-\x7e]*)$# && ($ret = $1);
  print "Status: 302\r\n";
  print "Set-Cookie: session=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax\r\n";
  print "Location: $ret\r\n";
  print "Content-Length: 0\r\n";
  print "Content-Type: text/html\r\n";
  print "\r\n";
  exit 0;
}

if ($path eq 'whoami.json') {
  print_json(encode_json(+{ nom => $user }));
  exit 0;
}

# /nooz, /nooz.json: what everyone has been doing, newest first, from the feed: befrening, unfrening, breading, wall
# posts and replies (each linked to the post itself, /<wall>#p<id>), likes (linked to the liked post), xforming,
# joining.  Looks and @mention notices are left out.  The page redraws itself every 30 seconds.
if ($path =~ m#^nooz(\.json)?$#) {
  my $isjson = $1;
  my @ev;
  if (open(my $fp, '<', "$rootdir/feed.jsonl")) {
    my $size = -s $fp;
    seek($fp, $size - 400000, 0) if $size > 400000;     # the tail is plenty for 150 events
    my @l = <$fp>;
    close($fp);
    shift @l if $size > 400000;                           # a partial first line
    my $js = JSON::PP->new;
    for my $l (reverse @l) {
      next if $l =~ /"what":\s*"(?:look|mention)"/;
      my $e = eval { $js->decode($l) };
      next unless ref($e) eq 'HASH';
      push @ev, $e;
      last if @ev >= 150;
    }
  }
  my $evjson = JSON::PP->new->canonical(1)->ascii(1)->encode(\@ev);
  if ($isjson) {
    print_json($evjson);
    exit 0;
  }
  $evjson =~ s#</#<\\/#g;
  print "Content-Type: text/html\r\n\r\n";
  print <<"END";
    <html>
    <head>
    <title>peaple.io / nooz</title>
    </head>
    <body bgcolor="#000000" text="#ffffff" link="#9999ff" vlink="#bb99ff">
      $html::header
      <script>document.getElementById('headnooz').style.outline = '3px solid #00ff00';</script>
      <table width="1280" cellpadding="0" cellspacing="0"><tr><td>
        <div id="nooz"></div>
      </td></tr></table>
    <script>
    (function() {
      var ev = $evjson;
      var COLS = 70, CW = 16, CH = 24;
      var sheets = {}, loaded = 0;
      ['$html::phont', 'titulus'].forEach(function(n) {
        var im = new Image(); im.onload = function() { if (++loaded == 2) render(); };
        im.src = '/fontasy/' + n + '.png?grid=8'; sheets[n] = im;
      });
      function wrap(text, cols) {
        var lines = [], line = '';
        text.split(/\\s+/).forEach(function(w) {
          while (w.length > cols) { if (line) { lines.push(line); line = ''; } lines.push(w.substr(0, cols)); w = w.substr(cols); }
          if (!w) return;
          if (line && line.length + 1 + w.length > cols) { lines.push(line); line = w; }
          else line = line ? line + ' ' + w : w;
        });
        if (line) lines.push(line);
        return lines;
      }
      function drawText(ctx, phont, s, x, y, k) {
        var im = sheets[phont];
        for (var i = 0; i < s.length; ++i) {
          var c = s.charCodeAt(i); if (c < 0x20 || c > 0x7e) c = 0x7f;
          var g = c - 0x20;
          ctx.drawImage(im, (g % 12) * CW, Math.floor(g / 12) * CH, CW, CH, x + i * CW * k, y, CW * k, CH * k);
        }
      }
      function age(t) {
        var d = Math.max(0, Math.floor(Date.now() / 1000) - t);
        if (d < 120) return d + 's';
        if (d < 7200) return Math.floor(d / 60) + 'm';
        if (d < 172800) return Math.floor(d / 3600) + 'h';
        return Math.floor(d / 86400) + 'd';
      }
      // one event -> {text, other (the face shown on the right), href (where the row leads)}
      function say(e) {
        var a = e.a, b = e.b, who = e.who || a, wall = (a == who) ? 'their own wall' : '\@' + a + "'s wall";
        var at = e.id ? '#p' + e.id : '';      // the post itself, on the wall
        // events written before 2026-11-15 were cut at 160 (likes: 80) characters with nothing to show it
        if (e.t < 1794803466 && e.text && e.text.length == (e.what == 'like' ? 80 : 160)) e.text += '...';
        switch (e.what) {
          case 'post':
            if (e.re) return {text: 'replied to ' + (b && b != who ? '\@' + b : 'a post') + ' on ' + wall + ': ' + (e.text || ''), other: b && b != who ? b : a, href: '/' + a + at};
            return {text: 'wrote on ' + wall + ': ' + (e.text || ''), other: a, href: '/' + a + at};
          case 'like':
            return {text: 'liked what \@' + b + ' wrote on ' + (a == b ? 'their own wall' : a == who ? 'their wall' : '\@' + a + "'s wall") + ': ' + (e.text || ''), other: b, href: '/' + a + at};
          case 'fren':
            return {text: (who == a ? '' : '\@' + a + ' ') + 'befrended \@' + b, other: b, href: '/' + a + '/frens'};
          case 'unfren':
            return {text: (who == a ? '' : '\@' + a + ' ') + 'unfrended \@' + b, other: b, href: '/' + a + '/frens'};
          case 'bread':
            return {text: (who == a ? '' : '\@' + a + ' ') + 'breaded with \@' + b + ' and made \@' + e.kid, other: e.kid, href: '/' + e.kid + '/fam'};
          case 'xform':
            return {text: (who == a ? '' : '\@' + a + ' ') + 'xformed ' + Math.round(100 * (e.mul || 0)) + '% toward \@' + b, other: b, href: '/' + a};
          case 'join':
            return {text: 'joined peaple.io', other: null, href: '/' + who};
        }
        return {text: e.what + ' ' + (a || ''), other: null, href: '/' + who};
      }
      function face(nom, px) {
        return "<a href='/" + nom + "'><img width=" + px + " height=" + px + " style='border: 0; display: block' src='/" + nom + ".png?dim=128&nostamp=1' title='" + nom + "'></a>";
      }
      function render() {
        var div = document.getElementById('nooz');
        div.innerHTML = '';
        ev.forEach(function(e) {
          var s = say(e), lines = wrap(s.text, COLS);
          var tab = document.createElement('table');
          tab.cellPadding = 0; tab.cellSpacing = 0; tab.style.marginTop = '14px';
          var tr = tab.insertRow(), td0 = tr.insertCell(), td1 = tr.insertCell(), td2 = tr.insertCell();
          td0.vAlign = 'top'; td1.vAlign = 'top'; td2.vAlign = 'top'; td1.style.padding = '0 8px';
          var who = e.who || e.a;      // not logged in: shown as the parson it was done to
          td0.innerHTML = face(who, 64);
          td2.innerHTML = s.other && s.other != who ? face(s.other, 64) : '';
          var can = document.createElement('canvas');
          can.width = COLS * CW; can.height = 16 + lines.length * CH;
          can.style.display = 'block'; can.style.cursor = 'pointer';
          var ctx = can.getContext('2d');
          ctx.fillStyle = '#000000'; ctx.fillRect(0, 0, can.width, can.height);
          drawText(ctx, '$html::phont', who + '  ' + age(e.t), 0, 0, 0.5);
          lines.forEach(function(l, i) { drawText(ctx, 'titulus', l, 0, 16 + i * CH, 1); });
          var links = [];
          lines.forEach(function(l, i) {
            var re = /(^|[^A-Za-z0-9_])\@([A-Za-z0-9_]{1,31})/g, m;
            while ((m = re.exec(l))) links.push({x: (m.index + m[1].length) * CW, y: 16 + i * CH, w: (m[2].length + 1) * CW, h: CH, nom: m[2].toLowerCase()});
          });
          links.forEach(function(k) {
            var d = ctx.getImageData(k.x, k.y, k.w, k.h), q = d.data;
            for (var j = 0; j < q.length; j += 4) { var L = Math.max(q[j], q[j + 1], q[j + 2]); q[j] = q[j + 1] = 0.6 * L; q[j + 2] = L; }
            ctx.putImageData(d, k.x, k.y);
          });
          // a name goes to that parson; anywhere else on the line goes to where it happened
          can.addEventListener('click', function(ev2) {
            var r = can.getBoundingClientRect(), x = (ev2.clientX - r.left) * can.width / r.width, y = (ev2.clientY - r.top) * can.height / r.height;
            for (var i = 0; i < links.length; ++i) { var k = links[i]; if (x >= k.x && x < k.x + k.w && y >= k.y && y < k.y + k.h) { location.href = '/' + k.nom; return; } }
            location.href = s.href;
          });
          td1.appendChild(can);
          div.appendChild(tab);
        });
      }
      setInterval(function() {
        if (document.hidden) return;
        var i = new XMLHttpRequest;
        i.open('GET', '/nooz.json');
        i.onload = function() { try { var j = JSON.parse(this.responseText); if (j.length) { ev = j; render(); } } catch (x) { } };
        i.send();
      }, 30000);
    })();
    </script>
    </body>
    </html>
END
  exit 0;
}

# /top, /top/<board>: makemore's top.html.  Three boards (online, activity, and likes = likes received on wall posts and replies; score went with ownership 2026-11-15; makemore's fourth, followers = crew size, was dropped 2026-11-15) of up to 64 faces; the
# numbers come from /top/<board>.json, which devserver.py serves from its view counters and a scan of the account blocks.
if ($path =~ m#^top(?:/([a-z]*))?$#) {
  my $board = $1 // '';
  $board = 'online' unless $board =~ /^(online|activity|likes)$/;
  my ($f, $ph) = ($html::fontasy, $html::phont);
  my %w = (online => 96, activity => 128, likes => 80);
  my $tabs = join(" |\n", map {
    my $cls = $_ eq $board ? "style='outline: 3px solid #00ff00; cursor: pointer'" : "class='button'";
    "<a href='/top/$_'><img $cls height='24' width='$w{$_}' src='$f$ph.png?txt=$_&dim=8&chop=0'/></a>"
  } qw(online activity likes));
  print "Content-Type: text/html\r\n\r\n";
  print <<"END";
    <html>
    <head>
    <title>peaple.io / top / $board</title>
    <style type="text/css">
      .topcell { background-color: #333333; border: 2px solid #555555; }
    </style>
    </head>
    <body bgcolor="#000000" text="#ffffff" link="#9999ff" vlink="#bb99ff">
      $html::header
      <script>document.getElementById('headtop').style.outline = '3px solid #00ff00';</script>
      <table cellpadding=0 cellspacing=0 width="1280">
        <tr height=8></tr>
        <tr><td align="center" style='font-size: 40px'>[
          $tabs
        ]</td></tr>
      </table>
      <table width="1280"><tr><td align="center">
        <table id="tab" cellpadding=0 cellspacing=8></table>
      </td></tr></table>
    <script>
    (function() {
      var func = "$board";
      var unit = { activity: '&mu;Hz', likes: '', online: 's' };
      var sty = {
        activity: 'font-size: 24px; font-family: monospace',
        likes: 'font-size: 24px; font-family: monospace; color: #ff6666',
        online: 'font-size: 24px; font-family: monospace'
      };
      var i = new XMLHttpRequest;
      i.open('GET', '/top/' + func + '.json');
      i.onload = function() {
        if (this.status != 200) { return; }
        var ar = JSON.parse(this.responseText);
        var n = 0, cols = 4, html = '';
        for (var k in ar) {
          if (n % cols == 0) { html += "<tr>"; }
          var u = unit[func];
          var v = Math.floor(ar[k]);
          if (u == "s") { v *= 1024; u = "ms"; }
          if (u == "ms") {
            if (v >= 10000) { v = v / 1024; u = "s"; }
            if (v >= 10000) { v = v / 1024; u = "ks"; }
            if (v >= 10000) { v = v / 1024; u = "Ms"; }
            v = Math.floor(v);
          }
          if (u == "") {
            if (v >= 10000) { v = v / 1024; u = "k"; }
            if (v >= 10000) { v = v / 1024; u = "M"; }
            v = Math.floor(v);
          }
          html += "<td class='topcell'><table width=256 cellpadding=0 cellspacing=0><tr>" +
            "<td width=128><a href='/" + k + "'><img width=128 height=128 src='/" + k + ".png?dim=128'></a></td>" +
            "<td style='" + sty[func] + "' align='right'>&nbsp;" + v + "&nbsp;" + u + "</td>" +
            "</tr></table></td>";
          if (n % cols == cols - 1) { html += "</tr>"; }
          if (++n >= 64) { break; }
        }
        document.getElementById('tab').innerHTML = html;
      };
      i.send();
    })();
    </script>
    </body>
    </html>
END
  exit 0;
}

if ($path eq '' || $path eq 'rand') {
  my $nom = $peaple->pick;
  print "Status: 302\r\n";
  print "Location: /$nom\r\n";
  print "Content-Length: 0\r\n";
  print "Content-Type: text/html\r\n";
  print "\r\n";
  exit 0;
}

if ($path eq 'pick.json') {
  my $n = int($cgi->param('n')) || 1;
  $n = 1 if $n < 1;
  $n = 64 if $n > 64;

  my @nom;
  for (1 .. $n) {
    my $nom = $peaple->pick;
    push @nom, $nom;
  }

  my $json = encode_json(\@nom);

  print "Content-Type: text/json\r\n";
  print "Content-Length: " . length($json) . "\r\n";
  print "\r\n";
  print $json;
  exit 0;
}

if ($path eq 'new') {
  my $vis = new visage;
  my $nom = $vis->{nom};
  print "Status: 302\r\n";
  print "Location: /$nom\r\n";
  print "Content-Length: 0\r\n";
  print "Content-Type: text/html\r\n";
  print "\r\n";
  exit 0;
}

if ($path eq 'extra/mork.png' || $path eq 'extra/burning_ship.png') {
  $path =~ s/^extra\///;
  open(my $fp, "< $rootdir/$path") or die;
  undef local $/;
  my $png = <$fp>;
  close($fp);

  print "Content-Type: image/png\r\n";
  print "Content-Length: " . length($png) . "\r\n";
  print "\r\n";
  print $png;
  exit 0;
}

if ($path eq 'favicon.ico') {
  open(my $fp, "< $rootdir/favicon.ico") or die;
  undef local $/;
  my $png = <$fp>;
  close($fp);

  print "Content-Type: image/png\r\n";
  print "Content-Length: " . length($png) . "\r\n";
  print "\r\n";
  print $png;
  exit 0;
}

# edit?op=rblend&nom=X&mul=M&vdev=D&r=R[&return=URL]: blend the deviated rendering
# (same deviation the PNG shows for vdev/r) into X's vector by M, then redirect (hotorbot.ai)
if ($path eq 'edit') {
  my $op = $cgi->param('op') // '';
  my $enom = lc($cgi->param('nom') // '');
  $enom =~ /^[a-z0-9_]+$/ or die "bad nom";
  if ($op eq 'rblend') {
    my $mul = $cgi->param('mul') // 0.05;
    my $vdev = $cgi->param('vdev') // 1.0;
    my $r = $cgi->param('r') // rand(1);
    my $vis = $peaple->load_visage($enom) or die "no visage";
    my @dvec = @{$vis->{vec}};
    peaple::_vecdev(\@dvec, $vdev, $r);
    my $vv = $vis->{vec};
    for (my $i = 0; $i < @$vv; ++$i) {
      $$vv[$i] = $$vv[$i] * (1 - $mul) + $dvec[$i] * $mul;
    }
    $peaple->save_visage($vis);
  }
  my $ret = $cgi->param('return') // "/$enom";
  print "Status: 302\r\n";
  print "Location: $ret\r\n";
  print "Content-Length: 0\r\n";
  print "Content-Type: text/html\r\n";
  print "\r\n";
  exit 0;
}

my ($nom, $func, @extra) = split /\//, $path;
$func = 'wall' if $func eq '';

my $nomext;
if ($nom =~ /(^.+)\.([a-z]+$)/) {
  $nom = $1;
  $nomext = $2;
}
$nom = lc($nom);
$nom =~ /^[a-z0-9_]+$/ or die "bad nom";
length($nom) < 32 or die "bad nom";

if ($nomext eq "png") {
  if ($nom eq 'new') {
    my $vis = new visage;
    $nom = $vis->{nom};
  } elsif ($nom eq 'rand') {
    $nom = $peaple->pick;
  }

  my $dim = $cgi->param('dim') // 512;
  my $mul = $cgi->param('mul') // 1.0;
  my $dev = $cgi->param('dev') // $cgi->param('vdev') // 0.0;   # vdev/r: hotorbot's names
  my $rnd = $cgi->param('rnd') // $cgi->param('r');

  my $vis = $peaple->load_visage($nom) or die "no visage";

  my $png = $peaple->getpng($vis, $dim, $mul, $dev, $rnd);
  die unless $png;

  print "Content-Type: image/png\r\n";
  print "Content-Length: " . length($png) . "\r\n";
  print "\r\n";
  print $png;
  exit 0;

} elsif ($nomext eq "json") {

  $nom =~ s/\.json$//;

  my $vis = $peaple->load_visage($nom) or die "no visage";

  my $json = $vis->json;

  print "Content-Type: text/json\r\n";
  print "Content-Length: " . length($json) . "\r\n";
  print "\r\n";
  print $json;

} elsif ($func eq 'wall.json') {

  print_json('[' . join(',', wall_read($nom)) . ']');

} elsif ($func eq 'post.json') {

  # write on this parson's wall as the logged-in user: ASCII (the phonts have nothing else), 2000 characters,
  # one post per author every ten seconds
  $user ne '' or die "not logged in";
  my $text = $cgi->param('text') // '';
  $text =~ tr/\x{2018}\x{2019}\x{201c}\x{201d}/''""/;
  $text =~ s/\s+/ /g;
  $text =~ s/[^\x20-\x7e]//g;
  $text =~ s/^ | $//g;
  $text = substr($text, 0, 2000);
  my $err;
  # re=<post id>: a reply.  Threads are one level deep, so a reply to a reply joins that reply's thread.
  my $re = $cgi->param('re') // '';
  my $refrom = '';
  if ($re ne '') {
    my ($par) = $re =~ /^\d+-\d+$/ ? (grep { !defined $_->{like} && ($_->{id} // '') eq $re } wall_raw($nom)) : ();
    if ($par) {
      $refrom = $par->{from};
      $re = $par->{re} if defined $par->{re};
    } else {
      $err = 'no such post';
    }
  }
  if ($err) {
  } elsif ($text eq '') {
    $err = 'empty post';
  } else {
    my $ld = "$rootdir/walls/_last";
    -d "$rootdir/walls" or mkdir("$rootdir/walls");
    -d $ld or mkdir($ld);
    my @st = stat("$ld/$user");
    if (@st && time - $st[9] < 10) {
      $err = 'too fast, wait ten seconds';
    } else {
      open(my $t, '>', "$ld/$user"); close($t);
      my $fn = wall_path($nom);
      my $pid = int(time) . '-' . int(rand(1000000));
      my $line = JSON::PP->new->canonical(1)->encode(+{
        id => $pid, t => int(time), from => $user, text => $text,
        ip => ($ENV{HTTP_CF_CONNECTING_IP} // $ENV{REMOTE_ADDR} // ''),
        ($re ne '' ? (re => $re) : ()),
      });
      open(my $fp, '>>', $fn) or die "$fn: $!";
      print $fp "$line\n";
      close($fp);
      feed_event($user, 'post', $nom, $refrom, id => $pid, text => clip($text, 160), ($re ne '' ? (re => $re) : ()));
      # @nom in the text is news for that nom (the wall's nom and whoever is being answered already hear of it)
      my %told = ($user => 1, $nom => 1, $refrom => 1);
      my $nm = 0;
      for my $m (map { lc } $text =~ /(?<![A-Za-z0-9_])\@([A-Za-z0-9_]{1,31})/g) {
        next if $told{$m}++;
        feed_event($user, 'mention', $nom, $m, id => $pid, text => clip($text, 160), ($re ne '' ? (re => $re) : ()));
        last if ++$nm >= 5;
      }
      # a wall pins the record: make sure there is one on disk (devserver's sweep keeps records that have a wall)
      my $vis = $peaple->load_visage($nom);
      $peaple->save_visage($vis) if $vis && !-e $peaple->_vpath($nom);
    }
  }
  print_json('{"ok":' . ($err ? 0 : 1) . ($err ? ',"error":"' . $err . '"' : '') . ',"posts":[' . join(',', wall_read($nom)) . ']}');

} elsif ($func eq 'delpost.json') {

  # only the wall's own nom deletes from it
  $user eq $nom or die "not your wall";
  my $id = $cgi->param('id') // '';
  $id =~ /^\d+-\d+$/ or die "bad id";
  my $fn = wall_path($nom);
  if (open(my $fp, '<', $fn)) {
    my @keep = grep { index($_, "\"id\":\"$id\"") < 0 && index($_, "\"re\":\"$id\"") < 0 && index($_, "\"like\":\"$id\"") < 0 } <$fp>;
    close($fp);
    my $tmp = "$fn.$$.tmp";
    open(my $out, '>', $tmp) or die "$tmp: $!";
    print $out @keep;
    close($out);
    rename($tmp, $fn) or die;
  }
  print_json('{"ok":1,"posts":[' . join(',', wall_read($nom)) . ']}');

} elsif ($func eq 'like.json') {

  # like or unlike a post or a reply on this wall (toggles unless on=0/1 is given); one like per nom
  $user ne '' or die "not logged in";
  my $id = $cgi->param('id') // '';
  $id =~ /^\d+-\d+$/ or die "bad id";
  my @raw = wall_raw($nom);
  my ($p) = grep { !defined $_->{like} && ($_->{id} // '') eq $id } @raw;
  my $err;
  if (!$p) {
    $err = 'no such post';
  } elsif ($p->{from} eq $user) {
    $err = 'you cannot like your own post';
  } else {
    my ($was, $ever) = (0, 0);
    for (@raw) {
      next unless defined $_->{like} && $_->{like} eq $id && $_->{from} eq $user;
      $was = $_->{on} ? 1 : 0;
      $ever = 1;
    }
    my $on = defined $cgi->param('on') ? ($cgi->param('on') ? 1 : 0) : 1 - $was;
    if ($on != $was) {
      my $line = JSON::PP->new->canonical(1)->encode(+{ like => $id, from => $user, on => $on, t => int(time) });
      my $fn = wall_path($nom);
      open(my $fp, '>>', $fn) or die "$fn: $!";
      print $fp "$line\n";
      close($fp);
      # the first like is news for whoever wrote the post; toggling it again is not
      feed_event($user, 'like', $nom, $p->{from}, id => $id, (defined $p->{re} ? (re => $p->{re}) : ()), text => clip($p->{text}, 80)) if $on && !$ever && $p->{from} ne $user;
    }
  }
  print_json('{"ok":' . ($err ? 0 : 1) . ($err ? ',"error":"' . $err . '"' : '') . ',"posts":[' . join(',', wall_read($nom)) . ']}');

} elsif ($func eq 'unfren.json') {

  # drop a fren, both ways
  my $fnom = lc($cgi->param('fren') // '');
  $fnom =~ /^[a-z0-9_]{1,31}$/ or die "bad nom";
  my $vis = $peaple->load_visage($nom) or die "no visage";
  $vis->{frens} = [grep { $_ ne $fnom } @{$vis->{frens}}];
  $peaple->save_visage($vis);
  my $fvis = $peaple->load_visage($fnom);
  if ($fvis && $fvis->hasfren($nom)) {
    $fvis->{frens} = [grep { $_ ne $nom } @{$fvis->{frens}}];
    $peaple->save_visage($fvis);
  }
  feed_event($user, 'unfren', $nom, $fnom);
  print_json($vis->json);

} elsif ($func eq 'preview.png') {

  # what an action would look like, without saving anything:
  #   op=xform&fren=F&mul=M   this face blended M of the way toward F (as blend.json would leave it)
  #   op=bread&fren=F&seed=N  the kid of this parson and F for coordinate mask N (bread.json with the same seed makes it)
  my $op = $cgi->param('op') // 'xform';
  my $fnom = lc($cgi->param('fren') // '');
  $fnom =~ /^[a-z0-9_]{1,31}$/ or die "bad nom";
  my $vis = $peaple->load_visage($nom) or die "no visage";
  my $fvis = $peaple->load_visage($fnom) or die "no fren visage";
  my ($vv, $fvv) = ($vis->{vec}, $fvis->{vec});
  @$vv == 1536 && @$fvv == 1536 or die;
  my @pv;
  if ($op eq 'bread') {
    my $mul = $cgi->param('mul') // 0.5;
    srand(int($cgi->param('seed') // 0));
    @pv = map { rand(1) < $mul ? $$fvv[$_] : $$vv[$_] } 0 .. 1535;
  } else {
    my $mul = $cgi->param('mul') // 0.2;
    @pv = map { $$vv[$_] * (1 - $mul) + $$fvv[$_] * $mul } 0 .. 1535;
    my $m = 0;
    for (@pv) { $m = abs($_) if abs($_) > $m; }
    $_ *= 0.999 / $m for @pv;
  }
  my $pvis = new visage nom => $nom, vec => \@pv;
  my $png = $peaple->getpng($pvis, $cgi->param('dim') // 256, 1.0, 0.0, undef);
  die unless $png;
  print "Content-Type: image/png\r\n";
  print "Content-Length: " . length($png) . "\r\n";
  print "\r\n";
  print $png;

} elsif ($func eq 'addfren.json') {

  my @fnom = $cgi->param('fren');
  for (@fnom) {
    if ($_ eq '') {
      $_ = $peaple->pick;
    }
  }

  for (@fnom) {
    $_ = lc($_);
    /^[a-z0-9_]+$/ or die "bad nom";
    length($_) < 32 or die "bad nom";
  }

  my $vis = $peaple->load_visage($nom) or die "no visage";
  $vis->addfren(@fnom);
  $peaple->save_visage($vis);

  for my $fnom (@fnom) {
    my $fren = $peaple->load_visage($fnom);
    $fren->addfren($nom);
    $peaple->save_visage($fren);
    feed_event($user, 'fren', $nom, $fnom);
  }

  my $json = $vis->json;

  print "Content-Type: text/json\r\n";
  print "Content-Length: " . length($json) . "\r\n";
  print "\r\n";
  print $json;


} elsif ($func eq 'blend.json') {

  my $fnom = $cgi->param('fren');

  $fnom = lc($fnom);
  $fnom =~ /^[a-z0-9_]+$/ or die "bad nom";
  length($fnom) < 32 or die "bad nom";

  my $mul = $cgi->param('mul') // 0.25;

  my $fvis = $peaple->load_visage($fnom) or die "no fren visage";
  my $vis = $peaple->load_visage($nom) or die "no visage";

  my $vv = $vis->{vec};
  my $fvv = $fvis->{vec};
  @$vv == 1536 or die;
  @$fvv == 1536 or die;

  my $m0 = undef;
  my $m1 = undef;
  for (0 .. 1535) {
    $$vv[$_] = $$vv[$_] * (1 - $mul) + $$fvv[$_] * $mul;

    if (!defined($m0) || abs($$vv[$_]) > $m0) {
      $m0 = abs($$vv[$_]);
    }
  }
  my $m = $m0;

  for (0 .. 1535) {
    $$vv[$_] *= 0.999 / $m;
  }

  # makemore made whoever you xform toward one of your parens.  Off since 2026-11-15: parsons xform all the time
  # now, and it was overwriting the real parens of kids made by bread.  Parens are set by bread only.
  # if (!$vis->hasparen($fnom)) {
  #   my $vp = $vis->{parens};
  #   unshift @$vp, $fnom;
  #   splice @$vp, 2;
  # }

  # if (!$fvis->haskid($nom)) {
  #   my $fvk = $fvis->{kids};
  #   unshift @$fvk, $nom;
  #   splice @$fvk, 8;
  #
  #   $peaple->save_visage($fvis);
  # }

  $peaple->save_visage($vis);
  feed_event($user, 'xform', $nom, $fnom, mul => $mul + 0);

  my $json = $vis->json;

  print "Content-Type: text/json\r\n";
  print "Content-Length: " . length($json) . "\r\n";
  print "\r\n";
  print $json;

} elsif ($func eq 'bread.json' || $func eq 'bread') {

  my $fnom = $cgi->param('fren');

  $fnom = lc($fnom);
  $fnom =~ /^[a-z0-9_]+$/ or die "bad nom";
  length($fnom) < 32 or die "bad nom";

  my $mul = $cgi->param('mul') // 0.5;

  my $fvis = $peaple->load_visage($fnom) or die "no fren visage";
  my $vis = $peaple->load_visage($nom) or die "no visage";

  my $kgen = $vis->{gen};
  if ($fvis->{gen} < $kgen) {
    $kgen = $fvis->{gen};
  }
  --$kgen;

  my $kvis = new visage
    parens  => [$nom, $fnom],
    frens   => ["synthetic_dan_brumleve"],
    gen     => $kgen,
    ;
  {
    my @np = split /_/, $nom;
    my @kp = split /_/, $kvis->{nom};
    $kvis->{nom} = $kp[0] . '_' . $np[-1];
  }
  my $knom = $kvis->{nom};

  my $vv = $vis->{vec};
  my $fvv = $fvis->{vec};
  my $kvv = $kvis->{vec} = [ ];
  @$kvv = ( );
  @$vv == 1536 or die;
  @$fvv == 1536 or die;
  # seed=N fixes the coordinate mask, so the kid is the one preview.png?op=bread&seed=N showed
  srand(int($cgi->param('seed'))) if defined $cgi->param('seed');
  for (0 .. 1535) {
    if (rand(1) < $mul) {
      $$kvv[$_] = $$fvv[$_];
    } else {
      $$kvv[$_] = $$vv[$_];
    }
  }

  my $fvk = $fvis->{kids};
  unshift @$fvk, $knom;
  splice @$fvk, 8;

  my $vk = $vis->{kids};
  unshift @$vk, $knom;
  splice @$vk, 8;

  $peaple->save_visage($kvis);
  $peaple->save_visage($fvis);
  $peaple->save_visage($vis);
  feed_event($user, 'bread', $nom, $fnom, kid => $knom);
  # whoever breads (logged in) may write the kid's first system prompt
  if ($user ne '' && defined $cgi->param('thotz') && $cgi->param('thotz') =~ /\S/) {
    thotz_write($knom, scalar($cgi->param('thotz')));
  }

  if ($func eq 'bread.json') {
    my $json = $kvis->json;

    print "Content-Type: text/json\r\n";
    print "Content-Length: " . length($json) . "\r\n";
    print "\r\n";
    print $json;
  } elsif ($func eq 'bread') {
    print "Status: 302\r\n";
    print "Location: /$knom/fam\r\n";
    print "Content-Length: 0\r\n";
    print "Content-Type: text/html\r\n";
    print "\r\n";
  } else {
    die;
  }

} elsif ($func eq 'source.json') {
  if ($cgi->request_method eq 'POST') {
    if (my $datafh = $cgi->param('file')) {
      my $data;
      {
        undef local $/;
        $data = <$datafh>;
      }
      close($datafh);

#      my $comment = "#p:288,128 #q:352,128 #r:320,192";
      my $comment = "#p:254,205 #q:396,205 #r:325,367";


      open(my $out, "| convert - -set comment '$comment' $rootdir/uploads/$nom.png") or die;
      print $out $data;
      close($out);

      # default markers from the autoposer (falls back to the fixed defaults above if the poser server is down)
      if (my @m = $peaple->autopose("$rootdir/uploads/$nom.png")) {
        $comment = sprintf("#p:%d,%d #q:%d,%d #r:%d,%d", @m);
        system("mogrify", "+set", "comment", "$rootdir/uploads/$nom.png");
        system("mogrify", "-set", "comment", $comment, "$rootdir/uploads/$nom.png");
      }
    }
  }

  my $comment = '';
  {
    open(my $fp, "convert $rootdir/uploads/$nom.png -format %c info:- |") or die;
    undef local $/;
    $comment = <$fp>;
    close($fp);
  }

  my %tag;
  for my $kv (split /\s+/, $comment) {
    $kv =~ /^#/ or next;
    $kv = substr($kv, 1);

    my ($k, $v);
    if ($kv =~ /:/) {
      ($k, $v) = split(/:/, $kv, 2);
    } else {
      ($k, $v) = ($k, 1);
    }
    if ($v =~ /,/) {
      $v = [split /,/, $v];
    }

    $tag{$k} = $v;
  }

  if ($cgi->request_method eq 'POST') {
    $tag{p}->[0] = $cgi->param('px') // $tag{p}->[0];
    $tag{p}->[1] = $cgi->param('py') // $tag{p}->[1];
    $tag{q}->[0] = $cgi->param('qx') // $tag{q}->[0];
    $tag{q}->[1] = $cgi->param('qy') // $tag{q}->[1];
    $tag{r}->[0] = $cgi->param('rx') // $tag{r}->[0];
    $tag{r}->[1] = $cgi->param('ry') // $tag{r}->[1];

    my $px = $tag{p}->[0];
    my $py = $tag{p}->[1];
    my $qx = $tag{q}->[0];
    my $qy = $tag{q}->[1];
    my $rx = $tag{r}->[0];
    my $ry = $tag{r}->[1];

    my $comment = "#p:$px,$py #q:$qx,$qy #r:$rx,$ry";

    system(
      "mogrify",
      "+set", "comment",
      "$rootdir/uploads/$nom.png"
    );

    system(
      "mogrify",
      "-set", "comment", $comment,
      "$rootdir/uploads/$nom.png"
    );

    my @aff = math::getaff($px, $py, $qx, $qy, $rx, $ry);
    my $aff = join(',', @aff);

    # -affine/-transform auto-sizes the canvas and drops the translation (IM 6.9.12), so the face landed in the wrong
    # place; AffineProjection with an explicit viewport maps the markers exactly onto the canonical points
    open(my $rgbfp, "convert $rootdir/uploads/$nom.png -virtual-pixel mirror -define distort:viewport=128x128+0+0 -distort AffineProjection '$aff' +repage +set comment ppm:- |") or die;
    my $rgb;
    {
      local $/ = "\n";
      my $line = <$rgbfp>; $line eq "P6\n" or die "bad ppm magic";
      my $line = <$rgbfp>; $line eq "128 128\n" or die "bad ppm dim";
      my $line = <$rgbfp>; $line eq "255\n" or die "bad ppm depth";

      undef local $/;
      $rgb = <$rgbfp>;
    }
    length($rgb) == 128 * 128 * 3 or die "bad ppm length " . length($rgb);

    my $vec = $peaple->getvec($rgb);

    my $vis = $peaple->load_visage($nom);
    $vis->{vec} = $vec;
    $peaple->save_visage($vis);
  }

  my $json = encode_json(\%tag);
  
  print "Content-Type: text/json\r\n";
  print "Content-Length: " . length($json) . "\r\n";
  print "\r\n";
  print $json;

} elsif ($func eq 'wall') {

  # the wall: the picture, then what people wrote on it (walls/*.jsonl), newest first, each with its replies under it oldest first, drawn in titulus glyphs on
  # canvases like the chat transcript.  Logged-in users get a one-line post box; the wall's own nom gets delete buttons.
  my $subhead = html::subhead($nom);
  my $posts = '[' . join(',', wall_read($nom)) . ']';
  $posts =~ s#</#<\\/#g;
  my $postbox = $user ne '' ? qq{
          <table cellpadding="0" cellspacing="0"><tr>
            <td><img src="/$user.png?dim=128&nostamp=1" width="64" height="64" title="$user"/></td>
            <td width="8"></td>
            <td><input id="postin" type="text" maxlength="2000" autocomplete="off" placeholder="write on ${nom}'s wall"
              style="width: 1128px; box-sizing: border-box; font-size: 22px; padding: 8px; background: #111111; color: #ffffff; border: 2px solid #444444; outline: none"/></td>
          </tr></table>
  } : '';

  print "Content-Type: text/html\r\n\r\n";
  print <<"END";
    <html>
    <head>
    <title>peaple.io / $nom</title>

    <meta property='og:title' content='$nom'>
    <meta property='og:description' content='$nom'>
    <meta property='og:image' content='https://peaple.io/$nom.png'>
    <meta property='og:image:type' content='image/png'>
    <meta property='og:image:width' content='512'>
    <meta property='og:image:height' content='512'>
    <meta property='og:url' content='https://peaple.io/$nom'>
    <meta property='og:type' content='article'>
    <link rel='canonical' href='https://peaple.io/$nom'>

    </head>

      <body bgcolor="#000000" text="#ffffff" link="#9999ff" vlink="#bb99ff">
        $html::header
        $subhead

        <table width="1280"><tr><td align="center">
          <a href="/$nom/fam"><img id="pic" src="/$nom.png?dim=512" width="512" height="512"/></a>
        </td></tr></table>
        <br/>
        <table width="1280" cellpadding="0" cellspacing="0"><tr><td>
          $postbox
          <div id="posts"></div>
        </td></tr></table>

    <script>
    (function() {
      var nom = "$nom", user = "$user";
      var posts = $posts;
      var COLS = 75, CW = 16, CH = 24;
      var sheets = {}, loaded = 0;
      ['$html::phont', 'titulus'].forEach(function(n) {
        var im = new Image(); im.onload = function() { if (++loaded == 2) render(); };
        im.src = '/fontasy/' + n + '.png?grid=8'; sheets[n] = im;
      });
      function wrap(text, cols) {
        var lines = [], line = '';
        text.split(/\\s+/).forEach(function(w) {
          while (w.length > cols) { if (line) { lines.push(line); line = ''; } lines.push(w.substr(0, cols)); w = w.substr(cols); }
          if (!w) return;
          if (line && line.length + 1 + w.length > cols) { lines.push(line); line = w; }
          else line = line ? line + ' ' + w : w;
        });
        if (line) lines.push(line);
        return lines;
      }
      function drawText(ctx, phont, s, x, y, k) {   // k: glyph scale (1 = 16x24)
        var im = sheets[phont];
        for (var i = 0; i < s.length; ++i) {
          var c = s.charCodeAt(i); if (c < 0x20 || c > 0x7e) c = 0x7f;
          var g = c - 0x20;
          ctx.drawImage(im, (g % 12) * CW, Math.floor(g / 12) * CH, CW, CH, x + i * CW * k, y, CW * k, CH * k);
        }
      }
      function age(t) {
        var d = Math.max(0, Math.floor(Date.now() / 1000) - t);
        if (d < 120) return d + 's';
        if (d < 7200) return Math.floor(d / 60) + 'm';
        if (d < 172800) return Math.floor(d / 3600) + 'h';
        return Math.floor(d / 86400) + 'd';
      }
      var open = null;      // the reply box that is showing: {thread, re, to, pre}
      var jumped = false;
      function bar(p, top, thread) {   // under a post: like (count), reply, delete
        var d = document.createElement('div');
        d.style.marginTop = '6px'; d.style.height = '16px';
        function btn(txt, cls, title, fn) {
          var x = document.createElement('img');
          x.src = '/fontasy/$html::phont.png?txt=' + encodeURIComponent(txt) + '&dim=8&chop=0'; x.height = 16;
          x.style.marginRight = '12px'; x.title = title;
          if (cls) x.className = cls;
          if (fn) x.onclick = fn;
          d.appendChild(x);
        }
        var n = p.likes.length, mine = user && p.likes.indexOf(user) >= 0;
        var txt = (mine ? 'liked' : 'like') + (n ? ' ' + n : '');
        if (user && user != p.from) btn(txt, mine ? 'redbutton' : 'button', p.likes.join(', '), function() { call('like.json', 'id=' + encodeURIComponent(p.id)); });
        else if (n) btn(txt, '', p.likes.join(', '));
        if (user) btn('reply', 'button', 'reply', function() {   // a reply to a reply joins the thread, addressed with \@nom
          open = open && open.re == p.id ? null : {thread: thread.id, re: p.id, to: p.from, pre: top ? '' : '\@' + p.from + ' '};
          render();
        });
        if (user && user == nom) btn('x', 'redbutton', 'delete', function() { call('delpost.json', 'id=' + encodeURIComponent(p.id)); });
        return d;
      }
      function row(p, top, thread) {   // one post (64px face, 75 columns) or one reply (32px face, 72 columns, indented)
        var cols = top ? COLS : COLS - 3, face = top ? 64 : 32;
        var lines = wrap(p.text, cols);
        var tab = document.createElement('table');
        tab.cellPadding = 0; tab.cellSpacing = 0; tab.style.marginTop = top ? '16px' : '10px';
        if (!top) tab.style.marginLeft = '72px';
        tab.id = 'p' + p.id;                                   // /<nom>#p<id> links here (the nooz page does)
        if (location.hash == '#p' + p.id) tab.style.outline = '2px solid #00ff00';
        var tr = tab.insertRow(), td0 = tr.insertCell(), td1 = tr.insertCell();
        td0.vAlign = 'top'; td1.vAlign = 'top'; td1.style.paddingLeft = '8px';
        td0.innerHTML = "<a href='/" + p.from + "'><img width=" + face + " height=" + face + " style='border: 0; display: block' src='/" + p.from + ".png?dim=128&nostamp=1' title='" + p.from + "'></a>";
        var can = document.createElement('canvas');
        can.width = cols * CW; can.height = 16 + lines.length * CH;
        can.style.display = 'block';
        var ctx = can.getContext('2d');
        ctx.fillStyle = '#000000'; ctx.fillRect(0, 0, can.width, can.height);
        drawText(ctx, '$html::phont', p.from + '  ' + age(p.t), 0, 0, 0.5);   // who and how long ago, half-size
        lines.forEach(function(l, i) { drawText(ctx, 'titulus', l, 0, 16 + i * CH, 1); });
        // \@nom is a link to that nom's wall: tinted like a link, and the canvas answers clicks on it
        var links = [];
        lines.forEach(function(l, i) {
          var re = /(^|[^A-Za-z0-9_])\@([A-Za-z0-9_]{1,31})/g, m;
          while ((m = re.exec(l))) {
            var x = (m.index + m[1].length) * CW, w = (m[2].length + 1) * CW;
            links.push({x: x, y: 16 + i * CH, w: w, h: CH, nom: m[2].toLowerCase()});
          }
        });
        if (links.length) {
          links.forEach(function(k) {      // recolor the glyphs to the page's link blue (#9999ff), keeping their brightness
            var d = ctx.getImageData(k.x, k.y, k.w, k.h), q = d.data;
            for (var j = 0; j < q.length; j += 4) {
              var L = Math.max(q[j], q[j + 1], q[j + 2]);
              q[j] = q[j + 1] = 0.6 * L; q[j + 2] = L;
            }
            ctx.putImageData(d, k.x, k.y);
          });
          var hit = function(e) {
            var r = can.getBoundingClientRect(), x = (e.clientX - r.left) * can.width / r.width, y = (e.clientY - r.top) * can.height / r.height;
            for (var i = 0; i < links.length; ++i) { var k = links[i]; if (x >= k.x && x < k.x + k.w && y >= k.y && y < k.y + k.h) return k; }
            return null;
          };
          can.addEventListener('mousemove', function(e) { var k = hit(e); can.style.cursor = k ? 'pointer' : ''; can.title = k ? k.nom : ''; });
          can.addEventListener('click', function(e) { var k = hit(e); if (k) location.href = '/' + k.nom; });
        }
        td1.appendChild(can);
        td1.appendChild(bar(p, top, thread));
        return tab;
      }
      function render() {
        var div = document.getElementById('posts');
        div.innerHTML = '';
        var focus = null;
        posts.forEach(function(p) {
          div.appendChild(row(p, true, p));
          (p.replies || []).forEach(function(r) { div.appendChild(row(r, false, p)); });   // oldest first, going down
          if (user && open && open.thread == p.id) {
            var o = open;
            var inp = document.createElement('input');
            inp.type = 'text'; inp.maxLength = 2000; inp.autocomplete = 'off'; inp.placeholder = 'reply to ' + o.to; inp.value = o.pre;
            inp.style.cssText = 'margin: 10px 0 0 72px; width: 1128px; box-sizing: border-box; font-size: 22px; padding: 8px; background: #111111; color: #ffffff; border: 2px solid #444444; outline: none';
            inp.addEventListener('keydown', function(e) {
              if (e.key == 'Escape') { open = null; render(); return; }
              if (e.key != 'Enter') return;
              e.preventDefault();
              var t = inp.value.replace(/\\s+/g, ' ').trim();
              if (!t) return;
              open = null;
              call('post.json', 'text=' + encodeURIComponent(t) + '&re=' + encodeURIComponent(o.re));
            });
            div.appendChild(inp);
            focus = inp;
          }
        });
        if (focus) focus.focus();
        if (!jumped && location.hash.indexOf('#p') == 0) {     // arrived by a link to one post: bring it into view, once
          var t = document.getElementById(location.hash.substr(1));
          if (t) { jumped = true; t.scrollIntoView({block: 'center'}); }
        }
      }
      function call(what, body) {
        var i = new XMLHttpRequest;
        i.open('POST', '/' + nom + '/' + what);
        i.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
        i.onload = function() {
          try { var j = JSON.parse(this.responseText); if (j.posts) { posts = j.posts; render(); } if (j.error) alert(j.error); } catch (e) { }
        };
        i.send(body);
      }
      var inp = document.getElementById('postin');
      if (inp) inp.addEventListener('keydown', function(e) {
        if (e.key != 'Enter') return;
        e.preventDefault();
        var t = inp.value.replace(/\\s+/g, ' ').trim();
        if (!t) return;
        inp.value = '';
        call('post.json', 'text=' + encodeURIComponent(t));
      });
    })();
    </script>
      </body>
    </html>
END

} elsif ($func eq 'thotz.json') {

  # this nom's own system prompt: only the nom itself reads or writes it
  $user ne '' && $user eq $nom or die "not your thotz";
  my $err;
  $err = thotz_write($nom, scalar($cgi->param('text'))) if ($ENV{REQUEST_METHOD} // '') eq 'POST';
  my $cur = thotz_read($nom);
  print_json(JSON::PP->new->canonical(1)->ascii(1)->encode(+{ ok => ($err ? 0 : 1), ($err ? (error => $err) : ()), nom => $nom, text => $cur, custom => ($cur ne '' ? 1 : 0) }));

} elsif ($func eq 'thotz') {

  # the settings page behind the thotz button: a textarea holding this nom's system prompt, which only the nom itself
  # may see or change (anyone else is sent to their own, or to the wall).  Clearing it brings back the hashed personality.
  if ($user eq '' || $user ne $nom) {
    my $to = $user ne '' ? "/$user/thotz" : "/$nom";
    print "Status: 302\r\nLocation: $to\r\nContent-Length: 0\r\nContent-Type: text/html\r\n\r\n";
    exit 0;
  }
  my $subhead = html::subhead($nom);
  my $mine = 1;
  my $ro = '';
  my ($f, $ph) = ($html::fontasy, $html::phont);
  my $buttons = $mine ? qq{
          <table cellpadding="0" cellspacing="0" style="margin-top: 12px"><tr>
            <td style="font-size: 40px">[
              <img id="thotzsave" class="button" height="24" width="64" src="$f$ph.png?txt=save&dim=8&chop=0" title="save"/> |
              <img id="thotzreset" class="redbutton" height="24" width="80" src="$f$ph.png?txt=reset&dim=8&chop=0" title="back to the default personality"/>
            ]</td>
            <td width="16"></td>
            <td id="thotzmsg" style="font-family: monospace; font-size: 18px; color: #66ff66"></td>
          </tr></table>
  } : '';

  print "Content-Type: text/html; charset=utf-8\r\n\r\n";
  print <<"END";
    <html>
    <head>
    <title>peaple.io / $nom / thotz</title>
    </head>
      <body bgcolor="#000000" text="#ffffff" link="#9999ff" vlink="#bb99ff">
        $html::header
        $subhead
        <table width="1280" cellpadding="0" cellspacing="0"><tr>
          <td width="128" valign="top"><a href="/$nom"><img src="/$nom.png?dim=128&nostamp=1" width="128" height="128"/></a></td>
          <td width="16"></td>
          <td valign="top">
            <img height="24" src="$f$ph.png?txt=what+$nom+thinks+%28system+prompt%29&dim=8&chop=0"/>
            <textarea id="thotztext" maxlength="2000" rows="14" spellcheck="false" $ro
              style="display: block; margin-top: 8px; width: 1136px; box-sizing: border-box; font-family: monospace; font-size: 18px; padding: 8px; background: #111111; color: #ffffff; border: 2px solid #444444; outline: none; resize: vertical"></textarea>
            $buttons
          </td>
        </tr></table>
    <script>
    (function() {
      var nom = "$nom", mine = $mine;
      var ta = document.getElementById('thotztext'), msg = document.getElementById('thotzmsg');
      function say(t, bad) { if (msg) { msg.style.color = bad ? '#ff6666' : '#66ff66'; msg.textContent = t; } }
      function get(url, cb) { var i = new XMLHttpRequest; i.open('GET', url); i.onload = function() { cb(this.responseText); }; i.send(); }
      // the hashed personality is the placeholder: it is what applies while the box is empty
      get('/' + nom + '/persona.txt?default=1', function(t) { ta.placeholder = 'default: ' + t; });
      get('/' + nom + '/thotz.json', function(t) { try { ta.value = JSON.parse(t).text || ''; } catch (e) { } });
      function save(text) {
        var i = new XMLHttpRequest;
        i.open('POST', '/' + nom + '/thotz.json');
        i.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
        i.onload = function() {
          try {
            var j = JSON.parse(this.responseText);
            if (!j.ok) { say(j.error || 'failed', true); return; }
            ta.value = j.text || '';
            say(j.custom ? 'saved' : 'default personality');
          } catch (e) { say('failed', true); }
        };
        i.onerror = function() { say('failed', true); };
        i.send('text=' + encodeURIComponent(text));
      }
      if (mine) {
        document.getElementById('thotzsave').onclick = function() { save(ta.value); };
        document.getElementById('thotzreset').onclick = function() { save(''); };
        ta.addEventListener('input', function() { say(''); });
      }
    })();
    </script>
      </body>
    </html>
END

} elsif ($func eq 'chat') {

  # chat with the parson: picture left, fixed-width transcript canvas right (your lines in mork, the parson's in titulus,
  # drawn from the phont glyph grids client-side so streamed tokens render as they arrive), one-line entry bar below.
  # The reply streams from /$nom/chat.sse (devserver.py -> llama-server) with a persona derived from the nom.
  my $subhead = html::subhead($nom);
  my $pfont = $nom eq 'makemore_support' ? 'they' : 'titulus';   # the parson's phont; a few specials answer in another

  print "Content-Type: text/html\r\n\r\n";
  print <<"END";
    <html>
    <head>
    <title>peaple.io / $nom / chat</title>
    <meta property='og:title' content='$nom'>
    <meta property='og:image' content='https://peaple.io/$nom.png'>
    <meta property='og:url' content='https://peaple.io/$nom/chat'>
    <link rel='canonical' href='https://peaple.io/$nom/chat'>
    </head>
      <body bgcolor="#000000" text="#ffffff" link="#9999ff" vlink="#bb99ff">
        $html::header
        $subhead

        <table width="1280" cellpadding="0" cellspacing="0"><tr>
          <td valign="top" width="512"><a href="/$nom/fam"><img id="pic" src="/$nom.png?dim=512" width="512" height="512"/></a></td>
          <td width="16"></td>
          <td valign="top">
            <canvas id="chatcan" width="736" height="456" style="display: block; background: #000000"></canvas>
            <div style="width: 736px; height: 56px; padding-top: 8px; box-sizing: border-box">
              <input id="chatin" type="text" maxlength="400" autocomplete="off"
                style="width: 100%; box-sizing: border-box; font-size: 22px; padding: 8px; background: #111111; color: #ffffff; border: 2px solid #444444; outline: none"/>
            </div>
          </td>
        </tr></table>

    <script>
    (function() {
      var nom = "$nom";
      var COLS = 46, ROWS = 19, CW = 16, CH = 24;
      var can = document.getElementById('chatcan'), ctx = can.getContext('2d');
      var inp = document.getElementById('chatin');
      var sheets = {};
      ['$html::phont', '$pfont'].forEach(function(n) {
        var im = new Image(); im.onload = draw; im.src = '/fontasy/' + n + '.png?grid=8'; sheets[n] = im;
      });
      var transcript = [];   // {who: 'user'|'parson', text: '...'}
      var busy = false;

      function ascii(t) {   // the phonts have the 96 printable ASCII glyphs; fold curly quotes, dashes, accents
        return t.replace(/[\\u2018\\u2019\\u201a\\u2032]/g, "'").replace(/[\\u201c\\u201d\\u201e\\u2033]/g, '"')
                .replace(/[\\u2013\\u2014\\u2015]/g, '-').replace(/\\u2026/g, '...').replace(/\\u00a0/g, ' ')
                .normalize('NFKD').replace(/[\\u0300-\\u036f]/g, '');
      }
      function wrap(text, cols) {
        var lines = [], line = '';
        text = ascii(text);
        text.split(/\\s+/).forEach(function(w) {
          while (w.length > cols) { if (line) { lines.push(line); line = ''; } lines.push(w.substr(0, cols)); w = w.substr(cols); }
          if (!w) return;
          if (line && line.length + 1 + w.length > cols) { lines.push(line); line = w; }
          else line = line ? line + ' ' + w : w;
        });
        if (line) lines.push(line);
        return lines;
      }
      function drawText(phont, s, x, y) {
        var im = sheets[phont]; if (!im || !im.complete) return;
        for (var i = 0; i < s.length; ++i) {
          var c = s.charCodeAt(i); if (c < 0x20 || c > 0x7e) c = 0x7f;
          var k = c - 0x20;
          ctx.drawImage(im, (k % 12) * CW, Math.floor(k / 12) * CH, CW, CH, x + i * CW, y, CW, CH);
        }
      }
      function draw() {
        ctx.fillStyle = '#000000'; ctx.fillRect(0, 0, can.width, can.height);
        var rows = [];
        transcript.forEach(function(m, i) {
          if (i) rows.push(null);
          var ph = m.who == 'user' ? '$html::phont' : '$pfont';   // you type in mork (learn it by typing), the parson answers in titulus
          wrap(m.text || (m.who == 'parson' && busy ? '...' : ''), COLS).forEach(function(l) { rows.push([ph, l, m.who != 'user']); });
        });
        if (rows.length > ROWS) rows = rows.slice(rows.length - ROWS);
        rows.forEach(function(r, i) {
          if (!r) return;
          drawText(r[0], r[1], 0, i * CH);
          if (r[2]) {   // the parson's lines are tinted, so the two sides differ even when both use the same phont
            ctx.globalCompositeOperation = 'multiply';
            ctx.fillStyle = '#66ffff';
            ctx.fillRect(0, i * CH, can.width, CH);
            ctx.globalCompositeOperation = 'source-over';
          }
        });
      }

      function send() {
        var text = inp.value.replace(/\\s+/g, ' ').trim();
        if (!text || busy) return;
        inp.value = '';
        transcript.push({who: 'user', text: text});
        var reply = {who: 'parson', text: '', tools: []};
        transcript.push(reply);
        busy = true; inp.disabled = true; draw();
        var msgs = transcript.slice(0, -1).map(function(m) { var o = {role: m.who == 'user' ? 'user' : 'assistant', content: m.text}; if (m.tools && m.tools.length) o.tools = m.tools; return o; });
        fetch('/' + nom + '/chat.sse', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({messages: msgs})})
        .then(function(resp) {
          if (!resp.ok) { reply.text = '(' + nom + ' is asleep)'; return; }
          var reader = resp.body.getReader(), dec = new TextDecoder(), buf = '';
          function pump() {
            return reader.read().then(function(r) {
              if (r.done) return;
              buf += dec.decode(r.value, {stream: true});
              var lines = buf.split('\\n'); buf = lines.pop();
              lines.forEach(function(l) {
                if (l.indexOf('data: ') != 0) return;
                var d = l.substr(6); if (d == '[DONE]') return;
                try { var j = JSON.parse(d); var dl = j.choices && j.choices[0].delta; if (dl && dl.tool) { reply.tools.push(dl.tool); if (dl.tool.name == 'xform') document.getElementById('pic').src = '/' + nom + '.png?dim=512&t=' + Date.now(); } var t = dl && dl.content; if (t) { reply.text += t; draw(); } } catch (e) {}
              });
              return pump();
            });
          }
          return pump();
        })
        .catch(function() { reply.text = reply.text || '(' + nom + ' wandered off)'; })
        .then(function() { busy = false; inp.disabled = false; draw(); inp.focus(); });
      }
      inp.addEventListener('keydown', function(e) { if (e.key == 'Enter') { e.preventDefault(); send(); } });
      inp.focus();
      draw();
    })();
    </script>
      </body>
    </html>
END

} elsif ($func eq 'gogh') {

  my $subhead = html::subhead($nom);

  print "Content-Type: text/html\r\n\r\n";
  print qq<
    <html>
      <head>
      <title>peaple.io / $nom / gogh</title>

      <meta property='og:title' content='$nom'>
      <meta property='og:description' content='$nom'>
      <meta property='og:image' content='https://peaple.io/$nom.png?dim=1024'>
      <meta property='og:image:type' content='image/png'>
      <meta property='og:image:width' content='512'>
      <meta property='og:image:height' content='512'>
      <meta property='og:url' content='https://peaple.io/$nom/gogh'>
      <meta property='og:type' content='article'>
      <link rel='canonical' href='https://peaple.io/$nom/gogh'>

      </head>
      <body bgcolor="#000000" text="#ffffff" link="#9999ff" vlink="#bb99ff">
        $html::header
        $subhead

        <table width="1280"><tr><td align="center">
          <img src="/$nom.png?dim=1024" width="1024" height="1024"/>
        </td></tr></table>
      </body>
    </html>
  >;

} elsif ($func eq 'fam') {

  my $vis = $peaple->load_visage($nom);
  my $pvis0 = $peaple->load_visage($vis->paren(0), $vis);
  my $pvis1 = $peaple->load_visage($vis->paren(1), $vis);
  my $gpvis0 = $peaple->load_visage($pvis0->paren(0), $pvis0, 0);
  my $gpvis1 = $peaple->load_visage($pvis0->paren(1), $pvis0, 1);
  my $gpvis2 = $peaple->load_visage($pvis1->paren(0), $pvis1, 0);
  my $gpvis3 = $peaple->load_visage($pvis1->paren(1), $pvis1, 1);
  
  my $jskids = encode_json([reverse($vis->kids)]);

  my $subhead = html::subhead($nom);
  
  print "Content-type: text/html\r\n\r\n";
  
  print qq{
    <html>
    <head>
    <title>peaple.io / $nom / fam</title>

    <meta property='og:title' content='$nom'>
    <meta property='og:description' content='$nom'>
    <meta property='og:image' content='https://peaple.io/$nom.png'>
    <meta property='og:image:type' content='image/png'>
    <meta property='og:image:width' content='512'>
    <meta property='og:image:height' content='512'>
    <meta property='og:url' content='https://peaple.io/$nom/fam'>
    <meta property='og:type' content='article'>
    <link rel='canonical' href='https://peaple.io/$nom/fam'>
  
    <script>
      function addkid(kid) {
        while (kidrow.cells.length >= 7) {
          kidrow.deleteCell(kidrow.cells.length - 1);
        }
      
        kidrow.insertCell(0);
        var kidcell = kidrow.cells[0];
        kidcell.innerHTML = '<a href="/' + kid + '/fam"><img width="128" height="128" src="/' + kid + '.png?dim=128"></a>';
      }

      function onl() {
        var kids = $jskids;
        for (var i in kids) {
          addkid(kids[i]);
        }
      }
    </script>
    </head>
  
    <body bgcolor="#000000" text="#ffffff" link="#9999ff" vlink="#bb99ff" onload="onl()">

    $html::header
    $subhead

    <table width="1280"> <tr><td>
  
    <table cellspacing=0 cellpadding=0 align="center">
    
    <tr>
      <td><a href="/$$gpvis0{nom}/fam"><img src="/$$gpvis0{nom}.png?dim=128" width=128 height=128></a></td>
      <td rowspan=2><a href="/$$pvis0{nom}/fam"><img src="/$$pvis0{nom}.png?dim=256" width=256 height=256></a></td>
      <td rowspan=4><a href="/$$vis{nom}/frens"><img src="/$$vis{nom}.png?dim=512" width=512 height=512></a></td>
    </tr>
    <tr>
      <td><a href="/$$gpvis1{nom}/fam"><img src="/$$gpvis1{nom}.png?dim=128" width=128 height=128></a></td>
    </tr>
    <tr>
      <td><a href="/$$gpvis2{nom}/fam"><img src="/$$gpvis2{nom}.png?dim=128" width=128 height=128></a></td>
      <td rowspan=2><a href="/$$pvis1{nom}/fam"><img src="/$$pvis1{nom}.png?dim=256" width=256 height=256></a></td>
    </tr>
    <tr>
      <td><a href="/$$gpvis3{nom}/fam"><img src="/$$gpvis3{nom}.png?dim=128" width=128 height=128></a></td>
    </tr>
  
    </table>
    
    <br/>
    <br/>
    
    <table id="kidtab" cellspacing=0 cellpadding=0 align="center">
    <tr id="kidrow"></tr>
    </table>
  
    </td>
    </tr></table>
    
    </body>
    </html>
  };

} elsif ($func eq 'frens') {

  my $vis = $peaple->load_visage($nom);

  my @fimg = map
    qq<
      <img style="cursor: pointer" src="/$_.png?dim=128" width="128" height="128" onclick="clickfren('$_')"/>
    >,
    $vis->frens;

  my $subhead = html::subhead($nom);

  print "Content-type: text/html\r\n\r\n";

  print qq{
    <html>
    <head>
    <title>peaple.io / $nom / frens</title>

    <meta property='og:title' content='$nom'>
    <meta property='og:description' content='$nom'>
    <meta property='og:image' content='https://peaple.io/$nom.png'>
    <meta property='og:image:type' content='image/png'>
    <meta property='og:image:width' content='512'>
    <meta property='og:image:height' content='512'>
    <meta property='og:url' content='https://peaple.io/$nom/frens'>
    <meta property='og:type' content='article'>
    <link rel='canonical' href='https://peaple.io/$nom/frens'>

    <script>
      function clicktool(t) {
        breadbutton.style.outline = '3px solid blue';
        gotobutton.style.outline = "3px solid blue";

        var but = document.getElementById(t + "button");
        but.style.outline = "3px solid #00ff00";
        window.tool = t;
        var kd = document.getElementById('kidthotzdiv');     // logged in: the kid's system prompt can be written before breading
        if (kd) kd.style.display = (t == 'bread') ? 'block' : 'none';
      }
      window.tool = 'goto';

      function post(url, data, cb) {
        var i = new XMLHttpRequest;
        i.open('POST', url);
        i.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
        i.onload = function(e) {
          if (!(this.readyState == 4 && this.status == 200)) {
            return;
          }
          cb(this.responseText);
        }
        i.send(data);
      }

      function addfren(fren) {
        post("/$nom/addfren.json", "fren=" + escape(fren), function(x) {
          var z = JSON.parse(x);
          showfrens(z.frens);
          frenbuf.value = '';
        });
      }


      function clickfren(fren) {
        if (window.tool == 'goto') {
          location = "/" + fren + "/frens";
        } else if (window.tool == 'bread') {
          var kt = document.getElementById('kidthotz');
          post("/$nom/bread.json", "fren=" + escape(fren) + (kt && kt.value.trim() ? "&thotz=" + encodeURIComponent(kt.value) : ""), function(x) {
            var z = JSON.parse(x);
            location = "/" + z.nom + "/fam";
          });
        }
      }

      function showfrens(frens) {
        var html = "<table cellpadding='0' cellspacing='0'>";
        for (var i = 0; i < 16; ++i) {
          if (i % 4 == 0) {
            html += "<tr>";
          }
          html += "<td width='128' height='128'>";

          if (frens[i]) {
            html += "<img src='/" + frens[i] + ".png?dim=128' style='cursor: pointer' width='128' height='128' onclick='clickfren(" + '"' + frens[i] + '"' + ")'/>";
          }

          html += "</td>";
          if (i % 4 == 3) {
            html += "</tr>";
          }
        }

        var frenselem = document.getElementById('frens');
        frenselem.innerHTML = html;
      }

      function onl() {
        clicktool('goto');
      }
    </script>
    </head>
  
    <body bgcolor="#000000" text="#ffffff" link="#9999ff" vlink="#bb99ff" onload="onl()">

    $html::header
    $subhead

    <table width=1280 cellpadding=0 cellspacing=0>
      <tr valign="top">
        <td width=512 align="center">
    
          <table><tr><td>
            <div id="addfrenform">
              <table><tr><td valign="center">
                <input type="text" maxlength="32" size="32" id="frenbuf" placeholder="nom" style='font-size: 20px; font-family: monospace' onKeyPress="if (event.which == 13) { addfren(this.value) }">
              </td>
              <td style="width: 4px"></td>
              <td valign="center">
                <img class="button" src="$html::fontasy$html::phont.png?txt=addfren&chop=0&dim=8" align="bottom" onClick="addfren(frenbuf.value)">
              </td></tr></table>
            </div>
          </td></tr></table>

          <div id="frens">
          <table cellpadding="0" cellspacing="0">
            <tr>
              <td width='128' height='128'>$fimg[0]</td>
              <td width='128' height='128'>$fimg[1]</td>
              <td width='128' height='128'>$fimg[2]</td>
              <td width='128' height='128'>$fimg[3]</td>
            </tr>
            <tr>
              <td width='128' height='128'>$fimg[4]</td>
              <td width='128' height='128'>$fimg[5]</td>
              <td width='128' height='128'>$fimg[6]</td>
              <td width='128' height='128'>$fimg[7]</td>
            </tr>
            <tr>
              <td width='128' height='128'>$fimg[8]</td>
              <td width='128' height='128'>$fimg[9]</td>
              <td width='128' height='128'>$fimg[10]</td>
              <td width='128' height='128'>$fimg[11]</td>
            </tr>
            <tr>
              <td width='128' height='128'>$fimg[12]</td>
              <td width='128' height='128'>$fimg[13]</td>
              <td width='128' height='128'>$fimg[14]</td>
              <td width='128' height='128'>$fimg[15]</td>
            </tr>
          </table>
          </div>

        </td>
        <td align=center>
          <table cellpadding=0 cellspacing=0>
            <tr>
              <td colspan=4>
                <a href="/$nom/xform"><img id="pic" width="512" height="512" src="/$nom.png?dim=512" /></a>
              </td>
            </tr>
          </table>
        </td>
    
        <td align=right>
          <table>
            <tr><td>
              <table>
                <tr><td align=right height="36">
                  <img id="gotobutton" style="outline: 3px solid #00ff00" src="$html::fontasy$html::phont.png?txt=goto&chop=0&dim=8" onclick="clicktool('goto')">
                </td></tr>
                <tr><td align=right height="36">
                  <img id="breadbutton" class="button" src="$html::fontasy$html::phont.png?txt=bread&chop=0&dim=8" onclick="clicktool('bread')">
                </td></tr>
              </table>
            </td></tr>
            <tr><td height="16"></td></tr>
          </table>
        </td>
      </tr>
    </table>
    
    @{[ $user ne '' ? qq{<div id="kidthotzdiv" style="display: none; width: 1280px; margin-top: 12px">
      <textarea id="kidthotz" maxlength="2000" rows="3" spellcheck="false" placeholder="thotz for the kid (its system prompt), optional: write it, then click a fren to bread"
        style="width: 1280px; box-sizing: border-box; font-family: monospace; font-size: 18px; padding: 8px; background: #111111; color: #ffffff; border: 2px solid #444444; outline: none; resize: vertical"></textarea>
    </div>} : '' ]}
    </body>
    </html>
  };

} elsif ($func eq 'xform') {

  my $vis = $peaple->load_visage($nom);

  my $subhead = html::subhead($nom);

  print "Content-type: text/html\r\n\r\n";

  print qq{
    <html>
    <head>
    <title>peaple.io / $nom / xform</title>
    </head>

    <meta property='og:title' content='$nom'>
    <meta property='og:description' content='$nom'>
    <meta property='og:image' content='https://peaple.io/$nom.png'>
    <meta property='og:image:type' content='image/png'>
    <meta property='og:image:width' content='512'>
    <meta property='og:image:height' content='512'>
    <meta property='og:url' content='https://peaple.io/$nom/xform'>
    <meta property='og:type' content='article'>
    <link rel='canonical' href='https://peaple.io/$nom/xform'>
  
    <script>
      function get(url, cb) {
        var i = new XMLHttpRequest;
        i.open('GET', url);
        i.onload = function(e) {
          if (!(this.readyState == 4 && this.status == 200)) {
            return;
          }
          cb(this.responseText);
        }
        i.send();
      }
      function post(url, data, cb) {
        var i = new XMLHttpRequest;
        i.open('POST', url);
        i.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
        i.onload = function(e) {
          if (!(this.readyState == 4 && this.status == 200)) {
            return;
          }
          cb(this.responseText);
        }
        i.send(data);
      }
      function randstr() {
        return "" + Math.floor(Math.random() * 1000000000);
      }

      function addrandpals(n) {
        get("/pick.json?n=" + n, function(x) {
          var z = JSON.parse(x);
          for (var i in z) {
            addpal(z[i]);
          }
        });
      }

      var pals = new Array(16);
      var npals = 0;
      var mul = 0.2;   // fraction of the way to the clicked pal per click (0.5 snapped to the target almost at once)

      function addpal(pal) {
        if (pal == '') {
          get("/pick.json?n=1", function(x) {
            var z = JSON.parse(x);
            addpal(z[0]);
          });
          return;
        }

        var ipal;
        if (npals < 16) {
          ipal = npals;
          ++npals;
        } else {
          ipal = 0;
          for (var i = 15; i > 0; --i) {
            var paltdi = document.getElementById('pal' + i);
            var paltdp = document.getElementById('pal' + (i - 1));
            paltdi.innerHTML = paltdp.innerHTML;
            pals[i] = pals[i - 1];
          }
        }
       
        pals[ipal] = pal;
        var paltd = document.getElementById('pal' + ipal);
        var rnd = randstr();
        paltd.innerHTML = "<img src='/" + pal + ".png?rnd=" + rnd +
          "&dim=128' style='cursor: pointer' width='128' height='128' " +
          "onclick='clickpal(" + '"' + pal + '"' + ")'/>";

        document.getElementById('palbuf').value = '';
      }

      function clickpal(pal) {
        pic.style.outline = '3px solid yellow';
        post("/$nom/blend.json", "fren=" + pal + "&mul=" + mul, function(x) {
          var pic = document.getElementById('pic');
          var rnd = randstr();
          pic.src = "/$nom.png?dim=512&rnd=" + rnd;
        });
      }

      function onl() {
        addrandpals(16);
      }
    </script>

    <body bgcolor="#000000" text="#ffffff" link="#9999ff" vlink="#bb99ff" onload="onl()">
    $html::header
    $subhead

    <table width=1280 cellpadding=0 cellspacing=0>
      <tr valign="top">
        <td width=512 align="center">
          <a href="/$nom/enc"><img id="pic" src="/$nom.png?dim=512" width="512" height="512" onLoad="this.style.outline = ''"></a>
        </td>

        <td width="32"></td>

        <td>


          <div id="addpalform">
            <table><tr><td valign="center">
              <input type="text" maxlength="32" size="32" id="palbuf" placeholder="nom" style='font-size: 20px; font-family: monospace' onKeyPress="if (event.which == 13) { addpal(this.value) }">
            </td>
            <td style="width: 4px"></td>
            <td valign="center">
              <img class="button" src="$html::fontasy$html::phont.png?txt=addpal&chop=0&dim=8" align="bottom" onClick="addpal(palbuf.value)">
            </td></tr></table>
          </div>





          <table cellpadding="0" cellspacing="0">
            <tr>
              <td width='128' height='128' id='pal0'></td>
              <td width='128' height='128' id='pal1'></td>
              <td width='128' height='128' id='pal2'></td>
              <td width='128' height='128' id='pal3'></td>
            </tr>
            <tr>
              <td width='128' height='128' id='pal4'></td>
              <td width='128' height='128' id='pal5'></td>
              <td width='128' height='128' id='pal6'></td>
              <td width='128' height='128' id='pal7'></td>
            </tr>
            <tr>
              <td width='128' height='128' id='pal8'></td>
              <td width='128' height='128' id='pal9'></td>
              <td width='128' height='128' id='pal10'></td>
              <td width='128' height='128' id='pal11'></td>
            </tr>
            <tr>
              <td width='128' height='128' id='pal12'></td>
              <td width='128' height='128' id='pal13'></td>
              <td width='128' height='128' id='pal14'></td>
              <td width='128' height='128' id='pal15'></td>
            </tr>
          </table>
          </div>
        </td>
      </tr>
    </table>

    </body>
    </html>
  };

} elsif ($func eq 'enc') {

  my $vis = $peaple->load_visage($nom);

  my $subhead = html::subhead($nom);

  print "Content-type: text/html\r\n\r\n";

  print qq{
    <html>
    <head>
    <title>peaple.io / $nom / enc</title>
    </head>

    <meta property='og:title' content='$nom'>
    <meta property='og:description' content='$nom'>
    <meta property='og:image' content='https://peaple.io/$nom.png'>
    <meta property='og:image:type' content='image/png'>
    <meta property='og:image:width' content='512'>
    <meta property='og:image:height' content='512'>
    <meta property='og:url' content='https://peaple.io/$nom/enc'>
    <meta property='og:type' content='article'>
    <link rel='canonical' href='https://peaple.io/$nom/enc'>

    <script>
      function postfile(url, data, cb) {
        var i = new XMLHttpRequest;
        i.open('POST', url);
        i.setRequestHeader('Content-Type', 'multipart/form-data');
        var fd = new FormData();
        fd.append("file", data);

        i.onload = function(e) {
          if (!(this.readyState == 4 && this.status == 200)) {
            return;
          }
          cb(this.responseText);
        }
        i.send(fd);
      }
      function post(url, data, cb) {
        var i = new XMLHttpRequest;
        i.open('POST', url);
        i.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
        i.onload = function(e) {
          if (!(this.readyState == 4 && this.status == 200)) {
            return;
          }
          cb(this.responseText);
        }
        i.send(data);
      }

    if (0) {
      u = new URL(window.location);
      if (u.protocol != 'https:') {
        u.protocol = 'https:';
        if (window.location != u) {
          window.location = u;
        }
      }
    }
    
    function got_media(mediaStream) {
      window.mediaStream = mediaStream
      window.mediaStreamTrack = mediaStream.getVideoTracks()[0];
    
      window.imageCapture = new ImageCapture(window.mediaStreamTrack);
      window.camera_enabled = 1
      vid.srcObject = mediaStream;
    
      vid.onloadedmetadata = function() {
        var w = this.videoWidth;
        var h = this.videoHeight;
        vid.style.width = w;
        vid.style.height = h;
    
        capbutton.style.outline = "3px solid #00ff00";
        viddiv.style.display = 'block';
        capbutton.onclick = function() { stopvid() };
      }
    }
    
    function ask_camera() {
      navigator.mediaDevices.getUserMedia({video: true})
      .then(got_media)
      .catch(error => {
         // console.error('getUserMedia() error:', error);
         capbutton.style.outline = "3px solid red";
         capbutton.onclick = function() { alert("camera not available"); }
      });
    }
    
    function loadimg() {
      upcan.height = Math.floor(640 * this.height / this.width);
      upcan.getContext('2d').drawImage(this, 0, 0, upcan.width, upcan.height);
      window.saved = upcan.getContext('2d').getImageData(0, 0, upcan.width, upcan.height);
    
      stopvid();
      upcandiv.style.display = 'block';
      pqrdiv.style.display = 'block';
    
      upcan.toBlob(function(bl) {
        postfile("/$nom/source.json", bl, function(x) {

          uplab.style.outline = "3px solid blue";
          reloadpic();

          httpget("/$nom/source.json", function(j) {
            upcan.getContext('2d').imageSmoothingEnabled = false;
            var tri = JSON.parse(j);
            var c;
            c = 0x70; upcan.getContext('2d').drawImage(mork, (c % 16) * 2, Math.floor(c / 16) * 3 + 1, 2, 2, tri.p[0] - 8, tri.p[1] - 8, 2 * 8, 2 * 8);
            c = 0x71; upcan.getContext('2d').drawImage(mork, (c % 16) * 2, Math.floor(c / 16) * 3 + 1, 2, 2, tri.q[0] - 8, tri.q[1] - 8, 2 * 8, 2 * 8);
            c = 0x72; upcan.getContext('2d').drawImage(mork, (c % 16) * 2, Math.floor(c / 16) * 3 + 1, 2, 2, tri.r[0] - 8, tri.r[1] - 8, 2 * 8, 2 * 8);
            window.pqr = [tri.p, tri.q, tri.r];
          });
        });
      
      }, 'image/jpeg', 0.95);
    }
    
    function geturl(url) {
      var im = new Image();
      im.onload = loadimg;
      im.src = url;
    }
    
    function upfile() {
      var f = fileupload.files[0];
      if (f.type != 'image/jpeg' && f.type != 'image/png' || f.size > 4096*4096) {
        uplab.style.outline = "3px solid red";
        window.setTimeout(function() {
          uplab.style.outline = "3px solid blue";
        }, 500);
        return;
      }
      uplab.style.outline = "3px solid yellow";
    
      var img = new Image();
      img.onload = loadimg;
      img.src = URL.createObjectURL(f);
    }
    
    function capcam() {
      upcan.height = Math.floor(vid.videoHeight * 640 / vid.videoWidth);
    //  upcan.getContext('2d').translate(upcan.width, 0);
    //  upcan.getContext('2d').scale(-1, 1);
      upcan.getContext('2d').drawImage(vid, 0, 0, upcan.width, upcan.height);
      window.saved = upcan.getContext('2d').getImageData(0, 0, upcan.width, upcan.height);
    
      upcandiv.style.display = 'block';
      pqrdiv.style.display = 'block';
    
      viddiv.style.display = 'none';
      capbutton.onclick = function() { startvid() };
      capbutton.style.outline = "3px solid blue";
    
      upcan.toBlob(function(blob) {
        postfile("/$nom/source.json", blob, function(x) {

          httpget("/$nom/source.json", function(j) {
            upcan.getContext('2d').imageSmoothingEnabled = false;
            var tri = JSON.parse(j);
            var c;
            c = 0x70; upcan.getContext('2d').drawImage(mork, (c % 16) * 2, Math.floor(c / 16) * 3 + 1, 2, 2, tri.p[0] - 8, tri.p[1] - 8, 2 * 8, 2 * 8);
            c = 0x71; upcan.getContext('2d').drawImage(mork, (c % 16) * 2, Math.floor(c / 16) * 3 + 1, 2, 2, tri.q[0] - 8, tri.q[1] - 8, 2 * 8, 2 * 8);
            c = 0x72; upcan.getContext('2d').drawImage(mork, (c % 16) * 2, Math.floor(c / 16) * 3 + 1, 2, 2, tri.r[0] - 8, tri.r[1] - 8, 2 * 8, 2 * 8);
            window.pqr = [tri.p, tri.q, tri.r];
            reloadpic();
          });
        });
      });
    }
    
    
    function get_nom() {
      var nom = window.location.pathname;
      nom = nom.substr(1);
      var slash = nom.indexOf('/');
      nom = nom.substr(0, slash);
      return nom;
    }
    window.nom = get_nom();
    
    function randstr() {
      return "" + Math.floor(Math.random() * 1000000000);
    }
    
    function httpget(url, cb) {
      var i = new XMLHttpRequest;
      i.open('GET', url);
      i.overrideMimeType("text/plain");
      i.onload = function(e) {
        if (!(this.readyState == 4 && this.status == 200)) {
          return;
        }
        cb(this.responseText);
      }
      i.send();
    }
    
    function reloadpic() {
      pic.src = "/" + window.nom + ".png" + "?rnd=" + randstr();
    }
    
    function startvid() {
      ask_camera();
      capbutton.style.outline = "3px solid yellow";
      upcandiv.style.display = 'none';
      pqrdiv.style.display = 'none';
      viddiv.style.display = 'none';
    
    }
    
    function stopvid() {
      if (window.mediaStream) {
        window.mediaStream.getTracks().forEach(function(track) {
          track.stop();
        });
      }
      capbutton.onclick = function() { startvid() };
      capbutton.style.outline = "3px solid blue";
      viddiv.style.display = 'none';
      upcandiv.style.display = 'none';
      pqrdiv.style.display = 'none';
    }
    
    function clickauto() {
      window.posetool = 'auto';
      document.getElementById('pbutton').style.outlineColor = 'blue';
      document.getElementById('qbutton').style.outlineColor = 'blue';
      document.getElementById('rbutton').style.outlineColor = 'blue';
      document.getElementById('autobutton').style.outlineColor = '#00ff00';
    }
    function clickp() {
      window.posetool = 'p';
      document.getElementById('pbutton').style.outlineColor = '#00ff00';
      document.getElementById('qbutton').style.outlineColor = 'blue';
      document.getElementById('rbutton').style.outlineColor = 'blue';
      document.getElementById('autobutton').style.outlineColor = 'blue';
    }
    function clickq() {
      window.posetool = 'q';
      document.getElementById('pbutton').style.outlineColor = 'blue';
      document.getElementById('qbutton').style.outlineColor = '#00ff00';
      document.getElementById('rbutton').style.outlineColor = 'blue';
      document.getElementById('autobutton').style.outlineColor = 'blue';
    }
    function clickr() {
      window.posetool = 'r';
      document.getElementById('pbutton').style.outlineColor = 'blue';
      document.getElementById('qbutton').style.outlineColor = 'blue';
      document.getElementById('rbutton').style.outlineColor = '#00ff00';
      document.getElementById('autobutton').style.outlineColor = 'blue';
    }
    
    function canhighout() {
      if (window.posetool == 'auto') {
        document.getElementById('pbutton').style.outlineColor = 'blue';
        document.getElementById('qbutton').style.outlineColor = 'blue';
        document.getElementById('rbutton').style.outlineColor = 'blue';
      }
    }
    
    function canhigh() {
      if (!window.pqr) {
        return;
      }
      if (window.posetool != 'auto') {
        return;
      }
    
      var x = event.offsetX;
      var y = event.offsetY;
    
      var i = 0;
      var d = Math.pow(x - window.pqr[0][0], 2) + Math.pow(y - window.pqr[0][1], 2);
    
      var f = Math.pow(x - window.pqr[1][0], 2) + Math.pow(y - window.pqr[1][1], 2);
      if (f < d) {
        i = 1;
        d = f;
      }
      var f = Math.pow(x - window.pqr[2][0], 2) + Math.pow(y - window.pqr[2][1], 2);
      if (f < d) {
        i = 2;
        d = f;
      }
    
      var which = ['p', 'q', 'r'][i];
    
      document.getElementById('pbutton').style.outlineColor = 'blue';
      document.getElementById('qbutton').style.outlineColor = 'blue';
      document.getElementById('rbutton').style.outlineColor = 'blue';
      document.getElementById(which + 'button').style.outlineColor = '#00ff00';
      autobutton.style.outlineColor = '#00ff00';
    }
    
    function canclick() {
      if (!window.pqr || !window.posetool) {
        return;
      }
    
      var x = event.offsetX;
      var y = event.offsetY;
    
      var which;
      if (window.posetool == 'auto') {
        var i = 0;
        var d = Math.pow(x - window.pqr[0][0], 2) + Math.pow(y - window.pqr[0][1], 2);
    
        var f = Math.pow(x - window.pqr[1][0], 2) + Math.pow(y - window.pqr[1][1], 2);
        if (f < d) {
          i = 1;
          d = f;
        }
        var f = Math.pow(x - window.pqr[2][0], 2) + Math.pow(y - window.pqr[2][1], 2);
        if (f < d) {
          i = 2;
          d = f;
        }
    
        which = ['p', 'q', 'r'][i];
      } else {
        which = window.posetool;
        if (which != 'p' && which != 'q' && which != 'r') {
          return;
        }
      }
    
      post("/$nom/source.json", which + "x=" + x + "&" + which + "y=" + y, function(j) {
        upcan.getContext('2d').putImageData(window.saved, 0, 0);
    
        var tri = JSON.parse(j);
        var c;
        c = 0x70; upcan.getContext('2d').drawImage(mork, (c % 16) * 2, Math.floor(c / 16) * 3 + 1, 2, 2, tri.p[0] - 8, tri.p[1] - 8, 2 * 8, 2 * 8);
        c = 0x71; upcan.getContext('2d').drawImage(mork, (c % 16) * 2, Math.floor(c / 16) * 3 + 1, 2, 2, tri.q[0] - 8, tri.q[1] - 8, 2 * 8, 2 * 8);
        c = 0x72; upcan.getContext('2d').drawImage(mork, (c % 16) * 2, Math.floor(c / 16) * 3 + 1, 2, 2, tri.r[0] - 8, tri.r[1] - 8, 2 * 8, 2 * 8);
        window.pqr = [tri.p, tri.q, tri.r];
    
        reloadpic();
      });
    }
    
    </script>
    
    </head>
    
    <body bgcolor="#000000" text="#ffffff" link="#9999ff" vlink="#bb99ff">
    
    $html::header
    $subhead
    
    <img id="mork" src="/extra/mork.png" style="display: none" width=256 height=384>
    
    <table width=1280>
    
      <tr>
        <td align="center">
    
    
        </td>
      </tr>
    
      <tr style="height: 600px">
        <td align="center" valign="top" width=768>
    
    <table cellspacing=4 cellpadding=4><tr>
    <td>
      <img src="$html::fontasy$html::phont.png?txt=capture&chop=0&dim=8" width='112' height='24' align="bottom" onClick="startvid()" id="capbutton"/>
    </td>
    <td>
    <label id=uplab for="fileupload" style="outline: 3px solid blue; display: inline-block; cursor: pointer">
      <img src="$html::fontasy$html::phont.png?txt=upload&chop=0&dim=8" width='96' height='24' align="bottom" id="uploadbutton"/>
    </label>
    <input id="fileupload" style="display: none" type="file" onChange="upfile()"/>
    </td>
    
    </tr>
    
    
    </table>
    
          <div id="viddiv" style="width: 640px; border: 3px solid blue; display: none">
            <video id="vid" style="width: 640; cursor: pointer" autoplay onClick="capcam()"></video>
          </div>
    
          <div id="upcandiv" style="width: 640px; border: 3px solid #00ff00; display: none">
            <canvas id="upcan" width=640 onMouseMove="canhigh()" onMouseOut="canhighout()" onClick="canclick()"></canvas>
          </div>
    
          <div id="pqrdiv" style="display: none">
    <table cellspacing=4 cellpadding=4><tr>
    <td><img src="$html::fontasy$html::phont.png?txt=p&chop=1&dim=8&fg=ffffff&bg=000000" align="bottom" style="outline: 3px solid blue" onClick="clickp()" id="pbutton"/></td>
    <td><img src="$html::fontasy$html::phont.png?txt=q&chop=1&dim=8&fg=ffffff&bg=000000" align="bottom" style="outline: 3px solid blue" onClick="clickq()" id="qbutton"/></td>
    <td><img src="$html::fontasy$html::phont.png?txt=r&chop=1&dim=8&fg=ffffff&bg=000000" align="bottom" style="outline: 3px solid blue" onClick="clickr()" id="rbutton"/></td>
    <td><img src="$html::fontasy$html::phont.png?txt=auto&chop=0&dim=8" align="bottom" style="outline: 3px solid blue" onClick="clickauto()" id="autobutton"/></td>
    </tr></table>
    <script>window.posetool = 'auto';</script>
          </div>
    
    
    </td>
    
    
        <td align="center" valign="top" width=512>
           <a href="/$nom/grid"><img id="pic" src="/$nom.png?dim=512" width="512" height="512"></a>
        </td>
      </tr>
    <tr>
    
    
    <tr><td colspan=2>
    <br/><br/>
    <hr align="left" color="#444444" width=1280>
    <span style="color: #666666; font-family: monospace; font-size: 12px">
    Data uploaded may be retained indefinitely and used for any purpose.
    </span>
    </td></tr>
    </table>
    
    <script>
    startvid();
    </script>
    
    
    </body>
    </html>
    
  };
} elsif ($func eq 'mem') {

  my $subhead = html::subhead($nom);

  print "Content-type: text/html\r\n\r\n";

  print qq{
    <html>
    <head>
    <title>peaple.io / $nom / mem</title>

    <meta property='og:title' content='$nom'>
    <meta property='og:description' content='$nom'>
    <meta property='og:image' content='https://peaple.io/$nom.png'>
    <meta property='og:image:type' content='image/png'>
    <meta property='og:image:width' content='512'>
    <meta property='og:image:height' content='512'>
    <meta property='og:url' content='https://peaple.io/$nom/mem'>
    <meta property='og:type' content='article'>
    <link rel='canonical' href='https://peaple.io/$nom/mem'>
    
    <script>
    
    window.nom = "$nom";
    
    function shuffle(array) {
      var currentIndex = array.length, temporaryValue, randomIndex;
    
      // While there remain elements to shuffle...
      while (0 !== currentIndex) {
    
        // Pick a remaining element...
        randomIndex = Math.floor(Math.random() * currentIndex);
        currentIndex -= 1;
    
        // And swap it with the current element.
        temporaryValue = array[currentIndex];
        array[currentIndex] = array[randomIndex];
        array[randomIndex] = temporaryValue;
      }
    
      return array;
    }
    
    function randstr() {
      return "" + Math.floor(Math.random() * 1000000000);
    }

    function warpvar(x) {
      if (x >= 1) { return 1e12; }
      if (x <= -1) { return 1e-12; }
      return (x / (1 - x));
    }
    
    function unwarpvar(y) {
      return (y / (1 + y));
    }
    
    function onl() {
      window.nsolved = 0;
      var noms = new Array(18);
      for (var i = 0; i < 18; ++i) {
        // noms[i] = genfnom() + "_" + window.nom;
        // if (noms[i].length > 31) { noms[i] = window.nom; }
        noms[i] = randstr();
      }
    
      var ar = new Array(36);
      for (var i = 0; i < 36; ++i) {
        ar[i] = Math.floor(i / 2);
      }
    
      window.cells = new Array(36);
      window.solved = new Array(36);
    
      ar = shuffle(ar);
      for (var i = 0; i < 36; ++i) {
        window.cells[i] = noms[ar[i]];
        window.solved[i] = 0;
      }
    
      window.prev = -1;
      window.state = 0;
    }
    
    function onc(im) {
      var i = Math.floor(im.id.substr(3));
    
      if (window.state == 0) {
        if (window.solved[i]) {
          return;
        }
    
        var vdev = warpvar(window.mul);
        var im = document.getElementById('img' + i);
        var td = im.parentElement;
        td.style.borderColor = 'yellow';
        td.style.cursor = 'default';
        im.src = "/$nom.png" + "?dim=256&dev=" + vdev + "&rnd=" + window.cells[i];
        window.state = 1;
        window.prev = i;
        return;
      }
    
      if (window.state == 1) {
        if (i == window.prev)
          return;
    
        var vdev = warpvar(window.mul);
        var im = document.getElementById('img' + i);
        im.src = "/$nom.png?dim=256&dev=" + vdev + "&rnd=" + window.cells[i];
        var td = im.parentElement;
    
        if (window.cells[i] == window.cells[window.prev]) {
          td.style.borderColor = 'green';
          td.style.cursor = 'default';
          var imprev = document.getElementById('img' + window.prev);
          var tdprev = imprev.parentElement;
          tdprev.style.borderColor = 'green';
          tdprev.style.cursor = 'default';
    
          ++window.nsolved;
    if (window.nsolved == 18) { window.location = '/$nom/gogh'; }
    //if (window.nsolved == 18) { alert('great job'); }
          window.solved[i] = 1;
          window.solved[window.prev] = 1;
          window.state = 0;
          window.prev = -1;
        } else {
          td.style.borderColor = 'red';
          td.style.cursor = 'default';
          var imprev = document.getElementById('img' + window.prev);
          var tdprev = imprev.parentElement;
          tdprev.style.borderColor = 'red';
    
          window.setTimeout(function() {
            td.style.borderColor = 'blue';
            td.style.cursor = 'pointer';
            tdprev.style.borderColor = 'blue';
            tdprev.style.cursor = 'pointer';
    
            var vdev = warpvar(window.mul);
            document.getElementById('img' + i).src = "/extra/burning_ship.png";
            document.getElementById('img' + window.prev).src = "/extra/burning_ship.png";
            window.state = 0;
            window.prev = -1;
          }, 1000)
        }
    
        return;
      }
    }
    </script>
    </head>
    
    <body bgcolor="#000000" text="#ffffff" link="#9999ff" vlink="#bb99ff" onload="onl()">
    $html::header
    $subhead   

    <table width=1280 cellpadding=0 cellspacing=0>
    
    
    <tr><td align="center">
    <table><tr><td>
        <script>
          window.mul = 0.26;   // warpvar(0.26) = 0.35, the grid page's edge-middle deviation
        </script>
    </td></tr></table>
    </td></tr>
    
    <tr height=8></tr>
    
    <tr><td align=center>
    
    <table cellpadding=0 cellspacing=0>
    <tr>
      <td style="cursor: pointer; border: 2px solid blue"><img onclick="onc(this)" width="192" height="192" src="/extra/burning_ship.png" id="img0"></td>
      <td style="cursor: pointer; border: 2px solid blue"><img onclick="onc(this)" width="192" height="192" src="/extra/burning_ship.png" id="img1"></td>
      <td style="cursor: pointer; border: 2px solid blue"><img onclick="onc(this)" width="192" height="192" src="/extra/burning_ship.png" id="img2"></td>
      <td style="cursor: pointer; border: 2px solid blue"><img onclick="onc(this)" width="192" height="192" src="/extra/burning_ship.png" id="img3"></td>
      <td style="cursor: pointer; border: 2px solid blue"><img onclick="onc(this)" width="192" height="192" src="/extra/burning_ship.png" id="img4"></td>
      <td style="cursor: pointer; border: 2px solid blue"><img onclick="onc(this)" width="192" height="192" src="/extra/burning_ship.png" id="img5"></td>
    </tr>
    <tr>
      <td style="cursor: pointer; border: 2px solid blue"><img onclick="onc(this)" width="192" height="192" src="/extra/burning_ship.png" id="img6"></td>
      <td style="cursor: pointer; border: 2px solid blue"><img onclick="onc(this)" width="192" height="192" src="/extra/burning_ship.png" id="img7"></td>
      <td style="cursor: pointer; border: 2px solid blue"><img onclick="onc(this)" width="192" height="192" src="/extra/burning_ship.png" id="img8"></td>
      <td style="cursor: pointer; border: 2px solid blue"><img onclick="onc(this)" width="192" height="192" src="/extra/burning_ship.png" id="img9"></td>
      <td style="cursor: pointer; border: 2px solid blue"><img onclick="onc(this)" width="192" height="192" src="/extra/burning_ship.png" id="img10"></td>
      <td style="cursor: pointer; border: 2px solid blue"><img onclick="onc(this)" width="192" height="192" src="/extra/burning_ship.png" id="img11"></td>
    </tr>
    <tr>
      <td style="cursor: pointer; border: 2px solid blue"><img onclick="onc(this)" width="192" height="192" src="/extra/burning_ship.png" id="img12"></td>
      <td style="cursor: pointer; border: 2px solid blue"><img onclick="onc(this)" width="192" height="192" src="/extra/burning_ship.png" id="img13"></td>
      <td style="cursor: pointer; border: 2px solid blue"><img onclick="onc(this)" width="192" height="192" src="/extra/burning_ship.png" id="img14"></td>
      <td style="cursor: pointer; border: 2px solid blue"><img onclick="onc(this)" width="192" height="192" src="/extra/burning_ship.png" id="img15"></td>
      <td style="cursor: pointer; border: 2px solid blue"><img onclick="onc(this)" width="192" height="192" src="/extra/burning_ship.png" id="img16"></td>
      <td style="cursor: pointer; border: 2px solid blue"><img onclick="onc(this)" width="192" height="192" src="/extra/burning_ship.png" id="img17"></td>
    </tr>
    <tr>
      <td style="cursor: pointer; border: 2px solid blue"><img onclick="onc(this)" width="192" height="192" src="/extra/burning_ship.png" id="img18"></td>
      <td style="cursor: pointer; border: 2px solid blue"><img onclick="onc(this)" width="192" height="192" src="/extra/burning_ship.png" id="img19"></td>
      <td style="cursor: pointer; border: 2px solid blue"><img onclick="onc(this)" width="192" height="192" src="/extra/burning_ship.png" id="img20"></td>
      <td style="cursor: pointer; border: 2px solid blue"><img onclick="onc(this)" width="192" height="192" src="/extra/burning_ship.png" id="img21"></td>
      <td style="cursor: pointer; border: 2px solid blue"><img onclick="onc(this)" width="192" height="192" src="/extra/burning_ship.png" id="img22"></td>
      <td style="cursor: pointer; border: 2px solid blue"><img onclick="onc(this)" width="192" height="192" src="/extra/burning_ship.png" id="img23"></td>
    </tr>
    <tr>
      <td style="cursor: pointer; border: 2px solid blue"><img onclick="onc(this)" width="192" height="192" src="/extra/burning_ship.png" id="img24"></td>
      <td style="cursor: pointer; border: 2px solid blue"><img onclick="onc(this)" width="192" height="192" src="/extra/burning_ship.png" id="img25"></td>
      <td style="cursor: pointer; border: 2px solid blue"><img onclick="onc(this)" width="192" height="192" src="/extra/burning_ship.png" id="img26"></td>
      <td style="cursor: pointer; border: 2px solid blue"><img onclick="onc(this)" width="192" height="192" src="/extra/burning_ship.png" id="img27"></td>
      <td style="cursor: pointer; border: 2px solid blue"><img onclick="onc(this)" width="192" height="192" src="/extra/burning_ship.png" id="img28"></td>
      <td style="cursor: pointer; border: 2px solid blue"><img onclick="onc(this)" width="192" height="192" src="/extra/burning_ship.png" id="img29"></td>
    </tr>
    <tr>
      <td style="cursor: pointer; border: 2px solid blue"><img onclick="onc(this)" width="192" height="192" src="/extra/burning_ship.png" id="img30"></td>
      <td style="cursor: pointer; border: 2px solid blue"><img onclick="onc(this)" width="192" height="192" src="/extra/burning_ship.png" id="img31"></td>
      <td style="cursor: pointer; border: 2px solid blue"><img onclick="onc(this)" width="192" height="192" src="/extra/burning_ship.png" id="img32"></td>
      <td style="cursor: pointer; border: 2px solid blue"><img onclick="onc(this)" width="192" height="192" src="/extra/burning_ship.png" id="img33"></td>
      <td style="cursor: pointer; border: 2px solid blue"><img onclick="onc(this)" width="192" height="192" src="/extra/burning_ship.png" id="img34"></td>
      <td style="cursor: pointer; border: 2px solid blue"><img onclick="onc(this)" width="192" height="192" src="/extra/burning_ship.png" id="img35"></td>
    </tr>
    </table>
    
    </td></tr></table>
    
    </body>
    </html>
  };

} elsif ($func eq 'grid') {

  my $subhead = html::subhead($nom);

  print "Content-type: text/html\r\n\r\n";

  print qq{
    <html>
    <head>
    <title>peaple.io / $nom / grid</title>

    <meta property='og:title' content='$nom'>
    <meta property='og:description' content='$nom'>
    <meta property='og:image' content='https://peaple.io/$nom.png'>
    <meta property='og:image:type' content='image/png'>
    <meta property='og:image:width' content='512'>
    <meta property='og:image:height' content='512'>
    <meta property='og:url' content='https://peaple.io/$nom/grid'>
    <meta property='og:type' content='article'>
    <link rel='canonical' href='https://peaple.io/$nom/grid'>
    
    <script>
    
    function randstr() {
      return "" + Math.floor(Math.random() * 1000000000);
    }
    
    function reloadpic(i) {
      var pic = document.getElementById("pic" + i);
    
      var picnom;
      if (i == 12) {
        pic.src = "/$nom.png?dim=256&dev=0&rnd=" + randstr();
      } else {
        var x = i % 5;
        var y = Math.floor(i / 5);
        // gan14 is far more sensitive to the logit-space deviation than the old generator: 0.3 of the old scale
        // (neighbours of the centre ~0.17, edge-middles ~0.35, corners ~0.49); mem's default deviation is the edge-middle value
        var dev = 0.3 * Math.sqrt((x - 2) * (x - 2) +  (y - 2) * (y - 2)) / Math.sqrt(3.0);
        pic.src = "/$nom.png?dim=256&dev=" + dev + "&rnd=" + randstr();
      }
    }
    
    function onload() {
      for (var i = 0; i < 25; ++i) {
        reloadpic(i);
      }
    }
    
    </script>
    </head>
    
    <body bgcolor="#000000" text="#ffffff" link="#9999ff" vlink="#bb99ff" onload="onload()">

    $html::header
    $subhead
    
    <table width="1280">
    
    <tr height=8></tr>
    
    <tr><td>
    <table cellspacing=0 cellpadding=0 align="center">
    
    <tr>
      <td><img id="pic0" style="cursor: pointer" onClick="reloadpic(0)" width=256 height=256></a></td>
      <td><img id="pic1" style="cursor: pointer" onClick="reloadpic(1)" width=256 height=256></a></td>
      <td><img id="pic2" style="cursor: pointer" onClick="reloadpic(2)" width=256 height=256></a></td>
      <td><img id="pic3" style="cursor: pointer" onClick="reloadpic(3)" width=256 height=256></a></td>
      <td><img id="pic4" style="cursor: pointer" onClick="reloadpic(4)" width=256 height=256></a></td>
    </tr>
    <tr>
      <td><img id="pic5" style="cursor: pointer" onClick="reloadpic(5)" width=256 height=256></a></td>
      <td><img id="pic6" style="cursor: pointer" onClick="reloadpic(6)" width=256 height=256></a></td>
      <td><img id="pic7" style="cursor: pointer" onClick="reloadpic(7)" width=256 height=256></a></td>
      <td><img id="pic8" style="cursor: pointer" onClick="reloadpic(8)" width=256 height=256></a></td>
      <td><img id="pic9" style="cursor: pointer" onClick="reloadpic(9)" width=256 height=256></a></td>
    </tr>
    <tr>
      <td><img id="pic10" style="cursor: pointer" onClick="reloadpic(10)" width=256 height=256></a></td>
      <td><img id="pic11" style="cursor: pointer" onClick="reloadpic(11)" width=256 height=256></a></td>
      <!-- <td><img id="pic12" style="cursor: pointer" onClick="reloadpic(12)" width=256 height=256></a></td> -->
      <td><a href="/$nom/mem"><img id="pic12" width=256 height=256></a></td>
      <td><img id="pic13" style="cursor: pointer" onClick="reloadpic(13)" width=256 height=256></a></td>
      <td><img id="pic14" style="cursor: pointer" onClick="reloadpic(14)" width=256 height=256></a></td>
    </tr>
    <tr>
      <td><img id="pic15" style="cursor: pointer" onClick="reloadpic(15)" width=256 height=256></a></td>
      <td><img id="pic16" style="cursor: pointer" onClick="reloadpic(16)" width=256 height=256></a></td>
      <td><img id="pic17" style="cursor: pointer" onClick="reloadpic(17)" width=256 height=256></a></td>
      <td><img id="pic18" style="cursor: pointer" onClick="reloadpic(18)" width=256 height=256></a></td>
      <td><img id="pic19" style="cursor: pointer" onClick="reloadpic(19)" width=256 height=256></a></td>
    </tr>
    <tr>
      <td><img id="pic20" style="cursor: pointer" onClick="reloadpic(20)" width=256 height=256></a></td>
      <td><img id="pic21" style="cursor: pointer" onClick="reloadpic(21)" width=256 height=256></a></td>
      <td><img id="pic22" style="cursor: pointer" onClick="reloadpic(22)" width=256 height=256></a></td>
      <td><img id="pic23" style="cursor: pointer" onClick="reloadpic(23)" width=256 height=256></a></td>
      <td><img id="pic24" style="cursor: pointer" onClick="reloadpic(24)" width=256 height=256></a></td>
    </tr>
    
    </table>
    
    </td></tr></table>
    
    <br/>
    
    </body>
    </html>
  };

} else {

  print "Status: 404\r\n";
  print "Content-type: text/html\r\n\r\n";

  print qq{
    404
  };
}
