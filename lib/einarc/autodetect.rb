require 'einarc/baseraid'
require 'einarc/meta'
Einarc::MODULES.each_key { |k| require "einarc/#{k}" }

module Einarc

	@@pcimap = nil

	def self.pcimap
		return @@pcimap if @@pcimap
		@@pcimap = {}
		MODULES.each_pair { |filename, m|
			klass = Einarc.const_get(m[:classname])
			cnst = klass.constants
			# Ruby 1.8 vs 1.9 compatibility: klass.constants is a collection
			# that contains Strings in Ruby 1.8 and Symbols in Ruby 1.9, so
			# we'll check both
			if cnst.include?('PCI_IDS') or cnst.include?(:PCI_IDS)
				klass::PCI_IDS.each_value { |ids| @@pcimap[ids] = filename }
			end
		}
		return @@pcimap
	end

	def self.autodetect
		pci = `lspci -mn`
		raise "Error executing 'lspci': autodetection is not possible" if $?.exitstatus != 0

		res = []
		pci.split("\n").each { |l|
			raise "Unable to parse lspci line #{l.inspect}: autodetection is not possible" unless l =~ /^(.*?) "(.*?)" "(.*?)" "(.*?)"(.*?)"(.*?)" "(.*?)"$/
			vendor_id = $3
			product_id = $4
#			p [vendor_id, product_id]
			adapter = find_adapter_by_pciid(vendor_id, product_id, $6, $7)
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
