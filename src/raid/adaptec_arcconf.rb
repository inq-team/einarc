module RAID
	class AdaptecArcConf < BaseRaid
		CLI = "#{$EINARC_LIB}/adaptec_arcconf/cli"

		PCI_PRODUCT_IDS = {
			'Adaptec 3805' => ['0285', '02bc'],
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
					num = $1
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
			res['PCI vendor ID'] = '9005'
			res['PCI subvendor ID'] = '9005'
			res['PCI product ID'] = PCI_PRODUCT_IDS[res['Controller Model']][0]
			res['PCI subproduct ID'] = PCI_PRODUCT_IDS[res['Controller Model']][1]
			return res
		end

		def adapter_restart
			run("rescan #{@adapter_num}")
#			restart_module('aacraid')
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
			run("-AdpEventLog -Clear #{@args}")
		end

		def _log_list
			raise NotImplementedError
			seq = where = event_time = nil
			res = []
			run("-AdpEventLog -GetEvents -f /dev/stdout #{@args}").each { |l|
				case l
				when /^seqNum\s*:\s*(.*)$/
					seq = $1.hex
					where = event_time = nil
				when /^Time: (.+?) (.+?) (\d+) (\d+):(\d+):(\d+) (\d+)/
					month = $2.strip
					day = $3
					hour = $4
					minute = $5
					second = $6
					year = $7
					p year, month, day, hour, minute, second
					event_time = Time.local(year, month, day, hour, minute, second)
				when /^Event Description\s*:\s*(.*)$/
					res << {
						:id => seq,
						:time => event_time,
						:where => where,
						:what => $1,
					}
				end
			}
			return res
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
#				when /^ ? ?(\d+)\s*(.......)(.......)(....)(.......)(........)(.......)(..............)/
#					num = $1.to_i
#					state = $6.strip.downcase
#					state = 'normal' if state == 'valid'
#					ld = @logical[num] = {
#						:num => num,
#						:physical => [],
#						:capacity => textual2mb($3.strip),
#						:physical => [ cidl2physical($7.strip) ],
#						:raid_level => case $2.strip
#						when 'Volume' then 'linear'
#						when 'Stripe' then 0
#						when 'Mirror' then 1
#						when 'RAID-5' then 5
#						end,
#						:state => state,
#					}
#				when /^ ? ?\/dev\/(.............)...\s+(\S+)\s+(.*?)/
#					ld[:dev] = $1.strip
#					ld[:physical] << cidl2physical($2)
#				when /^ ? ?\/dev\/(\S*)/
#					ld[:dev] = $1
#				when /^\s+(\d+:\d+:\d+)/
#					ld[:physical] << cidl2physical($1)
#				when /^Size\s*:\s*(\d+)MB$/
#					ld[:capacity] = $1.to_i
#				when /^State\s*:\s*(.*?)$/
#					state = $1.downcase
#					state = 'normal' if state == 'optimal'
#					ld[:state] = state
#				when /^Stripe Size: (\d+)kB$/
#					ld[:stripe] = $1.to_i
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

			cmd = "create #{@adapter_num} logicaldrive #{opt_cmd}"
			sizes.each { |s|
				raid_level = 'volume' if raid_level == 'linear'
				cmd += s ? s.to_s : 'MAX'
				cmd += " #{raid_level} "
				cmd += discs.join(' ').gsub(/:/, ',')
				cmd += ' noprompt'

#				case raid_level
#				when 'linear'
#					if s
#						one_size = coerced_size(s / discs.size)
#						cmd += discs.collect { |d| "(#{physical2adaptec(d)},#{one_size}K)" }.join(' ')
#					else
#						cmd += discs.collect { |d| "(#{physical2adaptec(d)})" }.join(' ')
#					end
#				when '0'
#					cmd = 'container create stripe ' + opt_cmd
#					if s
#						one_size = coerced_size(s / (discs.size - 1))
#						cmd += "(#{physical2adaptec(discs.shift)},#{one_size}K) "
#					else
#						cmd += "(#{physical2adaptec(discs.shift)}) "
#					end
#					cmd += discs.collect { |d| physical2adaptec(d) }.join(' ')
#				when '1'
#					one_size = (s ? ",#{s.to_i}M" : '')
#					out = run("container create volume #{opt_cmd} (#{physical2adaptec(discs[0])}#{one_size})")
#					raise Error.new('Unable to find first volume just created') unless out[-1] =~ /Container (\d+) created/
#					cmd = "container create mirror #{$1} #{physical2adaptec(discs[1])}"
#				when '5'
#					cmd = 'container create raid5 ' + opt_cmd
#					if s
#						one_size = coerced_size(s / (discs.size - 1))
#						cmd += "(#{physical2adaptec(discs.shift)},#{one_size}K) "
#					else
#						cmd += "(#{physical2adaptec(discs.shift)}) "
#					end
#					cmd += discs.collect { |d| physical2adaptec(d) }.join(' ')
#				else
#					raise Error.new("Unsupported RAID level: \"#{raid_level}\"")
#				end
				p cmd
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
			chn = nil
			dev = nil
			phys = nil
			run("getconfig #{@adapter_num} pd").each { |l|
				case l
				when /Channel #(\d+):/
					chn = $1.to_i
				when /Device #(\d+)/
					phys = {}
				when /Reported Channel,Device\s*:\s*(\d+),(\d+)/
					@physical["#{$1}:#{$2}"] = phys
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
				when /Serial number\s*:\s*(.*)$/
					phys[:serial] = $1
				end
			}

			# Determine related LDs
			_logical_list.each_with_index { |l, i|
				l[:physical].each { |pd|
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
			l = run("-AdpGetProp AlarmDsply #{@args}").join("\n")
			return (case l
				when /Alarm status is Enabled/  then 'enable'
				when /Alarm status is Disabled/ then 'disable'
			end)
		end

		def get_adapter_rebuildrate(x = nil)
			raise NotImplemented
		end

		def get_adapter_coercion(x = nil)
			raise NotImplemented
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

		# ======================================================================

		def firmware_read(filename)
			raise NotImplementedError
		end

		def firmware_write(filename)
			raise NotImplementedError
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

		# Calculates coerced size: kB measurement, 64kB alignment
		def coerced_size(mb)
			(mb * 1024 / 64).to_i * 64
		end
	end
end
