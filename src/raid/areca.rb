require 'pty'
require 'expect'

module RAID
	class Areca < BaseRaid
	
		PCI_PRODUCT_IDS = {
			'ARC-1110' => '1110',
			'ARC-1120' => '1120',
			'ARC-1130' => '1130',
			'ARC-1160' => '1160',
			'ARC-1170' => '1170',
			'ARC-1210' => '1210',
			'ARC-1220' => '1220',
			'ARC-1230' => '1230',
			'ARC-1260' => '1260',
			'ARC-1261' => '1280',
			'ARC-1231' => '1280',
		}
		CLI = "#{$EINARC_LIB}/areca/cli"
		ARECA_PASSWORD = '0000'

		def initialize(adapter_num = nil)
			@adapter_num = adapter_num
			open_cli
		end

		# ======================================================================

		def self.query(res)
			`#{CLI} main`.each_line { |l|
				res << {
					:driver => 'areca',
					:num => $1.to_i,
					:model => $3,
					:version => $2,
				} if l =~ /^Controller#(\d+)\((.*?)\):\s+(.*)/
			}
#			raise Error.new('areca: failed to query adapter list') if $?.exitstatus != 0
		end

		# ======================================================================

#The System Information
#===========================================
#Main Processor     : 500MHz
#CPU ICache Size    : 32KB
#CPU DCache Size    : 32KB
#System Memory      : 256MB/333MHz
#Firmware Version   : V1.39 2006-2-9
#BOOT ROM Version   : V1.39 2006-1-4
#Serial Number      : Yxxxxxxxxxxxxxxx
#Controller Name    : ARC-1160
#Current IP Address : 192.168.10.111
#===========================================
#GuiErrMsg<0x00>: Success.
		def _adapter_info
			res = {}
			run_cli('sys info').each { |l|
				next if l =~ /=======/
				next if l =~ /^The System Information/
				key, value = l.split(/\s+:\s+/)
				key = case key
				when 'Serial Number' then 'Serial number'
				when 'Firmware Version' then 'Firmware version'
				else key
		    end
				res[key] = value
			}
			res['PCI vendor ID'] = '17d3'
			res['PCI product ID'] = PCI_PRODUCT_IDS[res['Controller Name']]
			return res
		end

		def adapter_restart
			begin
				close_cli
				sleep 10
			rescue PTY::ChildExited
			end

			restart_module 'arcmsr'

			# GREYFIX: make several tries to ensure that module
			# restarted successfully and adapter is now available. For
			# now, just sleep and hope it will be up by then.
			sleep 10

			open_cli
		end

		# ======================================================================

		def log_clear
			run_cli 'event clear'
		end

		def _log_list
			n = 0
			res = []
			run_cli('event info').each { |l|
				if l =~ /^(\d+)-(\d+)-(\d+)\s+(\d+):(\d+):(\d+)\s+(....................)(.*)/
					res << {
						:id => n,
						:time => Time.local($1, $2, $3, $4, $5, $6),
						:where => $7.strip,
						:what => $8,
					}
					n += 1
				end
			}
			return res
		end

		# ======================================================================

		def _task_list
			res = []
			@volumesets = @raidsets = nil
			volumesets.each { |vs|
				next unless vs
				next unless vs[:state] =~ /initializ/
				res << {
					:where => vs[:num],
					:what => vs[:state],
					:progress => vs[:progress],
				}
			}
			return res
		end

		# ======================================================================

		def _physical_list
			res = {}
			run_cli('disk info').each do |l|
				if l =~ /^ +\d+ +(\d+) +(\S+ +\S+) +(\S+) +(.+) *$/
					num = $1.strip
					target = "0:#{num}"
					d = {
						:model => $2.strip,
						:size => $3.strip,
						:state => $4.strip.downcase,
					}
					next if d[:size].downcase == 'n.a.'
					d[:size] = areca2mb(d[:size].strip.gsub(/GB$/, '').to_i)
