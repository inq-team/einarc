module RAID
	class Software < BaseRaid
		def initialize(adapter_num = nil)
			`mdadm -As 2>/dev/null`
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

		def logical_add(raid_level, discs = nil, sizes = nil)
			# Normalize arguments: make "discs" and "sizes" an array, "raid_level" a string
			if discs
				discs = discs.split(/,/) if discs.respond_to?(:split)
				discs = [discs] unless discs.respond_to?(:each)
			end
			raid_level = raid_level.to_s
			
			# Replace SCSI enumerations by devices
			discs.map!{|d| scsi_to_device(d) }
			
			# Checking disk for free
			for d in discs
				raise Error.new("Device #{d} is allready in RAID") if raid_member?(d)
			end
			
			raise Error.new('Software RAID does not support setting of the sizes') if sizes
			
			# If no discs use all free devices
			if discs.empty?
				discs = devices.select{|d| not raid_member?(d) }
				rise Error.new('No free disks') if discs.empty?
			end
#linear, raid0, 0, stripe, raid1, 1, mirror, raid4, 4, raid5,  5,  raid6, 6,  raid10,  10, multipath, mp, faulty
			case raid_level.downcase
			when 'passthrough'
				# Creating passthrough disc
				raise Error.new('Passthrough requires exactly 1 physical disc') unless discs.size == 1
				raid_level = 'linear'
			when '5'
				raise Error.new('RAID 5 requires more than 3 discs') unless discs.size > 2
			end
			
			# Unmount all devices
			discs.each{|d| `umount "#{d}" 2>/dev/null` }
			
			# Run mdadm command to create RAID
			out = `yes | mdadm --create --verbose #{next_raid_device_name} --auto=yes #{discs.size == 1 ? '--force' : ''} --level=#{raid_level} --raid-devices=#{discs.size} #{discs.join(' ')}`
			raise Error.new(out) unless $?.success?
			
			# Save configuration
			`mdadm --detail --scan > /etc/mdadm.conf`
			
			# Refresh lists
			@raids = @devices = nil
		end

		def logical_delete(id)
				# Unmount
				`umount /dev/md#{id} 2>/dev/null`
				
				# Find udi ofdeleting RAID
				udi = `hal-find-by-property --key block.device --string /dev/md#{id}`.chomp
				
				# HACK: delete udi from hal
				`hal-device -r #{udi}` unless udi.empty?
				
				# Stop RAID
				`mdadm --stop /dev/md#{id}`
				
				# Save config
				`mdadm --detail --scan > /etc/mdadm.conf`
				
				# Refresh lists
				@raids = @devices = nil
		end

		def logical_clear
			for r in raids
				# Unmount
				`umount #{r} 2>/dev/null`
			
				# Find udi of deletin RAID
				udi = `hal-find-by-property --key block.device --string #{r}`.chomp
				
				# HACK: delete udi from hal
				`hal-device -r #{udi}` unless udi.empty?
				
				# Stop RAID
				`mdadm --stop #{r}`
			end
			# Save config
			`cat /dev/null >/etc/mdadm.conf`
			
			# Refresh lists
			@raids = @devices = nil
		end

		def _physical_list
			# Find all storage udis by hal
			udis = `hal-find-by-property  --key storage.drive_type --string disk`.split("\n")
			
			# Find all raid udis
			excluded_udis = `hal-find-by-capability --capability storage.linux_raid`.split("\n")

			# Delete all raid udis from udi list
			for udi in excluded_udis
				udis.delete(udi)
			end
			
			# Resulting hash
			res = {}
			
			# Extracting data from hal
			for udi in udis
				d = {}
				d[:model] = `hal-get-property --udi #{udi} --key storage.model`.chomp
				d[:size] = `hal-get-property --udi #{udi} --key storage.size`.to_i / 1073741824.0
				d[:serial] = `hal-get-property --udi #{udi} --key storage.serial`.chomp
				d[:revision] = `hal-get-property --udi #{udi} --key storage.firmware_version`.chomp
				device = `hal-get-property --udi #{udi} --key block.device`.chomp
				if raid_member?(device)
					d[:state] = 'RAID Member'
				else
					d[:state] = 'Free'
				end
				target = phys_to_scsi(device.gsub(/^\/dev\//, ''))
				res[target] = d
			end
			
			res
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
				res[$2.to_i] = phys_to_scsi($1) if ph =~ /^(.+)\[(\d+)\]$/
			}
			return res
		end
		
		def list_devices
			# Find all storage udis by hal
			udis = `hal-find-by-property  --key storage.drive_type --string disk`.split("\n")
			
			# Find all raid udis
			excluded_udis = `hal-find-by-capability --capability storage.linux_raid`.split("\n")

			# Delete all raid udis from udi list
			for udi in excluded_udis
				udis.delete(udi)
			end
			
			udis.map{|udi| `hal-get-property --udi #{udi} --key block.device`.chomp }
		end
		
		def devices
			@devices ||= list_devices
		end
		
		def raid_member?(device)
			# Delete '/dev/' before device name
			name = device.gsub(/^\/dev\//, '')
			
			# Check name in mdstat file
			not File.read('/proc/mdstat').grep(Regexp.new(name)).empty?
		end
		
		def list_raids
			res = []
			for l in File.readlines('/proc/mdstat')
				# md0 : active raid0 sdb[1] sdc[0]
				res[$1.to_i] = "/dev/md#{$1}" if l =~ /^md(\d+)\s*:\s*\S+\s*\S+\s*.*$/
			end
			res.compact
		end
		
		def raids
			@raids ||= list_raids
		end
		
		# Return next free name for md device
		def next_raid_device_name
			last_id = raids.map{|dev| dev.gsub(/\/dev\/md/, '').to_i }.sort[-1]
			last_id.nil? ? "/dev/md0" : "/dev/md#{last_id + 1}"
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
			res
		end
	end
end
