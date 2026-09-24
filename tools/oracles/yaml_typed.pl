# ORACLE for yamlvalue's `yaml-xs` profile (CART-1053): what YAML::XS (libyaml's Perl binding)
# loads. Perl is untyped: undef is null, a core boolean is a bool, everything else a STRING; a hash
# has no order, so keys are SORTED (the profile says so). NUL-separated paths on stdin; JSON out.
use strict; use warnings;
use YAML::XS ();
use JSON::PP ();
local $/;
my $in = <STDIN>;
sub canon {
    my ($v) = @_;
    return 'null' unless defined $v;
    return 'bool:' . ($v ? 'true' : 'false') if JSON::PP::is_bool($v);
    if (ref $v eq 'HASH') { return { '__o' => [ map { [ 'str:' . $_, canon($v->{$_}) ] } sort keys %$v ] } }
    if (ref $v eq 'ARRAY') { return { '__a' => [ map { canon($_) } @$v ] } }
    return 'unknown:' . ref($v) if ref $v;
    return 'str:' . $v;
}
my %out;
for my $p (split /\0/, $in) {
    next if $p eq '';
    my @docs = eval { YAML::XS::LoadFile($p) };
    if ($@) { my $m = "$@"; $m =~ s/\s+/ /g; $out{$p} = { error => substr($m, 0, 200) }; next }
    $out{$p} = { value => { '__a' => [ map { canon($_) } @docs ] } };
}
print JSON::PP->new->utf8->canonical(0)->encode(\%out);
