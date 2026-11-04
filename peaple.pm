package peaple;

use visage;
use nomgen;

use IO::Socket::INET;
use Digest::SHA qw(sha256_hex);
use Digest::SHA qw(sha256);
use Time::HiRes qw(time);
use POSIX qw(pow);

sub new {
  my ($p, $genhost, $enchost) = @_;
  $genhost //= $ENV{PEAPLE_GENHOST} // "localhost:4444";
  $enchost //= $ENV{PEAPLE_ENCHOST} // "localhost:4445";

  my $root = $ENV{PEAPLE_ROOT} // "/var/www/html/perl";
  # visage store: one 16 KB record per nom in $root/visages/<2 hex of sha256(nom)>/<nom>.vis, touched on every
  # load so devserver.py's hourly sweep can drop the least recently used beyond PEAPLE_VISAGE_CAP.  Replaced the
  # append-only log.dat that every CGI request re-indexed (3 s per request at 425k records) and that grew forever.
  my $vdir = "$root/visages";
  -d $vdir or mkdir($vdir) or die "$vdir: $!";
  my $this = bless {
    genhost   => $genhost,
    gens      => undef,
    enchost   => $enchost,
    encs      => undef,
    vdir      => $vdir,
  }, $p;

  $this->reconnectgen;
  $this->reconnectenc;

  $this->{dan} = $this->load_visage('synthetic_dan_brumleve');

  $this
}

sub _vpath {
  my ($this, $nom) = @_;
  my $d = $this->{vdir} . '/' . substr(sha256_hex($nom), 0, 2);
  -d $d or mkdir($d);
  "$d/$nom.vis"
}

sub slurp {
  # the visage store is a directory now; nothing to index
  1
}

my @goodnom;
{
  my $root = $ENV{PEAPLE_ROOT} // "/var/www/html/perl";
  open(my $fp, "< $root/goodnoms.txt") or die;
  while (<$fp>) {
    chomp;
    push @goodnom, $_;
  }
}

sub pick {
  my $this = shift;

#  $this->{off} > 0 or die;
#  my $off = int rand($this->{off});
#  my $log = $this->{log} or die "huh";
#
#  seek($log, $off << 14, 0);
#  local $/ = \32;
#  my $nom = <$log>;
#  $nom =~ s/\0+$//;
#  length($nom) > 0 or die "huh";

#  $nom

  $goodnom[int rand int @goodnom]
}

sub load_visage {
  my ($this, $nom, $kid, $which) = @_;

  my $fn = $this->_vpath($nom);
  my $pkt;
  if (open(my $fp, '<', $fn)) {
    binmode $fp;
    local $/ = \16384;
    $pkt = <$fp>;
    close($fp);
    utime(undef, undef, $fn);   # LRU touch
  }

  if (!defined($pkt) || length($pkt) != 16384) {
  my @vec = $this->vecgen($nom, $kid, $which);
  
  my $vis = new visage
    nom	=> $nom,
    vec	=> \@vec,
    gen	=> defined($kid) ? 1 + $kid->{gen} : 0,
    kids	=> defined($kid) ? [$kid->{nom}] : [ ],
    frens	=> ['synthetic_dan_brumleve'],
    ;

  my $p0 = $vis->pnomgen(0);
  my $p1 = $vis->pnomgen(1);
  $vis->{parens} = [$p0, $p1];

  if (defined($kid)) {
    $this->save_visage($vis);
  }

  return $vis;
  }

  my $padnom = substr($pkt, 0, 32);
  substr($padnom, 31, 1) eq "\0" or die;
  my $vnom = $padnom;
  $vnom =~ s/\0+$//s;
  return undef unless $vnom eq $nom;
  my $poff = 32;

  my @vec = unpack('d*', substr($pkt, $poff, 12288));
  $poff += 12288;
  
  my $gen = unpack('i', substr($pkt, $poff, 4));
  $poff += 4;

  my $frenspkt = substr($pkt, $poff, 512);
  $poff += 512;

  my @fren;
  for (my $i = 0; $i < 16; ++$i) {
    my $f = substr($frenspkt, $i * 32, 32);
    $f =~ s/\0+$//;
    next if length($f) == 0;
    push @fren, $f;
  }

  my $parenspkt = substr($pkt, $poff, 64);
  $poff += 64;

  my @paren;
  for (my $i = 0; $i < 2; ++$i) {
    my $f = substr($parenspkt, $i * 32, 32);
    $f =~ s/\0+$//;
    next if length($f) == 0;
    push @paren, $f;
  }

  my $kidspkt = substr($pkt, $poff, 256);
  $poff += 256;

  my @kid;
  for (my $i = 0; $i < 8; ++$i) {
    my $f = substr($kidspkt, $i * 32, 32);
    $f =~ s/\0+$//;
    next if length($f) == 0;
    push @kid, $f;
  }

  my $vis = new visage
    nom   => $nom,
    vec   => \@vec,
    gen   => $gen,
    frens => \@fren,
    kids => \@kid,
    ;

  if (@paren == 0) {
    my $p0 = $vis->pnomgen(0);
    my $p1 = $vis->pnomgen(1);
    $vis->{parens} = [$p0, $p1];
  } elsif (@paren == 1) {
    $vis->{parens} = [$paren[0], $paren[0]];
  } elsif (@paren == 2) {
    $vis->{parens} = \@paren;
  }

  $vis
}


