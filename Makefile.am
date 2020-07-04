#  Copyright (C) 2016 Tobias Oetiker

AUTOMAKE_OPTIONS =  foreign

SUBDIRS = lib thirdparty

BIN = bin/$(SCRIPT_NAME)

MAN = man/$(SCRIPT_NAME).1
POD = doc/$(SCRIPT_NAME).pod

export PATH := /usr/gnu/bin:$(PATH)

PERLTESTS := $(shell test -d t && find t -name "*.t")
TOOLS := $(shell test -d tools && find tools)

EXTRA_DIST = VERSION COPYRIGHT README.md LICENSE CHANGES AUTHORS cpanfile $(BIN) $(PERLTESTS) $(MAN) $(TOOLS)

YEAR := $(shell date +%Y)
DATE := $(shell date +%Y-%m-%d)

datadir = $(prefix)
nobase_data_DATA = $(PUB)

README.md COPYRIGHT: VERSION
	$(PERL) -i -p -e 's/(#VERSION#|\d+\.\d+\.\d+(?:-\w+)?)/$(PACKAGE_VERSION)/g;s/(#YEAR#|20[1-4]\d)/$(YEAR)/g;s/(#DATE#|20[1-9]\d-[01]\d-[0-3]\d)/$(DATE)/g;' $@

imandir = $(mandir)/man1
iman_DATA = $(MAN)

doc/%.pod: bin/% VERSION lib/Zadm/Zone/*.pm
	$(AM_V_at)mkdir -p doc; $(PERL) tools/genpod $< $@

man/%.1: doc/%.pod
	$(AM_V_at)mkdir -p man; test $(POD2MAN) = "no" || $(POD2MAN) --release=$(VERSION) --center=$(PACKAGE_NAME) $< > $@

dist_bin_SCRIPTS = $(BIN)

dist-hook: thirdparty $(POD)
	$(PERL) -i -p -e 's/^my .*# VERSION/my \$$VERSION = q{$(PACKAGE_VERSION)}; # VERSION/' $(distdir)/$(BIN)
	$(PERL) -i -p -e 's/^our\s+\$$VERSION\s*=\s*".+?";/our \$$VERSION = "$(PACKAGE_VERSION)";/;' $(distdir)/lib/$(CLASS_NAME)/*.pm

install-exec-hook:
	[ "$(PERL5LIB)" == "" ] || cd "$(DESTDIR)$(exec_prefix)" && $(PERL) -i -p -e 's{.*# PERL5LIB}{use lib qw($(PERL5LIB)); # PERL5LIB}' $(BIN) || true
	cd "$(DESTDIR)$(exec_prefix)" && $(PERL) -i -p -e 's{.*# LIBDIR}{use lib qw($(libdir)); # LIBDIR}' $(BIN)
	cd "$(DESTDIR)$(exec_prefix)" && $(PERL) -i -p -e 's{^#!.*perl.*}{#!$(PERL)};' $(BIN)
	cd "$(DESTDIR)$(libdir)/Zadm" && $(PERL) -i -p -e 's{^my .*# DATADIR}{my \$$DATADIR = "$(localstatedir)"; # DATADIR};' Zones.pm

test:
	$(PERL) "-MExtUtils::Command::MM" "-e" "test_harness(0, 'lib','thirdparty/lib/perl5')" $(PERLTESTS)
