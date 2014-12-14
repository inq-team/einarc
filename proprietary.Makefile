WGET=wget -q -N -P proprietary

# Special target to get proprietary download confirmation interactively
proprietary/agreed:
	@echo 'Unfortunately, Einarc uses some proprietary command-line utilities to'
	@echo 'control storages. Using it means that you agree with respective licenses'
	@echo 'and download agreements. For your convenience, they are available in'
	@echo 'agreements/ directory. Please read them and agree before proceeding.'
	@echo
	@echo 'Either type "yes" if you have read and agreed to all the respective'
	@echo 'licenses or reconfigure einarc disabling propriatery modules.'
	@echo
	@echo -n 'Do you agree? '
	@read agree && if [ "$$agree" != yes ]; then \
		echo "Einarc can't continue unless you'll agree"; \
		false; \
	else \
		mkdir -p proprietary && \
		echo "User $$USER has agreed to all the licenses on `date`" >proprietary/agreed; \
	fi

#===============================================================================
# Module: areca
#===============================================================================

tools/areca/cli: proprietary/v1.9.0_120503.zip
	mkdir -p tools/areca
	unzip -j proprietary/v1.9.0_120503.zip -d tools/areca
	chmod a+rx tools/areca/*
	if [ "$(TARGET)" = x86_64 ]; then \
		mv tools/areca/cli64 tools/areca/cli; \
		rm -f tools/areca/cli32; \
	else \
		mv tools/areca/cli32 tools/areca/cli; \
		rm -f tools/areca/cli64; \
	fi
	touch tools/areca/cli proprietary/v1.9.0_120503.zip

proprietary/v1.9.0_120503.zip: proprietary/agreed
	mkdir -p proprietary
	$(WGET) ftp://ftp.areca.com.tw/RaidCards/AP_Drivers/Linux/CLI/v1.9.0_120503.zip

#===============================================================================
# Module: lsi_megarc
#===============================================================================

tools/lsi_megarc/cli: proprietary/ut_linux_megarc_1.11.zip
	mkdir -p tools/lsi_megarc
	unzip proprietary/ut_linux_megarc_1.11.zip megarc.bin -d tools/lsi_megarc
	chmod a+rx tools/lsi_megarc/megarc.bin
	mv tools/lsi_megarc/megarc.bin tools/lsi_megarc/cli
	touch tools/lsi_megarc/cli proprietary/ut_linux_megarc_1.11.zip

# LSI seems to use a fairly complex and intricate scheme on a
# site. You can be in 2 states: "agreed" or "not (yet) agreed" with
# licensing info. State is tracked by IP and retained for some time,
# thus it's usually enough to visit "agreement" URL and then we can
# fetch the file itself.
proprietary/ut_linux_megarc_1.11.zip: proprietary/agreed
	mkdir -p proprietary
	$(WGET) 'http://www.lsi.com/magic.axd?x=e&file=http%3A//www.lsi.com/downloads/Public/Obsolete/Obsolete%2520Common%2520Files/ut_linux_megarc_1.11.zip'
	$(WGET) 'http://www.lsi.com/downloads/Public/Obsolete/Obsolete%20Common%20Files/ut_linux_megarc_1.11.zip'
	touch proprietary/ut_linux_megarc_1.11.zip

#===============================================================================
# Module: lsi_megacli
#===============================================================================

LSI_MEGACLI_VERSION=8.07.14
LSI_MEGACLI_ZIP=$(LSI_MEGACLI_VERSION)_MegaCLI.zip
LSI_MEGACLI_RPM=MegaCli-$(LSI_MEGACLI_VERSION)-1.noarch.rpm

tools/lsi_megacli/cli: proprietary/$(LSI_MEGACLI_ZIP)
	rm -rf tools/lsi_megacli
	mkdir -p tools/lsi_megacli
	unzip -j proprietary/$(LSI_MEGACLI_ZIP) -d tools/lsi_megacli Linux/$(LSI_MEGACLI_RPM)
	rpm2cpio tools/lsi_megacli/$(LSI_MEGACLI_RPM) | cpio -idv
	if [ "$(TARGET)" = x86_64 ]; then \
		mv opt/MegaRAID/MegaCli/MegaCli64 tools/lsi_megacli/cli.bin; \
	else \
		mv opt/MegaRAID/MegaCli/MegaCli tools/lsi_megacli/cli.bin; \
	fi
	rm -Rf \
		opt \
		tools/lsi_megacli/*.rpm
	printf '#!/bin/sh\nCLI_DIR=$$(dirname "$$0")\nLD_LIBRARY_PATH="$$CLI_DIR" "$$CLI_DIR/cli.bin" $$@ -NoLog\nexit $$?\n' >tools/lsi_megacli/cli
	chmod a+x tools/lsi_megacli/cli

# See above for crazy LSI stateful-by-IP site mechanics.
proprietary/$(LSI_MEGACLI_ZIP): proprietary/agreed
	mkdir -p proprietary
	$(WGET) 'http://www.lsi.com/magic.axd?x=e&file=http%3A//www.lsi.com/downloads/Public/Obsolete/Obsolete%2520Common%2520Files/ut_linux_megarc_1.11.zip'
	$(WGET) "http://www.lsi.com/downloads/Public/RAID%20Controllers/RAID%20Controllers%20Common%20Files/$(LSI_MEGACLI_ZIP)"
	touch proprietary/$(LSI_MEGACLI_ZIP)

#===============================================================================
# Module: amcc
#===============================================================================

proprietary/cli_linux_10.2.1_9.5.4.zip: proprietary/agreed
	mkdir -p proprietary
	$(WGET) ftp://tsupport:tsupport@ftp0.lsil.com/private/3Ware/downloads/cli_linux_10.2.1_9.5.4.zip

tools/amcc/cli: proprietary/cli_linux_10.2.1_9.5.4.zip
	mkdir -p tools/amcc
	unzip -j proprietary/cli_linux_10.2.1_9.5.4.zip -d tools/amcc $(TARGET)/tw_cli
	mv tools/amcc/tw_cli tools/amcc/cli
	chmod a+x tools/amcc/cli
	# prevent repeated download/extraction
	touch tools/amcc/cli proprietary/cli_linux_10.2.1_9.5.4.zip

#===============================================================================
# Module: lsi_mpt
#===============================================================================

ext/lsi_mpt.o: ext/lsi_mpt.c
	$(CC) -pipe -Wall -O2 -fPIC -I/usr/include/ruby/1.8 -I/usr/lib64/ruby/1.8/x86_64-linux-gnu -c -o ext/lsi_mpt.o ext/lsi_mpt.c

ext/lsi_mpt.so: ext/lsi_mpt.o
	$(CC) -shared -rdynamic -Wl,-export-dynamic -o ext/lsi_mpt.so ext/lsi_mpt.o -ldl -lcrypt -lm -lc -lruby

#	sh '$(WGET) http://www.lsi.com/files/support/ssp/fusionmpt/Utilities/mptutil_linux_10200.zip'

#===============================================================================
# Module: adaptec_aaccli
#===============================================================================

tools/adaptec_aaccli/cli: proprietary/Adaptec_Storage_Manager-Linux_v2.10.00.tgz
	mkdir -p tools/adaptec_aaccli
	tar -xvzf proprietary/Adaptec_Storage_Manager-Linux_v2.10.00.tgz -C tools/adaptec_aaccli
	rpm2cpio tools/adaptec_aaccli/aacapps-4.1-0.i386.rpm | cpio -idv
	rm -rf tools/adaptec_aaccli
	mkdir -p tools/adaptec_aaccli
	mv usr/sbin/aaccli tools/adaptec_aaccli/cli
	rm -rf dev usr

proprietary/Adaptec_Storage_Manager-Linux_v2.10.00.tgz: proprietary/agreed
	mkdir -p proprietary
	$(WGET) http://download.adaptec.com/raid/aac/sm/Adaptec_Storage_Manager-Linux_v2.10.00.tgz

#===============================================================================
# Module: adaptec_arcconf
#===============================================================================

ifeq ($(TARGET), x86_64)
tools/adaptec_arcconf/cli: proprietary/arcconf_v1_1_20324.zip
	mkdir -p tools/adaptec_arcconf
	unzip -j proprietary/arcconf_v1_1_20324.zip linux_x64/arcconf -d tools/adaptec_arcconf
	chmod a+rx tools/adaptec_arcconf/arcconf
	mv tools/adaptec_arcconf/arcconf tools/adaptec_arcconf/cli
	touch tools/adaptec_arcconf/cli proprietary/arcconf_v1_1_20324.zip
else
tools/adaptec_arcconf/cli: proprietary/arcconf_v1_1_20324.zip
	mkdir -p tools/adaptec_arcconf
	unzip -j proprietary/arcconf_v1_1_20324.zip linux_x86/arcconf -d tools/adaptec_arcconf
	chmod a+rx tools/adaptec_arcconf/arcconf
	mv tools/adaptec_arcconf/arcconf tools/adaptec_arcconf/cli
	touch tools/adaptec_arcconf/cli proprietary/arcconf_v1_1_20324.zip
endif

proprietary/arcconf_v1_1_20324.zip: proprietary/agreed
	mkdir -p proprietary
	$(WGET) http://download.adaptec.com/raid/storage_manager/arcconf_v1_1_20324.zip
