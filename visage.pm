package visage;
use nomgen;

use Digest::SHA qw(sha256);
use JSON;

my $json = new JSON;
$json->indent(1);
$json->space_after(1);
$json->canonical(1);

sub new {
  my $p = shift;

  my %arg = @_;
  $arg{nom} //= $p->nomgen;
  $arg{vec} //= [ ];
  $arg{frens} //= [ ];
  $arg{parens} //= [ ];
  $arg{kids} //= [ ];

  bless \%arg, $p
}

sub _pick {
  $_[int rand int @_]
}

sub nomgen {
  my $p = shift;

again:
  my ($r0, $r1, $r2, $r3) = map int(rand(65536)), 1 .. 4;

  my $pp = $nomgen::ppnom[$r0 % @nomgen::ppnom];
  my $sp = $nomgen::spnom[$r1 % @nomgen::spnom];
  my $ps = $nomgen::psnom[$r2 % @nomgen::psnom];
  my $ss = $nomgen::ssnom[$r3 % @nomgen::ssnom];

  my $nom = $pp . $sp . "_" . $ps . $ss;

  if (length($nom) > 31) {
    goto again;
  }

  return $nom;
}

sub pnomgen {
  my ($vis, $which) = @_;

  if ($vis->{nom} eq 'synthetic_dan_brumleve') {
    return 'synthetic_dan_brumleve';
  }

  my $cnom = $vis->{nom} or die;
  die unless $which eq '0' || $which eq '1';

  my ($r0, $r1, $r2, $r3) = unpack('N4', sha256($cnom . '*' . $which));

  my $pp = $nomgen::ppnom[$r0 % @nomgen::ppnom];
  my $sp = $nomgen::spnom[$r1 % @nomgen::spnom];

  my $s;
  if ($which) {
    my $ps = $nomgen::psnom[$r2 % @nomgen::psnom];
    my $ss = $nomgen::ssnom[$r3 % @nomgen::ssnom];
    $s = $ps . $ss;
  } else {
    $s = $cnom;
    $s =~ s/.*_//;
  }

  my $nom = $pp . $sp . "_" . $s;

  if (length($nom) > 31) {
    $nom = substr($nom, 0, 31);
  }

  return $nom;
}

sub frens {
  my $self = shift;
  @{$self->{frens}}
}

sub paren {
  my ($self, $which) = @_;
  $self->{parens}->[$which]
}

sub parens {
  my $self = shift;
  @{$self->{parens}}
}

sub kids {
  my $self = shift;
  @{$self->{kids}}
}

sub json {
  my $self = shift;

  my $export = +{
    nom    => $self->{nom},
    frens  => $self->{frens},
    gen    => $self->{gen},
    parens => $self->{parens},
    kids   => $self->{kids},
#    vec    => $self->{vec},
  };

  $json->encode($export)
}

sub hasfren {
  my ($self, $fren) = @_;
  for (@{$self->{frens}}) {
    if ($_ eq $fren) {
      return 1;
    }
  }
  return 0;
}

sub haskid {
  my ($self, $kid) = @_;
  for (@{$self->{kids}}) {
    if ($_ eq $kid) {
      return 1;
    }
  }
  return 0;
}

sub hasparen {
  my ($self, $paren) = @_;
  return 1 if $self->{parens}->[0] eq $paren;
  return 1 if $self->{parens}->[1] eq $paren;
  0
}

sub addfren {
  my ($self, @fren) = @_;
  for my $fren (@fren) {
    next if $self->hasfren($fren);
    unshift(@{$self->{frens}}, $fren);
    splice(@{$self->{frens}}, 16);
  }
  @{$self->{frens}}
}

1
