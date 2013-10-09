# Special file that stores meta-information: a detailed list of modules
# supported in this version of Einarc and some methods to aid its
# configuration and installation.

module RAID

	MODULES = {
		'areca' => {
			:desc => 'Areca adapters',
			:classname => 'Areca',
			:proprietary => true,
		},
		'lsi_megarc' => {
			:desc => 'older LSI MegaRAID SCSI/SATA adapters',
			:classname => 'LSIMegaRc',
			:proprietary => true,
		},
#		'lsi_mpt' => {
#			:desc => 'LSI MPT HBA adapters',
#			:classname => 'LSIMPT',
#			:proprietary => false,
#		},
		'lsi_megacli' => {
			:desc => 'newest LSI MegaRAID SAS adapters',
			:classname => 'LSIMegaCli',
			:proprietary => true,
		},
		'adaptec_aaccli' => {
			:desc => 'older Adaptec SCSI adapters that use aaccli',
			:classname => 'AdaptecAacCli',
			:proprietary => true,
		},
		'adaptec_arcconf' => {
			:desc => 'newer Adaptec adapters that use arcconf',
			:classname => 'AdaptecArcConf',
			:proprietary => true,
		},
		'amcc' => {
			:desc => '3Ware/AMCC RAID 7/8/9xxx/95xxx series controllers that use tw_cli',
			:classname => 'Amcc',
			:proprietary => true,
		},
		'software' => {
			:desc => 'Linux software RAID devices',
			:classname => 'Software',
			:proprietary => false,
		},
	}

	def self.generate_ruby_config(modules, destination)
		return if modules.empty?
		File.open(destination, 'w') { |f|
			f.puts <<__EOF__
# DO NOT EDIT: IT'S A GENERATED FILE! USE ./einarc-install TO REGENERATE!

module RAID
#{modules.collect { |m| "\trequire 'raid/#{m}'" }.join("\n")}

	RAIDS = {
#{modules.collect { |m| "\t\t'#{m}' => #{MODULES[m][:classname]}," }.join("\n")}
	}
end
__EOF__
		}
	end

end
