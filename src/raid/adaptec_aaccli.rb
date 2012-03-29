module RAID
	class AdaptecAacCli < BaseRaid
		AACCLI = "#{$EINARC_LIB}/adaptec_aaccli/cli"

		def initialize(adapter_num = nil)
			super()
			@adapter_num = adapter_num ? adapter_num : 0
		end

		# ======================================================================

		def self.query(res)
			run('controller list').each { |l|
				if l =~ /^aac(\d+)\s+(...................)/
					num = $1.to_i
					model = $2.strip
					res << {
						:driver => 'adaptec_aaccli',
						:num => num,
						:model => model,
						:version => '',
					} if run("open aac#{num}").grep(/Command Error/).empty? # supported by aaccli
				end
			}
			return res
		end

		# ======================================================================

		def _adapter_info
			res = {}
			run('controller details').each { |l|
				res[$1] = $2 if l =~ /^(.*?)\s*:\s*(.*?)$/
			}
			s = run('diagnostic dump text').grep(/ATUVID/)[0]
			res['PCI vendor ID'] = s.gsub( /^.*ATUVID\s*([0-9A-F]*)[\s]*ATUDID[\s]*([0-9A-F]*).*$/, '\1')
			res['PCI product ID'] = s.gsub( /^.*ATUVID\s*([0-9A-F]*)[\s]*ATUDID[\s]*([0-9A-F]*).*$/, '\2')
			return res
		end

		def adapter_restart
			restart_module('aacraid')
		end

		# ======================================================================

		def _task_list
			res = []
			run('task list').each { |t|
#TaskId Function  Done%  Container State Specific1 Specific2
#------ -------- ------- --------- ----- --------- ---------
#  106   Bld/Vfy   0.0%      1      RUN   00000000  00000000
				if t =~ /^\s*(\d+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)/
					res << {
						:id => $1.to_i,
						:where => $4,
						:what => $2,
						:progress => $3,
					}
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

		def _logical_list
			@logical = []
			ld = nil
			run('container list /full').each { |l|
				case l
				when ''
					ld = nil
#Label Type   Size   Ctr Size   Usage   C:ID:L Offset:Size   State   RO Lk Task    Done%  Ent Date   Time
#----- ------ ------ --- ------ ------- ------ ------------- ------- -- -- ------- ------ --- ------ --------
# 0    Volume 10.0GB            Valid   1:01:0 64.0KB:10.0GB                               0  062607 13:23:10
# /dev/sdb                              1:02:0 64.0KB:15.0GB                               1  062607 13:37:59
#                                       1:03:0 64.0KB:15.0GB                               2  062607 13:37:59

#Num          Total  Oth Stripe          Scsi   Partition                                      Creation
#Label Type   Size   Ctr Size   Usage   C:ID:L Offset:Size   State   RO Lk Task    Done%  Ent Date   Time
#----- ------ ------ --- ------ ------- ------ ------------- ------- -- -- ------- ------ --- ------ --------
# 0    Volume 68.4GB            Valid   0:00:0 64.0KB:68.4GB                               0  101807 13:09:58
# /dev/sda             1
				when /^ ? ?(\d+)\s*(.......)(.......)(....)(.......)(........)(.......)(..............)/
					num = $1.to_i
					state = $6.strip.downcase
					state = 'normal' if state == 'valid'
					ld = @logical[num] = {
						:num => num,
						:physical => [],
						:capacity => textual2mb($3.strip),
						:physical => [ cidl2physical($7.strip) ],
						:raid_level => case $2.strip
						when 'Volume' then 'linear'
						when 'Stripe' then 0
						when 'Mirror' then 1
						when 'RAID-5' then 5
						end,
						:state => state,
					}
				when /^ ? ?\/dev\/(.............)...\s+(\S+)\s+(.*?)/
					ld[:dev] = $1.strip
					ld[:physical] << cidl2physical($2)
				when /^ ? ?\/dev\/(\S*)/
					ld[:dev] = $1
				when /^\s+(\d+:\d+:\d+)/
					ld[:physical] << cidl2physical($1)
				end
			}
			return @logical
		end

		def logical_add(raid_level, discs = nil, sizes = nil, options = nil)
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
				sizes.collect! { |s| s.to_f }
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
						when 'stripe' then opt_cmd += "/stripe_size=#{$2}K "
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

			discs_ = discs
			sizes.each { |s|
				discs = discs_.dup
				case raid_level
				when 'linear'
					cmd = 'container create volume ' + opt_cmd
					if s
						one_size = coerced_size(s / discs.size)
						cmd += discs.collect { |d| "(#{physical2adaptec(d)},#{one_size}K)" }.join(' ')
					else
						cmd += discs.collect { |d| "(#{physical2adaptec(d)})" }.join(' ')
					end
				when '0'
					cmd = 'container create stripe ' + opt_cmd
					if s
						one_size = coerced_size(s / (discs.size - 1))
						cmd += "(#{physical2adaptec(discs.shift)},#{one_size}K) "
					else
						cmd += "(#{physical2adaptec(discs.shift)}) "
					end
					cmd += discs.collect { |d| physical2adaptec(d) }.join(' ')
				when '1'
					one_size = (s ? ",#{s.to_i}M" : '')
					out = run("container create volume #{opt_cmd} (#{physical2adaptec(discs[0])}#{one_size})")
					raise Error.new('Unable to find first volume just created') unless out[-1] =~ /Container (\d+) created/
					cmd = "container create mirror #{$1} #{physical2adaptec(discs[1])}"
				when '5'
					cmd = 'container create raid5 ' + opt_cmd
					if s
						one_size = coerced_size(s / (discs.size - 1))
						cmd += "(#{physical2adaptec(discs.shift)},#{one_size}K) "
					else
						cmd += "(#{physical2adaptec(discs.shift)}) "
					end
					cmd += discs.collect { |d| physical2adaptec(d) }.join(' ')
				else
					raise Error.new("Unsupported RAID level: \"#{raid_level}\"")
				end
				run(cmd)
			}

		end

		def logical_delete(id)
			run("container delete /always=true #{id}")
		end

		def logical_clear
			run('task stop /all')
			_logical_list.each_with_index { |l, i|
				next unless l
				logical_delete(i)
			}
		end

		def _physical_list
			@physical = {}
			run('disk list /full:disk show partition').each { |l|
				if l =~ /^(\d+):(\d+):(\d+)\s*.................................(..........)(..................)(......)\s*(\d+)\s+(\d+)\s+(.*?)\s+/
					@physical["#{$1.to_i}:#{$2.to_i}"] = {
						:model => $4.strip + ' ' + $5.strip,
						:revision => $6.strip,
						:size => $7.to_i * $8.to_i / (1024 * 1024),
						:state => $9.downcase,
					}
				end

#C:ID:L  Device Type     Removable media  Vendor-ID Product-ID        Rev   Blocks    Bytes/Block Usage            Shared Rate
#------  --------------  ---------------  --------- ----------------  ----- --------- ----------- ---------------- ------ ----
#Disk            N                HITACHI   HUS103073FL3800   SA1B  143374805 512         Initialized      NO     320

			}

			# Determine related LDs
			_logical_list.each_with_index { |l, i|
				l[:physical].each { |pd|
					if physical[pd][:state].is_a?(Array)
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

		def set_physical_hotspare_0(drv)
			raise NotImplemented
		end

		def set_physical_hotspare_1(drv)
			raise NotImplemented
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
			raise NotImplementedError
		end
		
		# ======================================================================

		private

		def run(command, check = true)
			out = `#{AACCLI} 'open aac#{@adapter_num}:#{command}'`.split("\n")
			out.slice!(0..6)
			if check
				out.each { |l|
					raise Error.new($1) if l =~ /^Command Error: <(.*?)>$/
					raise Error.new(out.join("\n").strip) if l =~ /^Parsing Error: <(.*?)>$/
				}
			end
			return out
		end

		def self.run(command)
			`#{AACCLI} '#{command}'`.split("\n").collect { |l| l.strip }
		end

		def textual2mb(textual)
			res = textual.to_f
			case textual
			when /GB$/ then res *= 1024
			when /MB$/ then ;
			when /KB$/ then res /= 1024
			else raise Error.new("Unparseable size specification: \"#{textual}\"")
			end
			return res
		end

		def cidl2physical(cidl)
			if cidl =~ /^(\d+):(\d+):(\d+)$/
				"#{$1.to_i}:#{$2.to_i}"
			else
				raise Error.new("Unparseable SCSI specification: \"#{cidl}\"")
			end
		end

		def physical2adaptec(phys)
			if phys =~ /^(\d+):(\d+)$/
				"(#{$1.to_i},#{$2.to_i})"
			else
				raise Error.new("Unparseable physical disc specification: \"#{phys}\"")
			end			
		end

		# Calculates coerced size: kB measurement, 64kB alignment
		def coerced_size(mb)
			(mb * 1024 / 64).to_i * 64
		end
	end
end
