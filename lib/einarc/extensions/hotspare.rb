module RAID
	module Extensions
		module Hotspare
			def self.included(another)
				if another.ancestors.include? RAID::BaseRaid
					another.class_eval do
						alias_method :original_method_names, :method_names
						alias_method :original_shortcuts, :shortcuts

						def method_names
							unless @method_names_with_hotspare
								@method_names_with_hotspare = original_method_names
								@method_names_with_hotspare['adapter'] += %w(hotspare_add hotspare_delete)
							end
							@method_names_with_hotspare
						end

					end
				end
			end

			def adapter_hotspare_add(phys_name = nil)
				raise Error.new('Object identifier not specified') unless phys_name

				physicals = _physical_list
				phys = physicals[phys_name]
				raise Error.new("Drive not found") unless phys
				raise Error.new("Drive found, but not free") unless phys[:state] == 'free'
				set_physical_hotspare_1 phys_name
			end

			def adapter_hotspare_delete(phys_name = nil)
				raise Error.new('Object identifier not specified') unless phys_name

				physicals = _physical_list
				phys = physicals[phys_name]
				raise Error.new("Drive not found") unless phys
				raise Error.new("Drive found, but is not a hotspare") unless phys[:state] == 'hotspare'
				# try the new hotspare API
				begin
					logicals = _logical_list
					logicals.each do |log|
						lgpds = _logical_physical_list(log[:num])
						if lgpds.find { |pd| pd[:num] == phys_name }
							raise Error.new("Drive found, but is a dedicated hotspare")
						end
					end
				rescue NotImplementedError => e
					# new hotspare API not yet supported
				rescue NoMethodError => e
					# new hotspare API not even heard of
				end
				set_physical_hotspare_0 phys_name
			end
		end
	end
end
