require 'raid/extensions/hotspare'

module RAID
	class AdaptecArcConf < BaseRaid

		include Extensions::Hotspare

		CLI = "#{$EINARC_LIB}/adaptec_arcconf/cli"

		PCI_IDS = {
			'Adaptec 3805'  => ['9005', '0285', '9005', '02bc'],
			'Adaptec 5805'  => ['9005', '0285', '9005', '02b6'],
			'Adaptec 5805Z' => ['9005', '0285', '9005', '02da'],
			'Adaptec 51645' => ['9005', '0285', '9005', '02cf'],
			'Adaptec 2230S' => ['9005', '0286', '9005', '028c'],
			'Adaptec 5405'  => ['9005', '0285', '9005', '02d1'],
			'Adaptec 5405Z' => ['9005', '0285', '9005', '02d8'],
			'Adaptec 2405'  => ['9005', '0285', '9005', '02d5'],
			'Adaptec 6405'  => ['9005', '028b', '9005', '0300'],
		}

		def initialize(adapter_num = nil)
			super()
			@adapter_num = adapter_num ? adapter_num : 1
		end

		# ======================================================================

		def self.query(res)
			run('getversion').each { |vl|
				if vl =~ /^Controller #(\d+)$/
					num = $1.to_i
					model = '[unknown]'
					version = '[unknown]'
					run("getconfig #{num} ad").each { |cl|
						if cl =~ /Controller Model\s*:\s*(.*)$/
							model = $1
						end
						version = $1 if cl =~ /Firmware\s*:\s*(.*)$/
					}
					res << {
						:driver => 'adaptec_arcconf',
						:num => num,
						:model => model,
						:version => version,
					}
				end
			}
			return res
		end

		# ======================================================================

		def _adapter_info
			res = {}
			run("getconfig #{@adapter_num} ad").each { |l|
				if l =~ /^(.*?)\s*:\s*(.*?)$/
					value = $2
					key = $1
					key = case key
					when 'Controller Serial Number' then 'Serial number'
					when 'Firmware' then 'Firmware version'
					when 'Status' then 'BBU'
					else key
					end
					res[key] = value
				end
			}
			res['PCI vendor ID'], res['PCI product ID'], res['PCI subvendor ID'], res['PCI subproduct ID'] = PCI_IDS[res['Controller Model']]
			return res
		end

		def adapter_restart
			run("rescan #{@adapter_num}")
			restart_module('aacraid')
		end

		# ======================================================================

#Controllers found: 1
#Logical device Task:
#   Logical device                 : 0
#   Task ID                        : 101
#   Current operation              : Build/Verify
#   Status                         : In Progress
#   Priority                       : High
#   Percentage complete            : 0
		def _task_list
			res = []
			task = {}
			run("getstatus #{@adapter_num}").each { |t|
				case t
				when /Logical device Task:/
					task = {}
					res << task
				when /Task ID\s*:\s(\d+)$/
					task[:id] = $1.to_i
				when /Logical device\s*:\s*(\d+)/
					task[:where] = $1
				when /Current operation\s*:\s*(.*)$/
					task[:what] = $1
				when /Percentage complete\s*:\s*(\d+)/
					task[:progress] = $1.to_i
				end
			}
			return res
		end

		# ======================================================================

		def _log_clear(subsys)
			run("getlogs #{@adapter_num} #{subsys} clear")
		end

		def _log_discover
			[ 'device', 'dead', 'event', 'ppi' ]
		end

		def _log_dump(subsys)
			# Silently skip PPI log dump, as it can only be cleared
			return "" if subsys == "ppi"

			parsed_log = ""
			run("getlogs #{@adapter_num} #{subsys}").each{ |l|
				next if (l =~ /^Controllers found/ or l =~ /^Command completed successfully/ or l=~ /^$/)
				parsed_log << l
			}
			return parsed_log
		end

		def _log_list
			raise NotImplementedError
		end

