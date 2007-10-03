include Makefile.config

all: tools
	echo '$$EINARC_LIB = "$(EINARC_LIB_DIR)"' >src/raid/baseraid.rb
	cat src/raid/baseraid.rb.in >>src/raid/baseraid.rb

#all: ext/lsi_mpt.so

install:
	echo $(BIN_DIR)
	echo $(DESTDIR)
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
	tools/lsi_megarc/megarc.bin \
	tools/lsi_megacli/MegaCli

download: \
	proprietary/V1.72.250_70306.zip \
	proprietary/ut_linux_megarc_1.11.zip \
	proprietary/1.01.27_Linux_MegaCli.zip

clean:
	rm -rf tools
	rm -f ext/lsi_mpt.o ext/lsi_mpt.so

veryclean: clean
	rm -rf proprietary Makefile.config

#===============================================================================
# Module: areca
#===============================================================================

tools/areca/cli: proprietary/V1.72.250_70306.zip
	mkdir -p tools/areca
	unzip -j proprietary/V1.72.250_70306.zip -d tools/areca
	chmod a+x tools/areca/*

proprietary/V1.72.250_70306.zip:
	mkdir -p proprietary
	wget -P proprietary ftp://ftp.areca.com.tw/RaidCards/AP_Drivers/Linux/CLI/V1.72.250_70306.zip

#===============================================================================
# Module: lsi_megarc
#===============================================================================

tools/lsi_megarc/megarc.bin: proprietary/ut_linux_megarc_1.11.zip
	mkdir -p tools/lsi_megarc
	unzip proprietary/ut_linux_megarc_1.11.zip megarc.bin -d tools/lsi_megarc
	chmod a+x tools/lsi_megarc/megarc.bin

proprietary/ut_linux_megarc_1.11.zip:
	mkdir -p proprietary
	wget -P proprietary http://www.lsi.com/files/support/rsa/utilities/megaconf/ut_linux_megarc_1.11.zip

#===============================================================================
# Module: lsi_megacli
#===============================================================================

tools/lsi_megacli/MegaCli: proprietary/1.01.27_Linux_MegaCli.zip
	mkdir -p tools/lsi_megacli
	cd tools/lsi_megacli
	unzip -j proprietary/1.01.27_Linux_MegaCli.zip -d tools/lsi_megacli
	unzip tools/lsi_megacli/MegaCliLin.zip -d tools/lsi_megacli
	rpm2cpio tools/lsi_megacli/MegaCli-1.01.27-0.i386.rpm | cpio -idv
	mv opt/MegaRAID/MegaCli/MegaCli opt/MegaRAID/MegaCli/MegaCli64 tools/lsi_megacli/
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
