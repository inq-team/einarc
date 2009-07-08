require 'raid/baseraid'
require 'raid/meta'
RAID::MODULES.each_key { |k| require "raid/#{k}" }

module RAID

	@@pcimap = nil

	def self.pcimap
		return @@pcimap if @@pcimap
		@@pcimap = {}
		MODULES.each_pair { |filename, m|
			klass = RAID.const_get(m[:classname])
			if klass.constants.include?('PCI_IDS')
				klass::PCI_IDS.each_value { |ids| @@pcimap[ids] = filename }
			end
		}
	end

	def self.autodetect
		pci = `lspci -mn`
		raise "Error executing 'lspci': autodetection is not possible" if $?.exitstatus != 0

		res = []
		pci.split("\n").each { |l|
			next unless l =~ /^(.*?) "(.*?)" "(.*?)" "(.*?)"(.*?)"(.*?)" "(.*?)"$/
			vendor_id = $3
			product_id = $4
#			p [vendor_id, product_id]
			adapter = find_adapter_by_pciid(vendor_id, product_id)
			if adapter
				puts "Detected device supported by \"#{adapter}\" (#{vendor_id}:#{product_id})"
				res << adapter
			end
		}
		res.sort!.uniq!
		return res
	end

	# Find corresponding Einarc's module working with controller specified by PCI ID
	def self.find_adapter_by_pciid(vendor_id, product_id, sub_vendor_id = nil, sub_product_id = nil)
		return (pcimap[[vendor_id, product_id, sub_vendor_id, sub_product_id]] or pcimap[[vendor_id, product_id]])
	end
end