sub save_visage {
  my ($this, $vis) = @_;

  my $nom = $vis->{nom};
  length($nom) > 0 or die "no nom";
  my $vec = pack('d*', @{$vis->{vec}});

  length($nom) < 32 or die;
  my $padnom = $nom . ("\0" x (32 - length($nom)));
  my $pkt = $padnom;
  my $poff = 32;

  my $vecn = 12288;
  length($vec) == $vecn or die;
  $pkt .= $vec;
  $poff += $vecn;

  $pkt .= pack('i', $vis->{gen});
  $poff += 4;

  my $fpkt = join('',
    map pack('C32', unpack('C*', $vis->{frens}->[$_ - 1])),
    1 .. 16
  );
  length($fpkt) == 512 or die;
  $pkt .= $fpkt;
  $poff += length($fpkt);

  $fpkt = join('',
    map pack('C32', unpack('C*', $vis->{parens}->[$_ - 1])),
    1 .. 2
  );
  length($fpkt) == 64 or die;
  $pkt .= $fpkt;
  $poff += length($fpkt);

  $fpkt = join('',
    map pack('C32', unpack('C*', $vis->{kids}->[$_ - 1])),
    1 .. 8
  );
  length($fpkt) == 256 or die;
  $pkt .= $fpkt;
  $poff += length($fpkt);

  $poff <= 16384 or die;
  $pkt .= ("\0" x (16384 - $poff));

  # write whole, then rename: readers never see a partial record and concurrent CGIs cannot interleave
  my $fn = $this->_vpath($nom);
  my $tmp = "$fn.$$.tmp";
  open(my $fp, '>', $tmp) or die "$tmp: $!";
  binmode $fp;
  print $fp $pkt;
  close($fp) or die "$tmp: $!";
  rename($tmp, $fn) or die "rename $tmp: $!";

  1
}

sub reconnectenc {
  my $this = shift;
  undef $this->{encs};
  my $host = $this->{enchost};
again:
  eval {
    $this->{encs} = new IO::Socket::INET $host;
  };

  if ($@) {
    warn "got enc connect error $@, sleep(1) and try again";
    sleep(1);
    undef $this->{encs};
    goto again;
  }
}

sub reconnectgen {
  my $this = shift;
  undef $this->{gens};
  my $host = $this->{genhost};
again:
  eval {
    $this->{gens} = new IO::Socket::INET $host;
  };

  if ($@) {
    warn "got gen connect error $@, sleep(1) and try again";
    sleep(1);
    undef $this->{gens};
    goto again;
  }
}

sub _vecmul {
  my ($vec, $mul) = @_;

  my $x0 = 0.5 / 65536.0;
  my $x1 = 1.0 - $x0;

  for (my $i = 0; $i < @$vec; ++$i) {
    my $x = $vec->[$i];

    $x -= 0.5;
    $x *= $mul;
    $x += 0.5;

    if ($x > $x1) {
      $x = $x1;
    } elsif ($x < $x0) {
      $x = $x0;
    }

    $vec->[$i] = $x;
  }

  $vec
}

sub _vecdev {
  my ($vec, $dev, $rnd) = @_;

  $rnd ||= rand(1);

  my $x0 = 0.5 / 65536.0;
  my $x1 = 1.0 - $x0;
  my $f = 4.0;

  my $sha = $rnd;
  my @sha;
  for (1 .. 48) {
    $sha = sha256($sha);
    push @sha, $sha;
  }
  $sha = join '', @sha;
  length($sha) == 1536 or die;

  for (my $i = 0; $i < @$vec; ++$i) {
    my $x = $vec->[$i];

    if ($x > $x1) {
      $x = $x1;
    } elsif ($x < $x0) {
      $x = $x0;
    }

    my $r = ord(substr($sha, $i, 1)) / 128.0 - 1.0;

    my $lx = log($x) - log(1 - $x);
    $lx += $f * $dev * $r;
    $x = 1 / (1 + exp(-$lx));

    if ($x > $x1) {
      $x = $x1;
    } elsif ($x < $x0) {
      $x = $x0;
    }

    $vec->[$i] = $x;
  }

  $vec
}

