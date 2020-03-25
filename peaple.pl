#!/usr/bin/perl

BEGIN {
  our $rootdir = "/var/www/html/perl";
}

use lib $rootdir;
use peaple;
use html;
use math;

our $peaple;
BEGIN {
  our $peaple = new peaple;
}

use CGI;
use JSON;

my $cgi = new CGI;
my $json = new JSON;

my $path = $ENV{PATH_INFO};
$path =~ s#^/+##;

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
  my $dev = $cgi->param('dev') // 0.0;
  my $rnd = $cgi->param('rnd');

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

  if (!$vis->hasparen($fnom)) {
    my $vp = $vis->{parens};
    unshift @$vp, $fnom;
    splice @$vp, 2;
  }

  # if (!$fvis->haskid($nom)) {
  #   my $fvk = $fvis->{kids};
  #   unshift @$fvk, $nom;
  #   splice @$fvk, 8;
  #
  #   $peaple->save_visage($fvis);
  # }

  $peaple->save_visage($vis);

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

    open(my $rgbfp, "convert $rootdir/uploads/$nom.png -affine '$aff' -transform -crop 128x128+0+0 -extent 128x128 +repage +set comment ppm:- |") or die;
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

  my $subhead = html::subhead($nom);

  print "Content-Type: text/html\r\n\r\n";
  print qq<
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

      <body bgcolor="#ffffff">
        $html::header
        $subhead

        <table width="1280"><tr><td align="center">
          <a href="/$nom/fam"><img id="pic" src="/$nom.png?dim=512" width="512" height="512"/></a>
        </td></tr></table>
      </body>
    </html>
  >;

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
      <body bgcolor="#ffffff">
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
  
    <body bgcolor="#ffffff" onload="onl()">

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
          post("/$nom/bread.json", "fren=" + escape(fren), function(x) {
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
  
    <body bgcolor="#ffffff" onload="onl()">

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
                <img class="button" src="https://fontasy.io/$html::phont.png?txt=addfren&chop=0&dim=8" align="bottom" onClick="addfren(frenbuf.value)">
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
                  <img id="gotobutton" style="outline: 3px solid #00ff00" src="https://fontasy.io/$html::phont.png?txt=goto&chop=0&dim=8" onclick="clicktool('goto')">
                </td></tr>
                <tr><td align=right height="36">
                  <img id="breadbutton" class="button" src="https://fontasy.io/$html::phont.png?txt=bread&chop=0&dim=8" onclick="clicktool('bread')">
                </td></tr>
              </table>
            </td></tr>
            <tr><td height="16"></td></tr>
          </table>
        </td>
      </tr>
    </table>
    
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
      var mul = 0.5;

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

    <body bgcolor="#ffffff" onload="onl()">
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
              <img class="button" src="https://fontasy.io/$html::phont.png?txt=addpal&chop=0&dim=8" align="bottom" onClick="addpal(palbuf.value)">
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
    
    <body bgcolor="#ffffff">
    
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
      <img src="https://fontasy.io/$html::phont.png?txt=capture&chop=0&dim=8" width='112' height='24' align="bottom" onClick="startvid()" id="capbutton"/>
    </td>
    <td>
    <label id=uplab for="fileupload" style="outline: 3px solid blue; display: inline-block; cursor: pointer">
      <img src="https://fontasy.io/$html::phont.png?txt=upload&chop=0&dim=8" width='96' height='24' align="bottom" id="uploadbutton"/>
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
    <td><img src="https://fontasy.io/mork.png?txt=p&chop=1&dim=8&fg=ffffff&bg=000000" align="bottom" style="outline: 3px solid blue" onClick="clickp()" id="pbutton"/></td>
    <td><img src="https://fontasy.io/mork.png?txt=q&chop=1&dim=8&fg=ffffff&bg=000000" align="bottom" style="outline: 3px solid blue" onClick="clickq()" id="qbutton"/></td>
    <td><img src="https://fontasy.io/mork.png?txt=r&chop=1&dim=8&fg=ffffff&bg=000000" align="bottom" style="outline: 3px solid blue" onClick="clickr()" id="rbutton"/></td>
    <td><img src="https://fontasy.io/$html::phont.png?txt=auto&chop=0&dim=8" align="bottom" style="outline: 3px solid blue" onClick="clickauto()" id="autobutton"/></td>
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
    
    <body bgcolor="#ffffff" onload="onl()">
    $html::header
    $subhead   

    <table width=1280 cellpadding=0 cellspacing=0>
    
    
    <tr><td align="center">
    <table><tr><td>
        <script>
          window.mul = 0.35;
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
        var dev = Math.sqrt((x - 2) * (x - 2) +  (y - 2) * (y - 2)) / Math.sqrt(3.0);
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
    
    <body bgcolor="#ffffff" onload="onload()">

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
