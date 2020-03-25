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
  our @ppnom = _slurplist("/var/www/html/perl/ppnoms.txt");
  our @psnom = _slurplist("/var/www/html/perl/psnoms.txt");
  our @spnom = _slurplist("/var/www/html/perl/spnoms.txt");
  our @ssnom = _slurplist("/var/www/html/perl/ssnoms.txt");
}

1
