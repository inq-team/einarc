include dep.Makefile

.PHONY: all clean

all: \
	xhtml/manual.html \
	man/einarc.1 \
	man/einarc-install.8

xhtml/manual.html: manual.txt VERSION $(DEPS_manual)
	mkdir -p xhtml
	a2x -f xhtml --destination-dir=xhtml manual.txt
	cp -r images/*.png xhtml

man/einarc.1: einarc-man.txt VERSION $(DEPS_einarc_man)
	mkdir -p man
	a2x -f manpage --destination-dir=man einarc-man.txt

man/einarc-install.8: einarc-install-man.txt VERSION $(DEPS_einarc_install_man)
	mkdir -p man
	a2x -f manpage --destination-dir=man einarc-install-man.txt

VERSION: ../VERSION
	sed 's/^Einarc //' <../VERSION >VERSION

NEWS: ../NEWS
	sed 's/^== /=== /' <../NEWS >NEWS

clean:
	rm -rf xhtml man manual.xml einarc-man.xml einarc-install-man.xml NEWS VERSION
