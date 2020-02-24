package Test2::Harness::Util::UUID;
use strict;
use warnings;

our $VERSION = '0.999004';

use Data::UUID;
use Importer 'Importer' => 'import';

our @EXPORT = qw/gen_uuid/;

my $UG = Data::UUID->new;
sub gen_uuid() { $UG->create_str() }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Util::UUID - Utils for generating UUIDs.

=head1 DESCRIPTION

B<PLEASE NOTE:> Test2::Harness is still experimental, it can all change at any
time. Documentation and tests have not been written yet!

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