sub getvec {
  my ($this, $rgb) = @_;

  length($rgb) == 128 * 128 * 3 or die "bad rgblen";
  my $inp = pack('d*', map { ($_ + 0.5) / 256.0 } unpack 'C*', $rgb);

  my $hdr = ("\0" x 256);
  my $pkt = $hdr . $inp;

again:
  my $pvec = eval {
    my $s = $this->{encs};
    die "no server" unless $s;
    print $s $pkt;

    local $/ = \12288;
    scalar <$s>;
  };

  if ($@) {
    warn "got error $@";
    warn "reconnecting after sleep(1)";
    sleep(1);
    $this->reconnectenc;
    goto again;
  }
  
  [unpack 'd*', $pvec]
}

sub getpng {
  my ($this, $vis, $dim, $mul, $dev, $rnd) = @_;
  $mul //= 1;
  $dim //= 512;
  $dev //= 0;

  # each generator stage past the first doubles resolution; PEAPLE_MAXDIM is
  # the output size of the full served chain (1024 for the original 4-stage one)
  my $maxdim = $ENV{PEAPLE_MAXDIM} // 1024;
  my $stop = {128 => 0, 256 => 1, 512 => 2, 1024 => 3}->{$dim};
  die "bad dim $dim" unless defined $stop;
  $stop -= {128 => 0, 256 => 1, 512 => 2, 1024 => 3}->{$maxdim};
  $stop = 0 if $stop > 0;

  my @vec = @{$vis->{vec}};
  if ($mul != 1) {
    _vecmul(\@vec, $mul);
  }
  if ($dev > 0) {
    _vecdev(\@vec, $dev, $rnd);
  }
  my $vec = pack('d*', @vec);
  length($vec) == 12288 or die "bad veclen";

  my $hdr = pack('i', $stop) . ("\0" x 252);
  my $pkt = $hdr . $vec;

again:
  my $png = eval {
    my $s = $this->{gens};
    die "no server" unless $s;
    print $s $pkt;
    my @png;
    {
      local $/ = \8;
      my $pnghdr = <$s>;
      defined $pnghdr or die "no hdr";
      die "bad hdr" unless $pnghdr eq pack('C*', qw(137 80 78 71 13 10 26 10));
  
      push @png, $pnghdr;
  
      while (1) {
        local $/ = \4;
        my $len = <$s>;
        die "no len" unless defined($len);
        push @png, $len;
        $len = unpack('N', $len);
        my $type = <$s>;
        die "no type" unless defined $type;
        push @png, $type;
  
        local $/ = \($len + 4);
        push @png, scalar <$s>;
  
        last if $type eq 'IEND';
      }
    }
  
    join '', @png
  };

  if ($@) {
    warn "got error $@";
    warn "reconnecting after sleep(1)";
    sleep(1);
    $this->reconnectgen;
    goto again;
  }
  
  $png;
}

# noms whose vector is fixed rather than hashed from the name: $root/special/<nom>.vec, 1536 little-endian doubles
# (paxter.vec = the hash vector of "fordcountychronicle", so the chat librarian wears that face under its own name)
my %special;
{
  my $root = $ENV{PEAPLE_ROOT} // "/var/www/html/perl";
  for my $fn (glob("$root/special/*.vec")) {
    my ($nom) = $fn =~ m{/([a-z0-9_]+)\.vec$} or next;
    open(my $fp, '<', $fn) or next;
    binmode $fp;
    local $/;
    my $raw = <$fp>;
    close($fp);
    $special{$nom} = [unpack('d*', $raw)] if length($raw) == 12288;
  }
}