#Logical device number 0
#   Logical device name                      : 1
#   RAID level                               : Simple_volume
#   Status of logical device                 : Optimal
#   Size                                     : 69989 MB
#   Read-cache mode                          : Enabled
#   Write-cache mode                         : Disabled (write-through)
#   Write-cache setting                      : Disabled (write-through)
#   Partitioned                              : No
#   Protected by Hot-Spare                   : No
#   Bootable                                 : Yes
#   Failed stripes                           : No
#   --------------------------------------------------------
#   Logical device segment information
#   --------------------------------------------------------
#   Segment 0                                : Present (0,2) DAL0P7605RJ5
		def _logical_list
			@logical = []
			ld = nil
			run("getconfig #{@adapter_num} ld").each { |l|
				case l
				when /Logical device number (\d+)/
					num = $1.to_i
					ld = @logical[num] = {
						:num => num,
						:physical => [],
					}
				when /Size\s*:\s*(\d+) MB/
					ld[:capacity] = $1.to_i
				when /RAID level\s*:\s*(.*)$/
					ld[:raid_level] = $1.strip
					ld[:raid_level] = case ld[:raid_level]
					when 'Simple_volume', 'Spanned_volume' then 'linear'
					else ld[:raid_level]
					end
				when /Segment (\d+)\s*:\s*(.*?) \((\d+),(\d+)\)/
					ld[:physical] << "#{$3}:#{$4}"
				when /Dedicated Hot-Spare\s*:\s*(\d+),(\d+)/
					ld[:physical] << "#{$1}:#{$2}"
				when /Status of logical device\s+:\s(.+)$/
					state = $1
					case state
						when /Optimal/
							ld[:state] = "normal"
						when /Impacted/
							ld[:state] = "initializing"
					else
						ld[:state] = state.downcase
					end
				when /^Logical device name +: (.+)$/
					ld[:dev] = find_dev_by_name($1.strip)
				end
			}
			return @logical
		end

		def logical_add(raid_level, discs = nil, sizes = nil, options = nil)
			# Normalize arguments: make "discs" and "sizes" an array, "raid_level" a string
			if discs
				discs = discs.split(/,/) if discs.respond_to?(:split)
				discs = [discs] unless discs.respond_to?(:each)
			else
				discs = _physical_list.keys
			end
			raid_level = raid_level.to_s
			if sizes
				sizes = sizes.split(/,/) if sizes.respond_to?(:split)
				sizes = [sizes] unless sizes.respond_to?(:each)
				sizes.collect! { |s| s.to_i }
			else
				sizes = [ nil ]
			end

			# Options are all the same for all commands, pre-parse them
			opt_cmd = ''
			if options
				options = options.split(/,/) if sizes.respond_to?(:split)
				options.each { |o|
					if o =~ /^(.*?)=(.*?)$/
						case $1
						when 'stripe' then opt_cmd += "Stripesize #{$2} "
						else raise Error.new("Unknown option \"#{o}\"")
						end
					else
						raise Error.new("Unable to parse option \"#{o}\"")
					end
				}
			end

			# Adaptec doesn't support passthrough discs - emulate using "volumes"
			if raid_level == 'passthrough'
				raise Error.new('Passthrough requires exactly 1 physical disc') unless discs.size == 1
				sizes = [ nil ]
				raid_level = 'linear'
			end

			raise Error.new('RAID 1 requires exactly 2 discs') if raid_level == '1' and discs.size != 2

			# Adaptec doesn't support RAID0 on only 1 disc
			raid_level = 'linear' if raid_level == '0' and discs.size == 1

			sizes.each { |s|
				cmd = "create #{@adapter_num} logicaldrive #{opt_cmd}"
				raid_level = 'volume' if raid_level == 'linear'
				cmd += s ? s.to_s : 'MAX'
				cmd += " #{raid_level} "
				cmd += discs.join(' ').gsub(/:/, ',')
				cmd += ' noprompt'

#				TODO: 	port size computation/validation logic
#					from adaptec_aaccli module#r1313,207:241
				run(cmd)
			}

		end

		def logical_delete(id)
			run("delete #{@adapter_num} logicaldrive #{id} noprompt")
		end

		def logical_clear
			run("delete #{@adapter_num} logicaldrive all noprompt", false)
		end


		def logical_hotspare_add(ld, drv)
			run("setstate #{@adapter_num} device #{drv.gsub(":"," ")} hsp logicaldrive #{ld} noprompt")
		end

		def logical_hotspare_delete(ld, drv)
			set_physical_hotspare_0(drv)
		end

		def _logical_physical_list(ld)
			res = []
			_logical_list.select { |l| l[:num] == ld.to_i }[0][:physical].each { |d|
				state = nil
				_physical_list.each_pair { |num, drv|
					state = "hotspare" if drv[:dedicated_to] == ld and num == d
				}
				res.push( { :num => d, :state => state ? state : ld } )
			}
			return res
		end

