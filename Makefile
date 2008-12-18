-include config.Makefile

all: tools src/raid/build-config.rb
#all: ext/lsi_mpt.so

BIN_FILES=\
	src/einarc \
	src/einarc-install \
	src/raid-wizard-passthrough \
	src/raid-wizard-optimal \
	src/raid-wizard-clear

install:
	if [ -z "$(EINARC_LIB_DIR)" ]; then echo 'Run ./configure first!'; false; fi
	mkdir -p $(DESTDIR)$(BIN_DIR) $(DESTDIR)$(RUBY_SHARE_DIR) $(DESTDIR)$(EINARC_VAR_DIR) $(DESTDIR)$(EINARC_LIB_DIR)
	install -m755 $(BIN_FILES) $(DESTDIR)$(BIN_DIR)
	cp src/raid/*.rb proprietary.Makefile $(DESTDIR)$(RUBY_SHARE_DIR)
	if test -r config.rb; then cp config.rb $(DESTDIR)$(EINARC_VAR_DIR); fi
	if test -r proprietary/agreed; then mkdir -p $(DESTDIR)$(EINARC_VAR_DIR)/proprietary && cp proprietary/agreed $(DESTDIR)$(EINARC_VAR_DIR)/proprietary; fi
	if test -d tools; then cp -r tools/* $(DESTDIR)$(EINARC_LIB_DIR); fi
#	if File.exists?('ext/lsi_mpt.so')
#		mkdir_p INSTALL_DIR_PREFIX + LIB_DIR
#		cp 'ext/lsi_mpt.so', INSTALL_DIR_PREFIX + LIB_DIR
#	end

doc: doc/xhtml

doc/xhtml: doc/manual.txt
	mkdir -p doc/xhtml
	a2x -f xhtml -D doc/xhtml doc/manual.txt
	cp -r doc/images doc/xhtml

clean:
	rm -rf tools
	rm -f ext/lsi_mpt.o ext/lsi_mpt.so

veryclean: clean
	rm -rf proprietary config.Makefile src/raid/build-config.rb config.rb doc/xhtml

include proprietary.Makefile
