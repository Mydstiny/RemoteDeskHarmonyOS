package Locale::Maketext::Simple;
use strict; use warnings;
our $VERSION = '0.21';
my $Singleton;
sub import { my($class, %args) = @_; $Singleton = $class->new(%args); }
sub new { bless {}, $_[0] }
sub loc { return $_[1] || $_[0] }
sub get_handle { $Singleton }
1;
