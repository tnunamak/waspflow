#!/usr/bin/env perl
# Stream ECMA-48 terminal output as readable text. Complete sequences are
# removed in bulk; an incomplete trailing sequence is retained across reads.
# The 8 KB cap bounds an unterminated control string, after which its payload
# is released as ordinary text rather than withholding unbounded output.
use strict;
use warnings;
use IO::Handle;

STDOUT->autoflush(1);

my $chunk_size = $ENV{WASPFLOW_STRIP_ANSI_CHUNK_SIZE} // 8192;
$chunk_size = 8192 unless $chunk_size =~ /\A[1-9][0-9]*\z/;
my $holdback_limit = 8192;
my $buffer = '';

# ECMA-48 CSI: parameter bytes, intermediate bytes, then a final byte.
my $csi = qr/(?:\e\[|\x9b)[\x30-\x3f]*[\x20-\x2f]*[\x40-\x7e]/;
# OSC accepts xterm's BEL extension as well as the standard string terminator.
my $osc = qr/(?:\e\]|\x9d)[^\a\e\x9c]*(?:\a|\e\\|\x9c)/;
my $string = qr/(?:\e[\x50\x58\x5e\x5f]|[\x90\x98\x9e\x9f])[^\e\x9c]*(?:\e\\|\x9c)/;
my $charset = qr/\e(?:[%#]|[\(\)\*\+\-\.\/])[\x30-\x7e]/;
# Fe excludes [ ] P X ^ _: those bytes open CSI/control strings, not two-byte
# escape sequences. Keeping them out prevents an OSC split across reads from
# leaking its payload.
my $fe = qr/\e[\x30-\x4f\x51-\x57\x59-\x5a\x5c\x60-\x7e]/;
my $complete = qr/(?:$csi|$osc|$string|$charset|$fe)/;
my $partial = qr/
  (?:
    (?:\e\[|\x9b)[\x30-\x3f]*[\x20-\x2f]* |
    (?:\e\]|\x9d)[^\a\e\x9c]*(?:\e)? |
    (?:\e[\x50\x58\x5e\x5f]|[\x90\x98\x9e\x9f])[^\e\x9c]*(?:\e)? |
    \e(?:[%#]|[\(\)\*\+\-\.\/])? |
    \e
  )\z
/x;

while (sysread(STDIN, my $chunk, $chunk_size)) {
    $buffer .= $chunk;
    $buffer =~ s/$complete//g;

    my $holdback = '';
    if ($buffer =~ /($partial)/) {
        $holdback = $1;
        if (length $holdback < $holdback_limit) {
            substr($buffer, -length($holdback)) = '';
        } else {
            $holdback = '';
        }
    }

    # Unrecognised ESC forms are deliberately degraded by removing only ESC;
    # console_codes(4) documents non-standard forms for which no total parser
    # exists, while a transcript must never retain raw ESC bytes.
    $buffer =~ s/\e//g;
    print $buffer if length $buffer;
    $buffer = $holdback;
}

# An incomplete final sequence has no readable payload yet. Drop its ESC byte
# and release any remainder, preserving the no-ESC transcript invariant.
$buffer =~ s/\e//g;
print $buffer if length $buffer;
