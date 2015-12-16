#!/usr/bin/perl -c

# Package to handle Cyrus Index files (version 9 only)

package Cyrus::CacheFile;

use strict;
use warnings;

use IO::File;
use IO::File::fcntl;
use IO::Handle;
use File::Temp;
use YAML;

# /* Access assistance macros for memory-mapped cache file data */
# /* CACHE_ITEM_BIT32: Convert to host byte order */
# /* CACHE_ITEM_LEN: Get the length out */
# /* CACHE_ITEM_NEXT: Return a pointer to the next entry.  Sizes are
#  * 4-byte aligned, so round up to the next 4 byte boundry */
#  #define CACHE_ITEM_BIT32(ptr) (ntohl(*((bit32 *)(ptr))))
#  #define CACHE_ITEM_LEN(ptr) CACHE_ITEM_BIT32(ptr)
#  #define CACHE_ITEM_NEXT(ptr) ((ptr)+4+((3+CACHE_ITEM_LEN(ptr))&~3))

# #define MAILBOX_CACHE_MINOR_VERSION 2
# #define NUM_CACHE_FIELDS 10

our $NUM_CACHE_FIELDS = 10;
our @NAMES = qw(
  ENVELOPE
  BODYSTRUCTURE
  BODY
  SECTION
  HEADERS
  FROM
  TO
  CC
  BCC
  SUBJECT
);

# PUBLIC API

sub new {
  my $class = shift;
  my $handle = shift;

  # read header
  my $buf;
  # XXX - check for success!
  sysread($handle, $buf, 4);
  my $version = unpack('N', $buf);
  my $Self = bless { version => $version, handle => $handle, offset => 4 }, ref($class) || $class;
  return $Self;
}

sub new_file {
  my $class = shift;
  my $file = shift;
  my $lockopts = shift;

  my $fh;
  if ($lockopts) {
    $lockopts = ['lock_ex'] unless ref($lockopts) eq 'ARRAY';
    $fh = IO::File::fcntl->new($file, '+<', @$lockopts)
          || die "Can't open $file for locked read: $!";
  } else {
    $fh = IO::File->new("< $file") 
          || die "Can't open $file for read: $!";
  }

  return $class->new($fh);
}

sub next_record {
  my $Self = shift;
  my $buf;

  my @record;
  my $size = 0;
  for (1..$NUM_CACHE_FIELDS) {
    sysread($Self->{handle}, $buf, 4);
    return undef unless $buf;
    my $num = unpack('N', $buf);
    my $bytes = $num;
    $bytes += 4 - $num % 4 if $num % 4; # offsets are multiple of 4 bytes
    sysread($Self->{handle}, $buf, $bytes);
    push @record, [$num, $bytes, $buf];
    $size += $bytes + 4;
  }

  my $ret = {
    size => $size,
    records => \@record,
  };

  $Self->{record} = $ret;
  $Self->{offset} += $size;

  return $ret;
}

sub record {
  my $Self = shift;
  my $Field = shift;

  return undef unless ($Self->{record}); 

  if ($Field) {
    return $Self->{record}{$Field};
  }
  return $Self->{record};
}

sub offset {
  my $Self = shift;

  if (@_) {
    my $spot = shift;
    seek($Self->{handle}, $spot, 0);
    $Self->{offset} = $spot;
  }

  return $Self->{offset};
}

sub dump {
  my $Self = shift;

  while (my $rec = $Self->next_record()) {
    $Self->dump_record($rec);
  }
}

sub dump_record {
  my $Self = shift;
  my $rec = shift || $Self->{record};
  return unless $rec;
  print Dump($rec->{records});
}

sub print_record {
  my $Self = shift;
  my $rec = shift || $Self->{record};
  return unless $rec;
  foreach my $rnum (0..$NUM_CACHE_FIELDS-1) {
    my $record = $rec->{records}[$rnum];
    my $str = substr($record->[2], 0, $record->[0]);
    if ($rnum == 3) { # section
      my @items = unpack('N*', $str);
      $str = parse_section(0, \@items);
    }
    print "$NAMES[$rnum]: $str\n";
  }
}

sub parse_section {
  my $part = shift;
  my $items = shift;
  my $num_parts = shift @$items;
  if ($num_parts == 0) {
    return "$part:()";
  }
  my $ret = "$part:(" . parse_item($items);
  my $n = 1;
  while ($n < $num_parts) {
    my $subpart = $part ? "$part.$n" : $n;
    $ret .= " " . parse_item($items);
    $n++;
  }
  $n = 1;
  $ret .= ")";
  while ($n < $num_parts) {
    my $subpart = $part ? "$part.$n" : $n;
    $ret .= " " . parse_section($subpart, $items);
    $n++;
  }
  return $ret;
}

sub parse_item {
  my $items = shift;
  my $header_offset = shift @$items;
  my $header_size = shift @$items;
  my $content_offset = shift @$items;
  my $content_size = shift @$items;
  my $encoding = shift @$items;
  return "($header_offset:$header_size $content_offset:$content_size $encoding)";
}
