#  Copyright (C) 2016 Tobias Oetiker

AUTOMAKE_OPTIONS =  foreign

SUBDIRS = lib thirdparty

BIN = bin/$(SCRIPT_NAME)

PERLTESTS := $(shell test -d t && find t -name "*.t")

THIRDPARTY_DIR := $(shell pwd)/thirdparty
SCHEMATA := $(shell test -d schemata && find schemata -type f -name "*.pl")

EXTRA_DIST = VERSION COPYRIGHT README.md LICENSE CHANGES AUTHORS PERL_MODULES $(BIN) $(PERLTESTS) $(SCHEMATA)

YEAR := $(shell date +%Y)
DATE := $(shell date +%Y-%m-%d)

datadir = $(prefix)
nobase_data_DATA = $(PUB) $(SCHEMATA)


README.md COPYRIGHT : VERSION
	$(PERL) -i -p -e 's/(#VERSION#|\d+\.\d+\.\d+(?:-\w+)?)/$(PACKAGE_VERSION)/g;s/(#YEAR#|20[1-4]\d)/$(YEAR)/g;s/(#DATE#|20[1-9]\d-[01]\d-[0-3]\d)/$(DATE)/g;' $@

dist_bin_SCRIPTS = $(BIN)

dist-hook: thirdparty $(POD)
	$(PERL) -i -p -e 's/^my .*# VERSION/my \$$VERSION = q{$(PACKAGE_VERSION)}; # VERSION/' $(distdir)/$(BIN)
	$(PERL) -i -p -e 's/^our\s+\$$VERSION\s*=\s*".+?";/our \$$VERSION = "$(PACKAGE_VERSION)";/;'  $(distdir)/lib/$(CLASS_NAME)/*.pm

install-exec-hook:
	[ "$(PERL5LIB)" == "" ] || cd "$(DESTDIR)$(exec_prefix)" && $(PERL) -i -p -e 's{.*# PERL5LIB}{use lib qw($(PERL5LIB)); # PERL5LIB}' $(BIN) || true
	cd "$(DESTDIR)$(exec_prefix)" && $(PERL) -i -p -e 's{.*# LIBDIR}{use lib qw($(libdir)); # LIBDIR}' $(BIN)
	cd "$(DESTDIR)$(exec_prefix)" && $(PERL) -i -p -e 's{^#!.*perl.*}{#!$(PERL)};' $(BIN)
	cd "$(DESTDIR)$(libdir)/Zadm" && $(PERL) -i -p -e 's{^my .*# DATADIR}{my \$$DATADIR = "$(localstatedir)"; # DATADIR};' Zones.pm

test:
	$(PERL) "-MExtUtils::Command::MM" "-e" "test_harness(0, 'lib','thirdparty/lib/perl5')" $(PERLTESTS)
