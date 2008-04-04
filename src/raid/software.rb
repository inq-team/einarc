module RAID
	class Software < BaseRaid
		def initialize(adapter_num = nil)
			@dev = []
		end

		# ======================================================================

		def self.query(res)
			res << {
				:driver => 'software',
				:num => 0,
				:model => 'Linux software RAID',
				:version => `uname -r`,
			}
			return res
		end

		# ======================================================================

		def _adapter_info
			{}
		end

		def adapter_restart
#			restart_module('megaraid_sas')
		end

		# ======================================================================

		def _task_list
			res = []
			return res
		end

		# ======================================================================

		def log_clear
		end

		def _log_list
			[]
		end

		def _logical_list
			@logical = []
			ld = nil
			File.open('/proc/mdstat', 'r') { |f|
				f.each_line { |l|
					l.chop!
					p l
					case l
					when /^md(\d+)\s*:\s*(\S+)\s*(\S+)\s*(.*)$/
						num = $1.to_i
						state = $2
						raid_level = $3
						phys = parse_physical_string($4)

						state = 'normal' if state == 'active'
						raid_level = $1.to_i if raid_level =~ /raid(\d+)/
						
						ld = @logical[num] = {
							:num => num,
							:dev => "md#{num}",
							:physical => [ phys ],
							:state => state,
							:raid_level => raid_level,
						}
					when /^\s*(\d+) blocks/
						ld[:capacity] = $1.to_i / 1024
					end
				}
			}
			return @logical
		end

		def logical_add(raid_level, discs = nil, sizes = nil, options = nil)
			raise NotImplementedError
		end

		def logical_delete(id)
			raise NotImplementedError
		end

		def logical_clear
			raise NotImplementedError
		end

		def _physical_list
			raise NotImplementedError
		end

		# ======================================================================

		def firmware_read(filename)
			raise NotImplementedError
		end

		def firmware_write(filename)
			raise NotImplementedError
		end

		# ======================================================================

		def get_adapter_raidlevels(x = nil)
			[ '0', '1', '5', '6' ]
		end

		def get_adapter_rebuildrate(x = nil)
			raise NotImplementedError
			# should work tweaking /proc/sys/dev/raid/speed_limit_min
		end

		def set_physical_hotspare_0(drv)
			run("-PDHSP -Rmv -PhysDrv [#{drv}] #{@args}")
		end

		def set_physical_hotspare_1(drv)
			run("-PDHSP -Set -PhysDrv [#{drv}] #{@args}")
		end
		
		def get_logical_stripe(num)
			ld = _logical_list[num.to_i]
			raise Error.new("Unknown logical disc \"#{num}\"") unless ld
			return ld[:stripe]
		end

		private
		def parse_physical_string(str)
			res = []
			str.split(/ /).each { |ph|
				p ph
				res[$2.to_i] = phys_to_scsi($1) if ph =~ /^(.+)\[(\d+)\]$/
			}
			return res
		end

		# Converts physical name (sda) to SCSI enumeration (1:0)
		def phys_to_scsi(name)
			case name
			when /^hd(.)(\d*)$/
				res = "1:#{$1[0] - 'a'[0]}"
				res += ":#{$2}" unless $2.empty?
			when /^sd(.)(\d*)$/
				res = "0:#{$1[0] - 'a'[0]}"
				res += ":#{$2}" unless $2.empty?
			else
				res = name
			end
			return res
		end
	end
end
