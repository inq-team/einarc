include dep.Makefile

.PHONY: all clean

all: \
	xhtml/manual.html \
	man/einarc.8 \
	man/raid-wizard-clear.8 \
	man/raid-wizard-passthrough.8 \
	man/einarc-install.8

xhtml/manual.html: manual.txt VERSION $(DEPS_manual)
	mkdir -p xhtml/images
	a2x -f xhtml --destination-dir=xhtml manual.txt
	cp -r images/*.png xhtml/images

man/einarc.8: einarc-man.txt VERSION $(DEPS_einarc_man)
	mkdir -p man
	a2x -f manpage --destination-dir=man einarc-man.txt

man/einarc-install.8: einarc-install-man.txt VERSION $(DEPS_einarc_install_man)
	mkdir -p man
	a2x -f manpage --destination-dir=man einarc-install-man.txt

man/raid-wizard-clear.8: raid-wizard-clear-man.txt VERSION $(DEPS_raid_wizard_clear)
	mkdir -p man
	a2x -f manpage --destination-dir=man raid-wizard-clear-man.txt

man/raid-wizard-passthrough.8: raid-wizard-passthrough-man.txt VERSION $(DEPS_raid_wizard_passthrough)
	mkdir -p man
	a2x -f manpage --destination-dir=man raid-wizard-passthrough-man.txt

VERSION: ../VERSION
	sed 's/^Einarc //' <../VERSION >VERSION

NEWS: ../NEWS
	sed 's/^== /=== /' <../NEWS >NEWS

clean:
	rm -rf xhtml man manual.xml einarc-man.xml einarc-install-man.xml NEWS VERSION
