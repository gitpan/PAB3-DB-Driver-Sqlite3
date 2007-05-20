use 5.008;
use ExtUtils::MakeMaker;
use Config;

$Verbose = 0;

%os_supported = ( 'linux' => 1, 'darwin' => 1 );

our $TERM_RED			= "\033[31;1m";
our $TERM_GREEN			= "\033[32;1m";
our $TERM_YELLOW		= "\033[33;1m";
our $TERM_BLUE			= "\033[34;1m";
our $TERM_MAGENTA		= "\033[35;1m";
our $TERM_CYAN			= "\033[36;1m";
our $TERM_WHITE			= "\033[37;1m";
our $TERM_RESET			= "\033[m";

my $_useit = ! $PAB || ( $PAB && $PAB_OPT{'with_sqlite3'} );

@_INC = qw(sqlite3.h);
%_LIBREQ = %_LIBS = ( 'sqlite3' => 1 );
@_LIB_PATH = qw(/usr/local/lib64 /usr/local/lib /usr/lib64 /usr/lib);
@_INC_PATH = qw();

@_EXT = ( '.so', '.a', '.dll', '.dylib' );

if( ! $os_supported{$^O} ) {
	if( $PAB && $PAB_OPT{'with_mysql'} eq '_auto_' ) {
		$_useit = 0;
	}
	elsif( $_useit ) {
		print <<EOF1;
************* WARNING *************
* Your operation system is not    *
* supported.                      *
* The installation may fail!      *
***********************************
EOF1
	}
}

%_MAKEOPTS = (
    NAME => 'PAB3::DB::Driver::Sqlite3',
    VERSION_FROM => 'Sqlite3.pm',
    ABSTRACT => 'Perl wrapper to Sqlite3',
    XSPROTOARG => '-prototypes',
    PREREQ_PM => {},
    OBJECT => '$(O_FILES)',
    XS => { 'Sqlite3.xs' => 'Sqlite3.c' },
    C => [ 'my_sqlite3.c', 'Sqlite3.c' ],
    DEFINE => '',
    PL_FILES => { 'install_files.PL' => $PAB ? 'pab' : 'self' },
);

if( ! $_useit ) {
	&donotuse();
	WriteMakefile( %_MAKEOPTS );
	$PAB ? return 1 : exit 0;
}

if( $PAB_OPT{'with_sqlite3'} ) {
	if( -d $PAB_OPT{'with_sqlite3'} ) {
		@_INC_PATH = ( $PAB_OPT{'with_sqlite3'} . '/include' );
		unshift @_LIB_PATH, $PAB_OPT{'with_sqlite3'} . '/lib';
		$ld = $ic = 1;
	}
}

if( $Config{'usethreads'} ) {
	$_MAKEOPTS{'DEFINE'} .= ' -DUSE_THREADS';
}
if( $PAB_OPT{'sqlite3_enable_metadata'} ) {
	$_MAKEOPTS{'DEFINE'} .= ' -DSQLITE_ENABLE_COLUMN_METADATA';
}
if( $^O eq 'darwin' ) {
	$_MAKEOPTS{'DEFINE'} .= ' -fnested-functions';
}

if( $^O ne 'linux' ) {
	$TERM_RED = $TERM_GREEN = $TERM_YELLOW = $TERM_BLUE = $TERM_MAGENTA =
		$TERM_CYAN = $TERM_WHITE = $TERM_RESET = '';
}

@argv = ();
foreach( @ARGV ) {
	if( /--help/ ) {
		print_usage();
	}
	elsif( /--libdir=(.+)/ ) {
		@_LIB_PATH = ( $lb = $1 );
	}
	elsif( /--incdir=(.+)/ ) {
		@_INC_PATH = ( $ic = $1 );
	}
	else {
		push @argv, $_;
	}
}
@ARGV = @argv;

$out = select( STDOUT );
$| = 1;
select( $out );

print $TERM_BLUE, "Preparing ", $TERM_YELLOW, $_MAKEOPTS{'NAME'}, $TERM_RESET, "\n";
foreach $lib( keys %_LIBS ) {
	print $TERM_WHITE, "Looking for ", $TERM_GREEN, "lib$lib", $TERM_RESET, " ...";
	$found = 0;
	foreach $path( @_LIB_PATH ) {

		foreach $ext( @_EXT ) {
			my $file = $path . '/lib' . $lib . $ext;
			if( -f $file ) {
				print $TERM_WHITE, "\n  found at ", $TERM_MAGENTA, $file, $TERM_RESET;
				$found = 1;
				if( $_LIBS{$lib} eq 'inst' ) {
					&file_copy( $file, 'lib' . $lib . $ext );
				}
			}
		}
	}
	if( ! $found ) {
		print $TERM_RED, " not found", $TERM_RESET;
		delete $_LIBS{$lib};
	}
	print "\n";
}

if( $^O eq 'MSWin32' ) {
	$_MAKEOPTS{'LIBS'} = [
		join( ' ', map{ '"-L' . $_ . '"' } @_LIB_PATH ) . ' '
		. join( ' ', map{ '-l' . $_ } keys %_LIBS )
		. ' ' . join( ' ', @_OBJECT )
	];
	$_MAKEOPTS{'INC'} = join( ' ', map{ '"-I' . $_ . '"' } @_INC_PATH );
}
else {
	$_MAKEOPTS{'LIBS'} = [
		join( ' ', map{ '-L' . $_ } @_LIB_PATH ) . ' '
		. join( ' ', map{ '-l' . $_ } keys %_LIBS )
		. ' ' . join( ' ', @_OBJECT )
	];
	$_MAKEOPTS{'INC'} = join( ' ', map{ '-I' . $_ } @_INC_PATH );
}

$found = 1;
foreach( keys %_LIBREQ ) {
	if( ! $_LIBS{$_} ) {
		$found = 0;
		last;
	}
}
if( ! $found ) {
	if( $PAB && $PAB_OPT{'with_sqlite3'} eq '_auto_' ) {
		&donotuse();
		WriteMakefile( %_MAKEOPTS );
		$PAB ? return 1 : exit 0;
	}
	else {
		print <<EOF1;
************* WARNING *************
* Some required libraries has not *
* been found.                     *
* The installation may fail!      *
***********************************
EOF1
	}
}

rename '_t', 't' if -d '_t';
WriteMakefile( %_MAKEOPTS );

1;

sub print_usage {
	print <<EOTH;
Usage: perl $0 [options]
Options:
    --help            print this message
    --libdir=DIR      Use DIR for running the linker; defaults to a guessed value
    --incdir=DIR      Use DIR for running the comiler; defaults to a guessed value
EOTH
	exit( 256 );
}

sub donotuse {
	$_MAKEOPTS{'XS'} = {};
	$_MAKEOPTS{'C'} = [];
	$_MAKEOPTS{'OBJECT'} = '';
	$_MAKEOPTS{'PM'} = {};
    $_MAKEOPTS{'PL_FILES'} => {};
	rename 't', '_t' if -d 't';
}

sub file_copy {
	my( $src, $dst ) = @_;
	my( $sfh, $dfh, $buf );
	return if ! -f $src;
	open( $sfh, '<', $src ) or warn "Can not open $src: $!";
	binmode( $sfh );
	open( $dfh, '>', $dst ) or warn "Can not open $dst: $!";
	binmode( $dfh );
	while( read( $sfh, $buf, 8192 ) ) {
		print $dfh $buf;
	}
	close( $dfh );
	close( $sfh );
}
