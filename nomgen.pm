package nomgen;

sub _slurplist {
  my $fn = shift;
  open(my $fp, "< $fn") or die "$fn: $!";
  my @x;
  while (<$fp>) {
    chomp;
    push @x, $_;
  }
  @x
}

BEGIN {
  my $root = $ENV{PEAPLE_ROOT} // "/var/www/html/perl";
  our @ppnom = _slurplist("$root/ppnoms.txt");
  our @psnom = _slurplist("$root/psnoms.txt");
  our @spnom = _slurplist("$root/spnoms.txt");
  our @ssnom = _slurplist("$root/ssnoms.txt");
}

1
