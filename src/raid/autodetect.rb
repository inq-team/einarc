require 'raid/baseraid'

RAID::MODULES.each_key { |k, v| require "raid/#{k}" }

module RAID
	def self.autodetect
		pci = `lspci -mn`
		raise "Error executing 'lspci': autodetection is not possible" if $?.exitstatus != 0

		pcimap = {}
		MODULES.each_pair { |filename, m|
			klass = self.const_get(m[:classname])
			if klass.constants.include?('PCI_IDS')
				klass::PCI_IDS.each_value { |ids|
					pcimap[ids] = filename
				}
			else
				$stderr.puts "WARNING: #{m[:classname]} does not supply PCI identifiers"
			end
		}

		res = []
		pci.split("\n").each { |l|
			next unless l =~ /^(.*?) "(.*?)" "(.*?)" "(.*?)" (.*?) "(.*?)" "(.*?)"$/
			vendor_id = $3
			product_id = $4
#			p [vendor_id, product_id]
			m = pcimap[[vendor_id, product_id]]
			if m
				puts "Detected device supported by \"#{m}\" (#{vendor_id}:#{product_id})"
				res << m
			end
		}
		res.sort!.uniq!
		return res
	end
end
