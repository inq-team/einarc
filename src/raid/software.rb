module RAID
	class Software < BaseRaid

		MDSTAT_PATTERN = /^md(\d+)\s:\s( (?:active|inactive) \s* (?:\([^)]*\))? \s* \S+)\s(.+)$/x
		MDSTAT_LOCATION = '/proc/mdstat'
		 
		def initialize(adapter_num = nil)
			for l in `mdadm --examine --scan`.grep /^ARRAY.+$/
				vars = l.split(' ')
				name = vars[1]
				uuid = vars[4].gsub(/UUID=/, '')
				unless active?(name)
					`mdadm -A -u #{uuid} #{name}`
				end
			end
		end

		# ======================================================================

		def self.query(res)
			res << {
				:driver => 'software',
				:num => 0,
				:model => 'Linux software RAID',
				:version => `uname -r`.chomp
			}
			return res
		end

		# ======================================================================

		def _adapter_info
			res = {}
			res['Controller Name'] = 'Linux software RAID (md)'
			res['RAID Level Supported'] = '0, 1, 5, 6, 10'
			res['Kernel Version'] = `uname -r`.chomp
			res['mdadm Version'] = `mdadm -V 2>&1`.chomp
			return res
		end

		def adapter_restart
			raise NotImplementedError
		end

		# ======================================================================

		def _task_list
			res = []
			lines = File.readlines(MDSTAT_LOCATION)
			lines.each_with_index do |l, i|
				if l =~ /^\s+\[.*\]\s+(\S+)\s+=\s+(\S+)%.*/
					res << {
						:id => res.size,
						:what => $1,
						:progress => $2,
						:where => lines[i - 2].gsub(/ : .+/, '').chomp,
					}
				end
			end
			return res
		end

		# ======================================================================

		def log_clear
			raise NotImplementedError
		end

		def _log_discover
			[]
		end

		def _log_list
			raise NotImplementedError
		end

		# ======================================================================

		def _logical_list
			@logical = []
			ld = nil
			File.open(MDSTAT_LOCATION, 'r') { |f|
				f.each_line { |l|
					l.chop!
					if l =~ /(\d+)k chunk/
						ld[:stripe] = $1.to_i
					end
					case l
					when  MDSTAT_PATTERN
						num = $1.to_i
						spl = $2.split(' ')
						if spl.first == 'inactive'
							state = 'inactive'
							raid_level = ''
						elsif spl.first == 'active'
							state = 'normal'
							raid_level = spl.last
						end
						phys = parse_physical_string($3)
						raid_level = $1 if raid_level =~ /raid(\d+)/
						
						ld = {
							:num => num,
							:dev => "/dev/md#{num}",
							:physical => phys,
							:state => state,
							:raid_level => raid_level,
						}
						@logical << ld
					when /^\s*(\d+) blocks/
						ld[:capacity] = $1.to_i / 1024.0
					when /resync=PENDING/
						ld[:state] = "initializing"
					when /resync = ([0-9\.\%]+)/
						ld[:state] = "initializing"
					when /recovery = ([0-9\.\%]+)/
						ld[:state] = "rebuilding"
					end
				}
			}
			return @logical
		end

		# ======================================================================

		def logical_add(raid_level, discs = nil, sizes = nil, options = nil)
			# Normalize arguments: "discs" and "sizes" are an array, "raid_level" is a string
			if discs
				discs = discs.split(/,/) if discs.respond_to?(:split)
				discs = [discs] unless discs.respond_to?(:each)
			end
			raid_level = raid_level.to_s
			
			# Replace SCSI enumerations by devices
			discs.map!{ |d| scsi_to_device(d) }
			
			# Check if discs are already RAID members
			for d in discs
				raise Error.new("Device #{d} is already in RAID") if raid_member?(d)
			end

			if sizes
				raise Error.new('Software RAID does not support multiple arrays on the same devices creation') if sizes.split(/,/).length > 1
				sizes = (sizes.to_i * 1024).to_s
			else
				sizes = "max"
			end

			# Options are all the same for all commands, pre-parse them
			opt_cmd = ''
			if options
				options = options.split(/,/) if sizes.respond_to?(:split)
				options.each { |o|
					if o =~ /^(.*?)=(.*?)$/
						case $1
						when 'stripe' then opt_cmd += "--chunk #{$2} "
						else raise Error.new("Unknown option \"#{o}\"")
						end
					else
						raise Error.new("Unable to parse option \"#{o}\"")
					end
				}
			end

			# If no discs use all free devices
			if discs.empty?
				discs = devices.select{ |d| not raid_member?(d) }
				rise Error.new('No free discs') if discs.empty?
			end

			#raid0, 0, stripe, raid1, 1, mirror, raid5, 5, raid6, 6, raid10, 10
			case raid_level.downcase
			when 'passthrough'
				raise Error.new('Passthrough requires exactly 1 physical disc') unless discs.size == 1
				raid_level = 'linear'
			when '5'
				raise Error.new('RAID 5 requires 3 or more discs') unless discs.size > 2
			end
			
			# Unmount all devices
			discs.each{ |d| `umount -f "#{d}" 2>/dev/null` }
			
			# Creat RAID using mdadm
			out = `yes | mdadm --create --verbose #{next_raid_device_name} --auto=yes --size=#{sizes} #{opt_cmd} --force --level=#{raid_level} --raid-devices=#{discs.size} #{discs.join(' ')}`
			raise Error.new(out) unless $?.success?

			# Refresh lists
			@raids = @devices = nil
		end

		# ======================================================================

		def logical_delete(id)
				# Unmount it first
				`umount -f /dev/md#{id} 2>/dev/null`
				
				# Get list of disks
				disks = devices_of("/dev/md#{id}")

				# Stop RAID
				`mdadm -S /dev/md#{id}`
				
				# Remove disks from RAID and zero superblocks
				disks.each{ |d|
					`mdadm /dev/md#{id} --remove #{d}`
					`mdadm --zero-superblock #{d}`
				}
				
				# Refresh lists
				@raids = @devices = nil
		end

		# ======================================================================

		def logical_clear
			# Consistently delete all devices
			raids.each{|r| logical_delete(r.gsub(/\/dev\/md/, '')) }
			
			# Refresh lists
			@raids = @devices = nil
		end

		# ======================================================================

		def _physical_list
			# Resulting hash
			res = {}
			
			# Extracting data from HAL
			for device in list_devices
				target = phys_to_scsi(device.gsub(/^\/dev\//, ''))
				d = {}
				d[:model] = physical_read_file(device, "device/model") or ""
				d[:revision] = physical_read_file(device, "device/rev") or ""
				d[:serial] = physical_read_file(device, "device/serial") or ""
				d[:size] = physical_read_file(device, "size") or 0
				d[:size] = d[:size].to_f * 512 / 1048576

				if raid_member?(device)
					d[:state] = 'hotspare' if spare?(device)
				else
					d[:state] = 'free'
				end
				res[target] = d
			end
		
			_logical_list.each do |logical|
				logical[:physical].each do |target|
					next if res[target][:state] == 'hotspare'
					if res[target][:state].is_a? Array
						res[target][:state] << logical[:num]
					else
						res[target][:state] = [ logical[:num] ]
					end
				end
			end
			res.each do |k, v|
				v[:state] = 'unknown' if v[:state].empty?
			end

			return res
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
			return %w{linear passthrough 0 1 5 6 10}
		end

		# ======================================================================

		def get_adapter_rebuildrate(x = nil)
			return File.read('/proc/sys/dev/raid/speed_limit_min').chomp
		end

		# ======================================================================

		def get_physical_hotspare(drv)
			(_physical_list[drv][:state] == 'hotspare') ? 1 : 0
		end

		def set_physical_hotspare_0(drv)
			raise Error.new("Device #{drv} is not hotspare") unless spare?(scsi_to_device(drv))
			raids.each { |r| `mdadm #{r} -r #{scsi_to_device(drv)}` }
		end

		def set_physical_hotspare_1(drv)
			raise Error.new("Device #{drv} is already in RAID") if raid_member?(scsi_to_device(drv))
			raids.each { |r| `mdadm #{r} -a #{scsi_to_device(drv)}` unless level_of(r) == '0' }
		end

		# ======================================================================

		def get_logical_stripe(num)
			ld = _logical_list.reject { |logical| logical[:num] != num.to_i }[0]
			raise Error.new("Unknown logical disc \"#{num}\"") unless ld
			return ld[:stripe]
		end

		# ======================================================================

		def _bbu_info
			raise NotImplementedError
		end

		# ======================================================================

		private
		def parse_physical_string(str)
			res = []
			str.split(/ /).each { |ph|
				res[$2.to_i] = phys_to_scsi($1) if ph =~ /^(.+)\[(\d+)\].*$/
			}
			return res.compact
		end
		
		def list_devices
			return File.open("/proc/partitions", "r").collect { |l|
				"/dev/" + $1 if l =~ /^\s+[38]\s+\d+\s+\d+\s+([a-z]+)$/ }.compact
		end
		
		def devices
			@devices ||= list_devices
		end
		
		def raid_member?(device)
			# Delete '/dev/' before device name
			name = device.gsub(/^\/dev\//, '')
			
			# Check name existence in mdstat file
			return (not File.read(MDSTAT_LOCATION).grep(Regexp.new(name)).empty?)
		end

		def spare?(device)
			# Delete '/dev/' before device name
			name = device.gsub(/^\/dev\//, '')
			
			# Ex. sda[0](S)
			return (not File.read(MDSTAT_LOCATION).grep(/#{name}\[[^\[]*\]\(S\)/).empty?)
		end
		
		def active?(device)
			# Delete '/dev/' before device name
			name = device.gsub(/^\/dev\//, '')
			
			# Check RAID existence in mdstat file
			return (not File.read(MDSTAT_LOCATION).grep(Regexp.new(name)).empty?)
		end
		
		def list_raids
			res = []
			for l in File.readlines(MDSTAT_LOCATION)
				# md0 : active raid0 sdb[1] sdc[0]
				res[$1.to_i] = "/dev/md#{$1}" if l =~ MDSTAT_PATTERN
			end
			return res.compact
		end
		
		def raids
			@raids ||= list_raids
		end
		
		def devices_of(device)
			#md0 : active linear sdc[0]
			File.read(MDSTAT_LOCATION).grep(%r[^#{device.gsub(/\/dev\//, '') }]).grep(MDSTAT_PATTERN) do
				return $3.split(/\[\d+\](\(S\))? ?/).map{|d| d.gsub('(S)','') }.map{|d| "/dev/#{d}" }
			end
		end
		
		def level_of(device)
			File.read(MDSTAT_LOCATION).grep(%r[^#{device.gsub(/\/dev\//, '') }]).grep(MDSTAT_PATTERN) do
				return $2.map{|l| l.gsub('raid','') }[0]
			end			
		end
		
		# Returns next free name for md device
		def next_raid_device_name
			last_id = raids.map{ |dev| dev.gsub(/\/dev\/md/, '').to_i }.sort[-1]
			return last_id.nil? ? "/dev/md0" : "/dev/md#{last_id + 1}"
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
		
		# Converts SCSI enumeration to physical device name
		def scsi_to_device(id)
			parts = id.split(':')
			res = "/dev/hd" if parts[0] == '1'
			res = "/dev/sd" if parts[0] == '0'
			res += ('a'[0] + parts[1].to_i).chr
			res += parts[2].to_s if parts.size == 3
			return res
		end

		def physical_read_file(device, source)
			begin
				return File.open("/sys/block/#{device.gsub(/^\/dev\//, '')}/#{source}", "r").readline.chop
			rescue Errno::ENOENT
				return nil
			end
		end
	end
end