#					if d[:state] =~ /raid set # (\d+)/
#						rsnum = $1.to_i
#						d[:state] = []
#						volumesets.each do |vs|
#							next unless vs
#							d[:state] << vs[:num] if vs[:raidset] == rsnum
#						end
#					end
					run_cli("disk info drv=#{num}").each do |dl|
						d[:serial] = $1 if dl =~ /^Serial Number .+: (\S+) +$/
						d[:state] = $1.downcase if dl =~ /^Device State .+: (\S+) *$/
						d[:revision] = $1 if dl =~ /^Firmware Rev\. .+: (\S+) +$/
					end
					res[target] = d
				end
			end
			return res
		end

		# ======================================================================

		def _logical_list
			return volumesets.collect { |vs|
				next unless vs
				raid_level = vs[:raid_level]
				if raid_level == '0+1' then
					raid_level = if raidsets[vs[:raidset] + 1][:channels].size % 2 == 0
						(raidsets[vs[:raidset] + 1][:channels].size == 2) ? '1' : '10'
					else
						'1E'
					end
				end
				{
					:num => vs[:num],
					:raid_level => raid_level,
					:physical => raidsets[vs[:raidset] + 1][:channels].collect { |c| "0:#{c}" },
					:capacity => areca2mb(vs[:capacity]),
					:state => vs[:state],
					:dev => @dev ? @dev[vs[:num] - 1] : nil,
				}
			}.compact
		end

		def logical_add(raid_level, discs, sizes = nil, options = nil)
			# Parse physical discs
			discs = discs.split(/,/) if discs.respond_to?(:split)
			discs.collect! { |d| physical2cli(d) }
			discs.sort! { |a, b| a <=> b }
			case raid_level.downcase
			when 'passthrough'
				# Creating passthrough disc
				raise Error.new('Passthrough requires exactly 1 physical disc') unless discs.size == 1
				raise Error.new('Disc sizes not required for passthrougth') if sizes
				enter_password
				run_cli("disk create drv=#{discs}", 'while creating passthrough disc')
				@volumesets = @raidsets = nil
				return
			when '1'
				raise Error.new('RAID 1 requires exactly 2 discs') unless discs.size == 2
			when '1e'
				raise Error.new('RAID 1E requires more than 2 discs') unless discs.size > 2
				raid_level = '1'
			when '10'
				raise Error.new('RAID 10 requires even number of discs >= 4') unless (discs.size > 2) and (discs.size % 2 == 0)
				raid_level = '1'
			end

			# Creating normal RAID array

			# Step 1: get raidset by a list of discs; if it does not exist - create it
			raidset = find_raidset(discs)

			# No good raidset found, we have to create it
			unless raidset
				enter_password
				run_cli("rsf create drv=#{discs.join(',')}", 'while preparing raidset')
				@raidsets = nil
				raidset = find_raidset(discs)
				raise Error.new('Unable to find created raidset after creation') unless raidset
			end

			# Step 2: create volumesets in designated raidset
			sizes = sizes.split(/,/) if sizes.respond_to?(:split)
			sizes = [sizes] unless sizes.respond_to?(:each)
			sizes.each { |s|
				enter_password
				s ? (size = s) : (size = raidsets[raidset][:freecap])
				run_cli("vsf create raid=#{raidset} capacity=#{size} level=#{raid_level}", 'while creating volumeset')
			}
			@volumesets = @raidsets = nil
		end

		def logical_delete(id)
			enter_password
			begin
				msg = run_cli("vsf delete vol=#{id}")
			rescue Error => e
				if e.text =~ /VolumeSet Type Is PassThrough/
					run_cli("disk delete drv=#{id}")
				else
					raise e
				end				
			end
			@raidsets = @volumesets = nil
			cleanup_raidsets
		end

		def logical_clear
			volumesets.each { |vs|
				next unless vs
				enter_password
				run_cli(
					if vs[:raid_level] == 'passthrough'
						"disk delete drv=#{raidsets[vs[:raidset] + 1][:channels][0]}"
					else
						"vsf delete vol=1"
					end,
					'while deleting volumesets',
					false					
				)
			}
			@raidsets = @volumesets = nil
			cleanup_raidsets

			return $?
		end

		# ======================================================================
		# Properties management

		def get_adapter_raidlevels(x = nil)
			[ '0', '1', '1E', '10', '3', '5', '6' ]
		end

		def set_adapter_alarm_mute(x = nil)
			run_cli 'sys beeper p=0'
		end

		def set_adapter_alarm_disable(x = nil)
			run_cli 'sys beeper p=1'
		end

		def set_adapter_alarm_enable(x = nil)
			run_cli 'sys beeper p=2'
		end

		def get_physical_hotspare(drv)
			(_physical_list[drv][:state] == 'hotspare') ? 1 : 0
		end

		def set_physical_hotspare_0(drv)
			drv = physical2cli(drv)
			enter_password
			run_cli "rsf deletehs drv=#{drv}"
		end

		def set_physical_hotspare_1(drv)
			drv = physical2cli(drv)
			enter_password
			run_cli "rsf createhs drv=#{drv}"
		end

		# ======================================================================
		# Private functions

		def raidsets
			@raidsets ||= list_raidsets
		end

		def volumesets
			@volumesets ||= list_volumesets
		end

		def enter_password
			run_cli("set password=#{ARECA_PASSWORD}", 'Adapter refused our password')
		end

		# #  Name             Disks TotalCap  FreeCap DiskChannels       State
		#===============================================================================
		# 1  Raid Set # 00        1  250.0GB  239.5GB 3                  Normal

		def list_raidsets
			@raidsets = []
			run_cli('rsf info').each { |l|
				next unless m = /^\s*(\d+)\s+(.................)\s*(\d+)\s+(.*?)\s+(.*?)\s+(.*?)\s+(.*?)$/.match(l)
				num = m[1].to_i
				@raidsets[num] = {
					:num => num,
					:name => m[2].strip,
					:disks => m[3],
					:totalcap => m[4].gsub(/GB$/, '').to_f,
					:freecap => m[5].gsub(/GB$/, '').to_f,
					:channels => m[6].split(//).collect { |c|
						c = (c =~ /[A-Z]/) ? (c[0] - 'A'[0] + 10) : (c.to_i)
					}.sort { |a, b| a <=> b },
					:state => m[7],
				}
			}
			return @raidsets;
		end

		# # Name             Raid Name       Level   Capacity Ch/Id/Lun  State
		#===============================================================================
		# 1 ARC-1210-VOL#00  Raid Set # 00   Raid0     10.5GB 00/00/00   Normal

		def list_volumesets
			@volumesets = []
			run_cli('vsf info').each { |l|
				next unless m = /^\s+(\d+)\s+(\S+)\s+Raid Set #\s+(\d+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+).*$/.match(l)
				num = m[1].to_i
				vs = @volumesets[num] = {
					:num => num,
					:name => m[2].strip,
					:raidset => m[3].to_i,
					:raid_level => m[4].gsub(/^Raid/, ''),
					:capacity => m[5].gsub!(/GB$/, '').to_f,
					:addr => m[6],
					:state => m[7].downcase
				}
				vs[:raid_level] = 'passthrough' if vs[:raid_level] == 'PassThr'
				if (vs[:state] =~ /^(.*?)\((.*?)\)$/)
					vs[:progress] = $2;
					vs[:state] = $1;
				end
			}
			return @volumesets;
		end

		def cleanup_raidsets
			raidsets.each { |rs|
				next unless rs
				if rs[:totalcap] == rs[:freecap]
					enter_password
					run_cli("rsf delete raid=#{rs[:num]}", 'while cleaning up raidsets')
				end
			}
			@volumesets = @raidsets = nil
		end

		# Finds a suitable raidset by physical discs enclosure
		def find_raidset(discs)
			res = nil
			raidsets.each { |rs|
				next unless rs
				res = rs[:num] if rs[:channels] == discs
			}
			return res;
		end

		# Converts Areca size (GB) into our standard MB
		def areca2mb(x)
			x * 1000000000.0 / 1048576.0
		end

		# Converts our standard MB into Areca size (GB)
		def mb2areca(x)
			x * 1048576.0 / 1000000000.0
		end

		# Converts physical notation "b:t" into physical drive number used by cli
		def physical2cli(d)
			raise Error.new("Invalid physical disc ID: \"#{d}\". Use channel:device format.") unless d =~ /(\d+):(\d+)/
			raise Error.new('Invalid channel number') unless $1 == '0'
			return $2.to_i
		end

		# ======================================================================

		def firmware_read(filename)
			raise NotImplementedError
		end

		def firmware_write(*filename)
			filename.each { |file|
				raise Error.new("There is no firmware file: \"#{file}\".") unless File.exist?(file)
				run_cli("sys updatefw path=#{file}")
			}
		end

		# ======================================================================

		# Runs trivial Areca command; raises an exception if it exists improperly
		def self.run(cmd)
			msg = `#{CLI} #{cmd}`
			raise Error.new(msg) if $?.exitstatus != 0
			return msg
		end

		# Runs trivial Areca command in CLI; raises an exception if it exists improperly.
		# Method assumes that CLI is in ready state, waiting on the prompt.
		def run(cmd)
			@cli_w.puts cmd
			msg, prompt = @cli_r.expect(/^(CLI> )/)
