module RAID
	class Software < BaseRaid
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
				:version => `uname -r`,
			}
			return res
		end

		# ======================================================================

		def _adapter_info
			res = {}
			res['Controller Name'] = 'Linux software RAID (md)'
			res['RAID Level Supported'] = 'linear, 0, 1, 4, 5, 6, 10, mp, faulty'
			res['Kernel Version'] = `uname -r`
			res['Current Time'] = `date`
			res['mdadm Version'] = `mdadm -V 2>&1`
			return res
		end

		def adapter_restart
			raise NotImplementedError
		end

		# ======================================================================

		def _task_list
			res = []
			lines = File.readlines('/proc/mdstat')
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

		def _log_list
			raise NotImplementedError
		end

		# ======================================================================

		def _logical_list
			@logical = []
			ld = nil
			File.open('/proc/mdstat', 'r') { |f|
				f.each_line { |l|
					l.chop!
					case l
					when /^md(\d+) : (active \S+|inactive) (.+)$/
						num = $1.to_i
						if $2 == 'inactive'
							state = 'inactive'
							raid_level = ''
						elsif $2.split(' ')[0] == 'active'
							state = 'normal'
							raid_level = $2.split(' ')[1]
						end
						phys = parse_physical_string($3)
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

		# ======================================================================

		def logical_add(raid_level, discs = nil, sizes = nil)
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
			
			raise Error.new('Software RAID does not support size setting') if sizes
			
			# If no discs use all free devices
			if discs.empty?
				discs = devices.select{ |d| not raid_member?(d) }
				rise Error.new('No free discs') if discs.empty?
			end

			#linear, raid0, 0, stripe, raid1, 1, mirror, raid4, 4, raid5, 5, raid6, 6, raid10, 10, multipath, mp, faulty
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
			out = `yes | mdadm --create --verbose #{next_raid_device_name} --auto=yes --force --level=#{raid_level} --raid-devices=#{discs.size} #{discs.join(' ')}`
			raise Error.new(out) unless $?.success?
			
			# Refresh lists
			@raids = @devices = nil
		end

		# ======================================================================

		def logical_delete(id)
				# Unmount it first
				`umount -f /dev/md#{id} 2>/dev/null`
				
				# Find all RAIDs
				raid_udis = `hal-find-by-capability --capability storage.linux_raid`.split("\n")
				
				# HAL's UDI of array we want to delete
				udi_to_delete = raid_udis.select{|udi| 
					`hal-get-property --udi #{udi} --key block.device`.chomp ==  "/dev/md#{id}" }[0]
	
				# HACK: Delete UDI from HAL
				`hal-device -r #{udi_to_delete}` unless udi_to_delete.nil?
				
				# Get list of disks
				disks = devices_of("/dev/md#{id}")

				# Stop RAID
				`mdadm -S /dev/md#{id}`
				
				# Remove disks from RAID
				disks.each{|d| `mdadm /dev/md#{id} --remove #{d}` }
				
				# Delete superblocks
				disks.each{|d| `mdadm --zero-superblock #{d}` }
				
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
			# Find all storage hardware from HAL
			udis = `hal-find-by-property  --key storage.drive_type --string disk`.split("\n")
			
			# Find all RAIDs
			excluded_udis = `hal-find-by-capability --capability storage.linux_raid`.split("\n")

			# Remove RAID devices from found hardware list
			for udi in excluded_udis
				udis.delete(udi)
			end
			
			# Resulting hash
			res = {}
			
			# Extracting data from HAL
			for udi in udis
				d = {}
				d[:model] = `hal-get-property --udi #{udi} --key storage.model 2>/dev/null`.chomp
				d[:size] = `hal-get-property --udi #{udi} --key storage.sizel 2>/dev/null`.to_i / 1073741824.0
				d[:serial] = `hal-get-property --udi #{udi} --key storage.seriall 2>/dev/null`.chomp
				d[:revision] = `hal-get-property --udi #{udi} --key storage.firmware_versionl 2>/dev/null`.chomp
				device = `hal-get-property --udi #{udi} --key block.devicel 2>/dev/null`.chomp
				if raid_member?(device)
					if spare?(device)
						d[:state] = 'Spare'
					else
						d[:state] = 'RAID Member'
					end
				else
					d[:state] = 'Free'
				end
				target = phys_to_scsi(device.gsub(/^\/dev\//, ''))
				res[target] = d
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
			return %w{linear, 0, 1, 4, 5, 6, 10, mp, faulty}
		end

		# ======================================================================

		def get_adapter_rebuildrate(x = nil)
			return File.read('/proc/sys/dev/raid/speed_limit_min').chomp
		end

		# ======================================================================

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
			ld = _logical_list[num.to_i]
			raise Error.new("Unknown logical disc \"#{num}\"") unless ld
			return ld[:stripe]
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
			# Find all storage hardware from HAL
			udis = `hal-find-by-property  --key storage.drive_type --string disk`.split("\n")
			
			# Find all RAIDs
			excluded_udis = `hal-find-by-capability --capability storage.linux_raid`.split("\n")

			# Remove RAID devices from found hardware list
			for udi in excluded_udis
				udis.delete(udi)
			end
			
			return dis.map{ |udi| `hal-get-property --udi #{udi} --key block.device`.chomp }
		end
		
		def devices
			@devices ||= list_devices
		end
		
		def raid_member?(device)
			# Delete '/dev/' before device name
			name = device.gsub(/^\/dev\//, '')
			
			# Check name existence in mdstat file
			return (not File.read('/proc/mdstat').grep(Regexp.new(name)).empty?)
		end

		def spare?(device)
			# Delete '/dev/' before device name
			name = device.gsub(/^\/dev\//, '')
			
			# Ex. /dev/sda[0](S)
			return (not File.read('/proc/mdstat').grep(/#{name}\[[^\[]*\]\(S\)/).empty?)
		end
		
		def active?(device)
			# Delete '/dev/' before device name
			name = device.gsub(/^\/dev\//, '')
			
			# Check RAID existence in mdstat file
			return (not File.read('/proc/mdstat').grep(Regexp.new(name)).empty?)
		end
		
		def list_raids
			res = []
			for l in File.readlines('/proc/mdstat')
				# md0 : active raid0 sdb[1] sdc[0]
				res[$1.to_i] = "/dev/md#{$1}" if l =~ /^md(\d+)\s*:\s*\S+\s*\S+\s*.*$/
			end
			return res.compact
		end
		
		def raids
			@raids ||= list_raids
		end
		
		def devices_of(device)
			#md0 : active linear sdc[0]
			md_pattern = Regexp.new("^#{device.gsub(/\/dev\//, '')} : (active \\S+|inactive) (.+)$")
			
			File.read('/proc/mdstat').grep(md_pattern) do
				return $2.split(/\[\d+\](\(S\))? ?/).map{|d| d.gsub('(S)','') }.map{|d| "/dev/#{d}" }
			end
		end
		
		def level_of(device)
			File.read('/proc/mdstat').grep(/#{device.gsub(/\/dev\//, '')} : (active|inactive)\s+(\S+)\s/) do
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
	end
end
