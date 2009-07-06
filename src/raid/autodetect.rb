require 'raid/baseraid'

module RAID
	def self.autodetect
		pci = `lspci -mn`
		raise "Error executing 'lspci': autodetection is not possible" if $?.exitstatus != 0

		res = []
		pci.split("\n").each { |l|
			next unless l =~ /^(.*?) "(.*?)" "(.*?)" "(.*?)"(.*?)"(.*?)" "(.*?)"$/
			vendor_id = $3
			product_id = $4
#			p [vendor_id, product_id]
			adapter = BaseRaid.find_adapter_by_pciid(vendor_id, product_id)
			if adapter
				puts "Detected device supported by \"#{adapter}\" (#{vendor_id}:#{product_id})"
				res << adapter
			end
		}
		res.sort!.uniq!
		return res
	end
end