sub vecgen {
  my ($this, $nom, $cvis, $which) = @_;

  if (!defined($cvis) && $special{$nom}) {
    return @{$special{$nom}};
  }

  if (defined($cvis)) {
    my $cnom = $cvis->{nom};
    my @pvec = $this->vecgen($nom);

    my @v;
    my $i = 0;
    my $sha = $nom . '<<<>>>';
    while (@v < 1536) {
      $sha = sha256($sha);
      for (unpack('C32', $sha)) {
        # a parent copies this fraction of the kid's coordinates (the rest come from its own nom).  Was 1/2 for the
        # old generator, which used the latent nearly linearly; gan14's mapping net turns a half-shared z into a
        # w-cosine of ~0.4 (strangers), 3/4 gives ~0.6 (loosely related), 7/8 ~0.8 (clones).  $which rotates the mask.
        $v[$i] = ((($_ + 64 * ($which // 0)) % 256) < 192 ? $cvis->{vec}->[$i] : $pvec[$i]);
        ++$i;
      }
    }
    @v == 1536 or die "huh";

    if (0)  {
      my $dan = $this->{dan} or die;
      my $danvec = $dan->{vec};
      my $gen = 1 + $cvis->{gen};
      my $w0 = pow(1-1/64, $gen);
      my $w1 = 1.0 - $w0;
      for (my $i = 0; $i < @v; ++$i) {
        $v[$i] = $danvec->[$i] * $w1 + $v[$i] * $w0;
      }
    }

    return @v;
  } else {
    my @v;
    my $sha = $nom;
    while (@v < 1536) {
      $sha = sha256($sha);
      push @v, map { ($_ + 0.5) / (1 << 32) } unpack('N*', $sha);
    }
    @v == 1536 or die "huh";

    return @v;
  }
}


# --- autoposer: default marker positions for a fresh upload, from the poser server (ffhq.proj/poser.ctx, port 4447) ---
# the net regresses the three markers of a 128x128 frame; like the old makemore Autoposer it runs twice: once on the
# letterboxed upload, then on the upload warped to the canonical crop by the first guess (small residual, best accuracy)

sub getpose {
  my ($this, $rgb) = @_;
  length($rgb) == 128 * 128 * 3 or return undef;
  my $host = $ENV{PEAPLE_POSEHOST} // "localhost:4447";
  my $out = eval {
    my $s = IO::Socket::INET->new(PeerAddr => $host, Timeout => 2) or die "no poser server";
    my $inp = pack('d*', map { ($_ + 0.5) / 256.0 } unpack 'C*', $rgb);
    print $s (("\0" x 256) . $inp);
    local $/ = \48;
    my $r = <$s>;
    defined($r) && length($r) == 48 or die "short poser reply";
    $r
  };
  if ($@) { warn "poser: $@"; return undef }
  [map { $_ * 128.0 } unpack 'd6', $out]
}

# rgb bytes of a png warped by a forward affine (convert AffineProjection order: sx,rx,ry,sy,tx,ty) into 128x128
sub _warp128 {
  my ($fn, @aff) = @_;
  my $aff = join(',', @aff);
  open(my $fp, "convert $fn -virtual-pixel mirror -define distort:viewport=128x128+0+0 -distort AffineProjection '$aff' +repage +set comment ppm:- |") or return undef;
  my $rgb;
  {
    local $/ = "\n";
    my $l = <$fp>; $l eq "P6\n" or return undef;
    $l = <$fp>; $l eq "128 128\n" or return undef;
    $l = <$fp>; $l eq "255\n" or return undef;
    undef local $/;
    $rgb = <$fp>;
  }
  close($fp);
  $rgb
}

# apply the inverse of a forward affine (sx,rx,ry,sy,tx,ty) to a point: dest -> source
sub _aff_unmap {
  my ($x, $y, $sx, $rx, $ry, $sy, $tx, $ty) = @_;
  my $det = $sx * $sy - $rx * $ry;
  return undef if abs($det) < 1e-12;
  $x -= $tx; $y -= $ty;
  (($sy * $x - $ry * $y) / $det, (-$rx * $x + $sx * $y) / $det)
}

sub autopose {
  my ($this, $fn) = @_;
  my ($w, $h) = split ' ', `identify -format '%w %h' $fn 2>/dev/null`;
  $w && $h or return undef;

  # pass 1: letterbox into 128x128
  my $f = 128.0 / ($w > $h ? $w : $h);
  my @aff1 = ($f, 0, 0, $f, (128 - $f * $w) / 2, (128 - $f * $h) / 2);
  my $rgb = _warp128($fn, @aff1) or return undef;
  my $m = $this->getpose($rgb) or return undef;
  my @p1;
  for my $i (0, 2, 4) {
    my ($x, $y) = _aff_unmap($m->[$i], $m->[$i + 1], @aff1);
    push @p1, $x, $y;
  }

  # pass 2: warp by the first guess into the canonical crop, predict the residual, map back
  my @aff2 = math::getaff(@p1);
  my @p2;
  if ($rgb = _warp128($fn, @aff2) and $m = $this->getpose($rgb)) {
    for my $i (0, 2, 4) {
      my ($x, $y) = _aff_unmap($m->[$i], $m->[$i + 1], @aff2);
      push @p2, $x, $y;
    }
    my $guard = $w / 16.0;
    for my $i (0 .. 5) {
      if (abs($p2[$i] - $p1[$i]) > $guard) { @p2 = (); last }
    }
  }
  my @p = @p2 ? @p2 : @p1;
  for my $i (0 .. 5) {
    my $lim = ($i % 2 ? $h : $w) - 1;
    $p[$i] = 0 if $p[$i] < 0;
    $p[$i] = $lim if $p[$i] > $lim;
    $p[$i] = int($p[$i] + 0.5);
  }
  @p
}

1
