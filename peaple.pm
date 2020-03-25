package peaple;

use visage;
use nomgen;

use IO::Socket::INET;
use Digest::SHA qw(sha256);
use Time::HiRes qw(time);
use POSIX qw(pow);

sub new {
  my ($p, $genhost, $enchost) = @_;
  $genhost //= "localhost:4444";
  $enchost //= "localhost:4445";

  open(my $log, "+<", "/var/www/html/perl/log.dat") or die;
  my $this = bless {
    genhost   => $genhost,
    gens      => undef,
    enchost   => $enchost,
    encs      => undef,
    log       => $log,
    ind       => { },
    off       => 0,
  }, $p;

  $this->slurp;
  $this->reconnectgen;
  $this->reconnectenc;

  $this->{dan} = $this->load_visage('synthetic_dan_brumleve');

  {
    my $oldfh = select($log);
    $| = 1;
    select($oldfh);
  }

  $this
}

sub slurp {
  my $this = shift;

  my $log = $this->{log};
  my $off = $this->{off};

  seek($log, $off << 14, 0);
  local $/ = \16384;

  my $t0 = time;

  while (defined(my $pkt = <$log>)) {
    length($pkt) == 16384 or die;
    my $padnom = substr($pkt, 0, 32);
    substr($padnom, 31, 1) eq "\0" or die;
    my $nom = $padnom;
    $nom =~ s/\0+$//s;

    $this->{ind}->{$nom} = $off;
    ++$off;
  }

  my $t1 = time;
  my $dt = $t1 - $t0;
  warn "slurp took $dt seconds";

  $this->{off} = $off;
}

my @goodnom;
{
  open(my $fp, "< /var/www/html/perl/goodnoms.txt") or die;
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

  my $log = $this->{log};
  my $off = $this->{ind}->{$nom};
  if (!defined($off)) {
    $this->slurp;
    $off = $this->{ind}->{$nom};

    if (!defined($off)) {
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
  }

  seek($log, $off << 14, 0);
  local $/ = \16384;
  my $pkt = <$log>;

  length($pkt) == 16384 or die;
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

  my $log = $this->{log};
  my $off = $this->{ind}->{$nom};
  if (!defined($off)) {
    $this->slurp;
    $off = $this->{ind}->{$nom};
    if (!defined($off)) {
      $off = $this->{off};
    }
  }

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

  seek($log, $off << 14, 0);
  print $log $pkt;

  $this->{ind}->{$nom} = $off;

  if ($off == $this->{off}) {
    ++$this->{off};
  }

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

  my $stop = {128 => -3, 256 => -2, 512 => -1, 1024 => 0}->{$dim};
  die "bad dim $dim" unless defined $stop;

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

sub vecgen {
  my ($this, $nom, $cvis, $which) = @_;

  if (defined($cvis)) {
    my $cnom = $cvis->{nom};
    my @pvec = $this->vecgen($nom);

    my @v;
    my $i = 0;
    my $sha = $nom . '<<<>>>';
    while (@v < 1536) {
      $sha = sha256($sha);
      for (unpack('C32', $sha)) {
        $v[$i] = (($which + $_) % 2 ? $cvis->{vec}->[$i] : $pvec[$i]);
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

1
