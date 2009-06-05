module RAID
	class AdaptecArcConf < BaseRaid
		CLI = "#{$EINARC_LIB}/adaptec_arcconf/cli"

		PCI_IDS = {
			'Adaptec 3805'  => ['9005', '0285', '9005', '02bc'],
			'Adaptec 5805'  => ['9005', '0285', '9005', '02b6'],
			'Adaptec 2230S' => ['9005', '0286', '9005', '028c'],
			'Adaptec 5405'  => ['9005', '0285', '9005', '02d1'],
		}

		def initialize(adapter_num = nil)
			if adapter_num
				@adapter_num = adapter_num
			else
				@adapter_num = 1
			end
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

		def log_clear
			raise NotImplementedError
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

#Controllers found: 1
#----------------------------------------------------------------------
#Physical Device information
#----------------------------------------------------------------------
#   Channel #0:
#      Transfer Speed                        : Ultra320
#      Initiator at SCSI ID 7
#      Device #2
#         Device is a Hard drive
#         State                              : Online
#         Supported                          : Yes
#         Transfer Speed                     : Ultra320
#         Reported Channel,Device            : 0,2
#         Vendor                             : FUJITSU
#         Model                              : MAW3073NC
#         Firmware                           : 0104
#         Serial number                      : DAL0P7605RJ5
#         Size                               : 70136 MB
#         Write Cache                        : Unknown
#         FRU                                : None
#         S.M.A.R.T.                         : No
#   Channel #1:
#      Transfer Speed                        : Ultra320
#      Initiator at SCSI ID 7
#      No physical drives attached
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
				when /Reported Channel,Device\s*:\s*(\d+),(\d+)/
					@physical["#{$1}:#{$2}"] = phys if hdd
				when /Vendor\s*:\s*(.*)$/
					phys[:vendor] = $1
				when /Model\s*:\s*(.*)$/
					phys[:model] = [phys[:vendor], $1].join(' ')
				when /Size\s*:\s*(\d+) MB$/
					phys[:size] = $1.to_i
				when /Firmware\s*:\s*(.*)$/
					phys[:revision] = $1
				when /State\s*:\s*(.*)$/
					phys[:state] = $1.downcase
					phys[:state] = 'free' if phys[:state] == 'ready'
					phys[:state] = 'hotspare' if phys[:state] == 'hot spare'
				when /Serial number\s*:\s*(.*)$/
					phys[:serial] = $1
				end
			}


			# Determine related LDs
			_logical_list.each_with_index { |l, i|
                                next unless l
				l[:physical].each { |pd|
					next if %w{ failed }.include?(@physical[pd][:state])
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
			[ 'linear', '0', '1', '5' ]
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

		def _bbu_info
			for line in run("getconfig #{@adapter_num} ad")
				if line =~ /^Status\s*:\s*(.*?)$/
					status = $1
					break
				end
			end
			info = {}
			if status =~ /Not Installed/				
				info[:vendor] = info[:serial] = info[:capacity] = info[:device] = 'n/a'
			end
			info
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