# GREYFIX: parse error message and raise
#			raise Error.new(msg) if $?.exitstatus != 0
			return msg
		end

		# Runs Areca command in CLI; raises an expection with
		# additional "errmsg" if it fails.
		# "retry" - if true, retry several times if RS-232 error
		# occurs. Recommended for idempotent commands.
		# Returns array of parsed strings of output.
		def run_cli(cmd, errmsg_add = 'areca: ', retry_ = true)
			tries = retry_ ? 5 : 0
			begin
				@cli_w.puts cmd
				msg, prompt = @cli_r.expect(/^(CLI> )/)

				# Cleanup
				lines = msg.split("\n").collect { |l| l.chomp }
				lines.delete_at(0) if lines[0] =~ Regexp.new(Regexp.quote(cmd))
				lines.delete_at(-1) if lines[-1] == 'CLI> '
				lines.delete_at(-1) if lines[-1].empty?

				# Error message
				errmsg = lines.delete_at(-1)
				raise Error.new(errmsg) unless errmsg =~ /GuiErrMsg<0x00>: Success/
			rescue Error => e
				if e.text =~ /Invaild Data Returned/
					tries -= 1
					retry if tries >= 0
				else
					raise Error.new(e.text)
				end
			end

			return lines
		end

		def open_cli
			@cli_r, @cli_w, @cli_pid = PTY.spawn("#{$EINARC_LIB}/areca/cli")
			@cli_w.sync = true

			# Turn on for debugging
#			$expect_verbose = true

			raise Error.new('areca: unable to initialize and get CLI prompt') unless @cli_r.expect(/^(CLI> )/)
			run_cli "set curctrl=#{@adapter_num}" if @adapter_num
		end

		def close_cli
			@cli_w.puts 'exit'
			@cli_w.close
			@cli_r.close
		end
	end
end
