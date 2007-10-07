-include Makefile.config

all: tools
	if [ -z "$(EINARC_LIB_DIR)" ]; then echo 'Run ./configure first!'; false; fi
	echo '$$EINARC_LIB = "$(EINARC_LIB_DIR)"' >src/raid/baseraid.rb
	cat src/raid/baseraid.rb.in >>src/raid/baseraid.rb

#all: ext/lsi_mpt.so

install:
	if [ -z "$(EINARC_LIB_DIR)" ]; then echo 'Run ./configure first!'; false; fi
	mkdir -p $(DESTDIR)$(BIN_DIR) $(DESTDIR)$(RUBY_SHARE_DIR) $(DESTDIR)$(EINARC_LIB_DIR)
	install -m755 src/einarc src/raid-wizard-passthrough src/raid-wizard-optimal $(DESTDIR)$(BIN_DIR)
	cp src/raid/*.rb $(DESTDIR)$(RUBY_SHARE_DIR)
	cp -ar tools/* $(DESTDIR)$(EINARC_LIB_DIR)
#	if File.exists?('ext/lsi_mpt.so')
#		mkdir_p INSTALL_DIR_PREFIX + LIB_DIR
#		cp 'ext/lsi_mpt.so', INSTALL_DIR_PREFIX + LIB_DIR
#	end

tools: \
	tools/areca/cli \
	tools/lsi_megarc/cli \
	tools/lsi_megacli/cli \
	tools/adaptec_aaccli/cli

download: \
	proprietary/V1.72.250_70306.zip \
	proprietary/ut_linux_megarc_1.11.zip \
	proprietary/1.01.27_Linux_MegaCli.zip \
	proprietary/5400s_s73_cli_v10.tar.Z

doc: doc/xhtml

doc/xhtml: doc/manual.txt
	mkdir -p doc/xhtml
	a2x -f xhtml -d doc/xhtml doc/manual.txt
	cp -r doc/images doc/xhtml

clean:
	rm -rf tools
	rm -f ext/lsi_mpt.o ext/lsi_mpt.so

veryclean: clean
	rm -rf proprietary Makefile.config doc/xhtml

#===============================================================================
# Module: areca
#===============================================================================

tools/areca/cli: proprietary/V1.72.250_70306.zip
	mkdir -p tools/areca
	unzip -j proprietary/V1.72.250_70306.zip -d tools/areca
	chmod a+rx tools/areca/*
	if [ "$(TARGET)" == x86_64 ]; then \
		mv tools/areca/cli64 tools/areca/cli; \
	else \
		mv tools/areca/cli32 tools/areca/cli; \
	fi

proprietary/V1.72.250_70306.zip:
	mkdir -p proprietary
	wget -P proprietary ftp://ftp.areca.com.tw/RaidCards/AP_Drivers/Linux/CLI/V1.72.250_70306.zip

#===============================================================================
# Module: lsi_megarc
#===============================================================================

tools/lsi_megarc/cli: proprietary/ut_linux_megarc_1.11.zip
	mkdir -p tools/lsi_megarc
	unzip proprietary/ut_linux_megarc_1.11.zip megarc.bin -d tools/lsi_megarc
	chmod a+rx tools/lsi_megarc/megarc.bin
	mv tools/lsi_megarc/megarc.bin tools/lsi_megarc/cli

proprietary/ut_linux_megarc_1.11.zip:
	mkdir -p proprietary
	wget -P proprietary http://www.lsi.com/files/support/rsa/utilities/megaconf/ut_linux_megarc_1.11.zip

#===============================================================================
# Module: lsi_megacli
#===============================================================================

tools/lsi_megacli/cli: proprietary/1.01.27_Linux_MegaCli.zip
	mkdir -p tools/lsi_megacli
	unzip -j proprietary/1.01.27_Linux_MegaCli.zip -d tools/lsi_megacli
	unzip tools/lsi_megacli/MegaCliLin.zip -d tools/lsi_megacli
	rpm2cpio tools/lsi_megacli/MegaCli-1.01.27-0.i386.rpm | cpio -idv
	if [ "$(TARGET)" == x86_64 ]; then \
		mv opt/MegaRAID/MegaCli/MegaCli64 tools/lsi_megacli/cli; \
	else \
		mv opt/MegaRAID/MegaCli/MegaCli tools/lsi_megacli/cli; \
	fi
	rm -Rf opt tools/lsi_megacli/MegaCli-1.01.27-0.i386.rpm tools/lsi_megacli/MegaCliLin.zip

proprietary/1.01.27_Linux_MegaCli.zip:
	mkdir -p proprietary
	wget -P proprietary http://www.lsi.com/support/downloads/megaraid/miscellaneous/linux/1.01.27_Linux_MegaCli.zip

#===============================================================================
# Module: lsi_mpt
#===============================================================================

ext/lsi_mpt.o: ext/lsi_mpt.c
	$(CC) -pipe -Wall -O2 -fPIC -I/usr/include/ruby/1.8 -I/usr/lib64/ruby/1.8/x86_64-linux-gnu -c -o ext/lsi_mpt.o ext/lsi_mpt.c

ext/lsi_mpt.so: ext/lsi_mpt.o
	$(CC) -shared -rdynamic -Wl,-export-dynamic -o ext/lsi_mpt.so ext/lsi_mpt.o -ldl -lcrypt -lm -lc -lruby

#	sh 'wget -P proprietary http://www.lsi.com/files/support/ssp/fusionmpt/Utilities/mptutil_linux_10200.zip'

#===============================================================================
# Module: adaptec_aaccli
#===============================================================================

tools/adaptec_aaccli/cli: proprietary/5400s_s73_cli_v10.tar.Z
	mkdir -p tools/adaptec_aaccli
	tar -xvzf proprietary/5400s_s73_cli_v10.tar.Z -C tools/adaptec_aaccli
	rpm2cpio tools/adaptec_aaccli/aacapps-1.0-0.i386.rpm | cpio -idv
	rm -rf tools/adaptec_aaccli
	mkdir -p tools/adaptec_aaccli
	mv usr/sbin/aaccli tools/adaptec_aaccli/cli
	rm -rf dev usr

proprietary/5400s_s73_cli_v10.tar.Z:
	mkdir -p proprietary
	wget -P proprietary http://download.adaptec.com/raid/ccu/linux/5400s_s73_cli_v10.tar.Z
