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
			# LSI doesn't support passthrough discs - emulate using RAID0
			raid_level = 0 if raid_level == 'passthrough'

			cmd = "-CfgLdAdd -r#{raid_level} "

			discs = _physical_list.keys unless discs
			cmd += ("[" + (discs.is_a?(Array) ? discs.join(',') : discs) + "]")

			if sizes
				sizes = sizes.split(/,/) if sizes.respond_to?(:split)
				sizes = [sizes] unless sizes.respond_to?(:each)
				sizes.each { |s| cmd += " -sz#{s}" }
			end

			if options
				options = options.split(/,/) if sizes.respond_to?(:split)
				options.each { |o|
					if o =~ /^(.*?)=(.*?)$/
						case $1
						when 'stripe' then cmd += " -strpsz#{$2}"
						else raise Error.new("Unknown option \"#{o}\"")
						end
					else
						raise Error.new("Unable to parse option \"#{o}\"")
					end
				}
			end
			cmd += " #{@args}"

			run(cmd)
		end

		def logical_delete(id)
			run("-CfgLdDel -L#{id} #{@args}")
		end

		def logical_clear
			run("-CfgClr #{@args}")
		end

		def _physical_list
			@physical = {}
			enclosure = nil
			slot = nil
			phys = nil

			run("-pdlist #{@args}").each { |l|
				case l
				when /^Enclosure Device ID:\s*(\d+)$/
					enclosure = $1.to_i
				when /^Slot Number:\s*(\d+)$/
					slot = $1.to_i
					phys = @physical["#{enclosure}:#{slot}"] = {}
				when /^Coerced Size:\s*(\d+)MB/
					phys[:size] = $1.to_i
				when /^Inquiry Data:\s*(.*?)\s+(.*)\s+(\S+?)\s+(\S+?)$/
					phys[:model] = $2
					phys[:revision] = $3
					phys[:serial] = $4
				when /^Firmware state: (.*?)$/
					phys[:state] = $1.downcase
					phys[:state] = 'free' if phys[:state] == 'unconfigured(good)'
				end
			}

			# Determine related LDs
#			_logical_list.each_with_index { |l, i|
#				l[:physical].each { |pd|
#					@physical[pd][:state] << i
#				}
#			}
#			@physical.each_value { |phys|
#				phys[:state] = 'unknown' if phys[:state].empty?
#			}

			return @physical
		end

		# ======================================================================

		def get_adapter_raidlevels(x = nil)
			[ '0', '1', '5', '6' ]
		end

		def get_adapter_alarm(x = nil)
			l = run("-AdpGetProp AlarmDsply #{@args}").join("\n")
			return (case l
				when /Alarm status is Enabled/  then 'enable'
				when /Alarm status is Disabled/ then 'disable'
			end)
		end

		def get_adapter_rebuildrate(x = nil)
			MEGACLI("-GetRbldrate #{@args}")
		end

		def get_adapter_coercion(x = nil)
			l = MEGACLI("-CoercionVu #{@args}")[0]
			return (case l
				when /^Coercion flag OFF/ then 0
				when /^Coercion flag ON/  then 1
			end)
		end

		def set_adapter_alarm_disable(x = nil)
			l = run("-AdpSetProp AlarmDsbl #{@args}").join("\n")
			raise Error.new(l) unless l =~ /success/
		end

		def set_adapter_alarm_enable(x = nil)
			l = run("-AdpSetProp AlarmEnbl #{@args}").join("\n")
			raise Error.new(l) unless l =~ /success/
		end

		def set_adapter_alarm_mute(x = nil)
			l = run("-AdpSetProp AlarmSilence #{@args}").join("\n")
			raise Error.new(l) unless l =~ /success/
		end

		def set_adapter_coercion_0(x)
			MEGACLI("-CoercionOff #{@args}")
		end

		def set_adapter_coercion_1(x)
			MEGACLI("-CoercionOn #{@args}")
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

		def set_logical_readahead_on(id)
			MEGACLI("-cldCfg #{@args} -L#{id} RA")
		end

		def set_logical_readahead_off(id)
			MEGACLI("-cldCfg #{@args} -L#{id} RAN")
		end

		def set_logical_readahead_adaptive(id)
			MEGACLI("-cldCfg #{@args} -L#{id} RAA")
		end

		def set_logical_write_writethrough(id)
			MEGACLI("-cldCfg #{@args} -L#{id} WT")
		end

		def set_logical_write_writeback(id)
			MEGACLI("-cldCfg #{@args} -L#{id} WB")
		end

		def set_logical_io_direct(id)
			MEGACLI("-cldCfg #{@args} -L#{id} DIO")
		end

		def set_logical_io_cache(id)
			MEGACLI("-cldCfg #{@args} -L#{id} CIO")
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
