package math;

sub matmul3 {
  my ($a, $b) = @_;

  my $c = [[0,0,0],[0,0,0],[0,0,0]];

  for my $arow (0 .. 2) {
    for my $bcol (0 .. 2) {
      for my $q (0 .. 2) {
        $c->[$arow]->[$bcol] += $a->[$arow]->[$q] * $b->[$q]->[$bcol];
      }
    }
  }
  $c
}

sub getaff {
  my ($px1, $py1, $qx1, $qy1, $rx1, $ry1) = @_;
  my ($px2, $py2, $qx2, $qy2, $rx2, $ry2) = (48, 64, 80, 64, 64, 96);
  
  my $b = [
    [$px2, $qx2, $rx2],
    [$py2, $qy2, $ry2],
    [1, 1, 1]
  ];
  
  my $inva = [
    [($qy1-$ry1),    -($qx1-$rx1),    ($qx1*$ry1-$rx1*$qy1)],
    [-(-$ry1+$py1),  (-$rx1+$px1),    -($px1*$ry1-$py1*$rx1)],
    [(-$qy1+$py1),   -(-$qx1+$px1),   ($px1*$qy1-$py1*$qx1)],
  ];
  
  my $det = $qx1*$ry1-$rx1*$qy1-$py1*$qx1+$py1*$rx1+$px1*$qy1-$px1*$ry1;
  my $idet = 1.0 / $det;
  
  for (@$inva) {
    for (@$_) {
      $_ *= $idet;
    }
  }
  
  my $c = matmul3($b, $inva);
  my @aff = ($c->[0]->[0], $c->[1]->[0], $c->[0]->[1], $c->[1]->[1], $c->[0]->[2], $c->[1]->[2]);
  @aff
}

1
