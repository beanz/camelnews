#!/usr/bin/perl
#
# Copyright (C) 2011 by Mark Hindess

use strict;
use warnings;
use Test::More;

require_ok('etc/app_config.pl');
require_ok('bin/app.psgi');
use_ok('Comments');
use_ok('HTMLGen');

done_testing;