#      Device #5
#         Device is a Hard drive
#         State                              : Ready
#         Supported                          : Yes
#         Transfer Speed                     : SATA 1.5 Gb/s
#         Reported Channel,Device(T:L)       : 0,5(5:0)
#         Reported Location                  : Enclosure 1, Slot 5
#         Reported ESD(T:L)                  : 2,1(1:0)
#         Vendor                             : 
#         Model                              : ST31000528AS
#         Firmware                           : CC37
#         Serial number                      : 9VP22859
#         Size                               : 953869 MB
#         Write Cache                        : Enabled (write-back)
#         FRU                                : None
#         S.M.A.R.T.                         : No
#         S.M.A.R.T. warnings                : 0
#         Power State                        : Full rpm
#         Supported Power States             : Full rpm,Powered off
#         SSD                                : No
#         MaxIQ Cache Capable                : No
#         MaxIQ Cache Assigned               : No
#         NCQ status                         : Disabled
		def _physical_list
			@physical = {}
			dev = nil
			phys = nil
			hdd = nil
			run("getconfig #{@adapter_num} pd").each { |l|
				case l
				when /Device #(\d+)/
					phys = {}
					hdd = false
				when /Device is a Hard drive/
					hdd = true
				when /Reported Channel,Device\(T:L\)\s*:\s*(\d+),(\d+).*/
					@physical["#{$1}:#{$2}"] = phys if hdd
				when /Vendor\s*:\s*(.*)$/
					phys[:vendor] = $1
				when /Model\s*:\s*(.*)$/
					phys[:model] = [phys[:vendor], $1].join(' ')
				when /Size\s*:\s*(\d+) MB$/
					phys[:size] = $1.to_i
				when /Firmware\s*:\s*(.*)$/
					phys[:revision] = $1
				when /^State\s*:\s*(.*)$/
					phys[:state] = $1.downcase
					phys[:state] = 'free' if phys[:state] == 'ready'
					phys[:state] = 'hotspare' if phys[:state] == 'hot spare'
				when /Serial number\s*:\s*(.*)$/
					phys[:serial] = $1
				when /Dedicated Spare for\s*:\s*logical device\s*(\d+)$/
					phys[:dedicated_to] = $1
				end
			}

			# Determine related LDs
			_logical_list.each_with_index { |l, i|
				next unless l
				l[:physical].each { |pd|
					next if %w{ failed }.include?(@physical[pd][:state])
					next if @physical[pd][:state] == "hotspare"
					if @physical[pd][:state].is_a?(Array)
						@physical[pd][:state] << i
					else
						@physical[pd][:state] = [ i ]
					end
				}
			}

			return @physical
		end

		# ======================================================================

		def get_adapter_raidlevels(x = nil)
			levels = {
				'Adaptec 3805'	=> [ 'linear', 'passthrough', '0', '1', '1E', '5', '5EE', '6', '10', '50', '60' ],
				'Adaptec 5805'	=> [ 'linear', 'passthrough', '0', '1', '1E', '5', '5EE', '6', '10', '50', '60' ],
				'Adaptec 5805Z'	=> [ 'linear', 'passthrough', '0', '1', '1E', '5', '5EE', '6', '10', '50', '60' ],
				'Adaptec 51645'	=> [ 'linear', 'passthrough', '0', '1', '1E', '5', '5EE', '6', '10', '50', '60' ],
				'Adaptec 5405'	=> [ 'linear', 'passthrough', '0', '1', '1E', '5', '5EE', '6', '10', '50', '60' ],
				'Adaptec 2230S'	=> [ 'linear', 'passthrough', '0', '1', '5', '10', '50' ],
				'Adaptec 2405'	=> [ 'linear', 'passthrough', '0', '1', '10' ],
			}
			model = AdaptecArcConf.query( [] )[0][:model]
			return (levels.has_key? model) ? levels[model] : [ 'linear', 'passthrough', '0', '1', '5' ]
		end

		def get_adapter_alarm(x = nil)
			raise NotImplemented
		end

		def get_adapter_rebuildrate(x = nil)
			raise NotImplemented
		end

		def get_adapter_coercion(x = nil)
			raise NotImplemented
		end

		def set_adapter_alarm_disable(x = nil)
			raise NotImplemented
		end

		def set_adapter_alarm_enable(x = nil)
			raise NotImplemented
		end

		def set_adapter_alarm_mute(x = nil)
			raise NotImplemented
		end

		def set_adapter_coercion_0(x)
			raise NotImplemented
		end

		def set_adapter_coercion_1(x)
			raise NotImplemented
		end

		def get_physical_hotspare(drv)
			(_physical_list[drv][:state] == 'hotspare') ? 1 : 0
		end

		def set_physical_hotspare_0(drv)
			run("setstate #{@adapter_num} device #{drv.gsub(":"," ")} rdy noprompt")
		end

		def set_physical_hotspare_1(drv)
			run("setstate #{@adapter_num} device #{drv.gsub(":"," ")} hsp noprompt")
		end
		
		def get_logical_stripe(num)
			ld = _logical_list[num.to_i]
			raise Error.new("Unknown logical disc \"#{num}\"") unless ld
			return ld[:stripe]
		end

		def set_logical_readahead_on(id)
			raise NotImplemented
		end

		def set_logical_readahead_off(id)
			raise NotImplemented
		end

		def set_logical_readahead_adaptive(id)
			raise NotImplemented
		end

		def set_logical_write_writethrough(id)
			raise NotImplemented
		end

		def set_logical_write_writeback(id)
			raise NotImplemented
		end

		def set_logical_io_direct(id)
			raise NotImplemented
		end

		def set_logical_io_cache(id)
			raise NotImplemented
		end

		# ======================================================================

		def firmware_read(filename)
			raise NotImplementedError
		end

		def firmware_write(filename)
			raise NotImplementedError
		end

		# ======================================================================

#--------------------------------------------------------
#Controller Battery Information
#--------------------------------------------------------
#Status                                   : Optimal
#Over temperature                         : No
#Capacity remaining                       : 98 percent
#Time remaining (at current draw)         : 3 days, 0 hours, 31 minutes
		def _bbu_info
			info = {}
			run("getconfig #{@adapter_num} ad").grep(/^Status\s*:\s*(.*?)$/) {
				unless $1 =~ /Not Installed/
					info[:vendor] = 'Adaptec'
					info[:device] = 'BBU'
				end
			}
			return info
		end
		
		# ======================================================================
		
		private

		def run(command, check = true)
			out = `#{CLI} #{command}`.split("\n").collect { |l| l.strip }
			es = $?.exitstatus
			error_msg = out.join("\n")
			error_msg = 'Unknown error' if error_msg.empty?
			raise Error.new(error_msg) if check and es != 0
			return out
		end

		def self.run(command)
			res = `#{CLI} #{command}`.split("\n").collect { |l| l.strip }
			es = $?.exitstatus
			$stderr.puts "Error: " + res.join("\n") if es != 0
			res
		end

	end
end
