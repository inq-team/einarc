# Software RAID module needs autodetect to distinguish standalone
# physical HDDs from logical HDDs made by hardware RAID controllers
require 'raid/autodetect'

require 'raid/extensions/hotspare.rb'

module RAID
	class Software < BaseRaid

		include Extensions::Hotspare

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
						ld[:state] = "pending"
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
			discs.map! { |d| scsi_to_device(d) }

			# Check if discs are already RAID members
			for d in discs
				raise Error.new("Device #{d} is already in RAID") if raid_member?(d)
			end

			if sizes
				sizes = sizes.split(/,/) if sizes.respond_to?(:split)
				sizes = [sizes] unless sizes.respond_to?(:each)
				raise Error.new('Software RAID does not support multiple arrays on the same devices creation') if sizes.length > 1
				sizes = (sizes[0].to_i * 1024).to_s
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

		def logical_hotspare_add(ld, drv)
			raise Error.new("Device #{drv} is already in RAID") if raid_member?(scsi_to_device(drv))
			raise Error.new("Can not add hotspare to level 0 RAID") if level_of("/dev/md#{ld}") == '0'
			`mdadm /dev/md#{ld} -a #{scsi_to_device(drv)}`
		end

		def logical_hotspare_delete(ld, drv)
			raise Error.new("This drive is not hotspare") unless get_physical_hotspare(drv)
			raise Error.new("Hotspare is dedicated not to that array") if _logical_physical_list(ld).select { |d| d[:num] == drv }.empty?
			`mdadm /dev/md#{ld} -r #{scsi_to_device(drv)}`
		end

		# ======================================================================

		def _logical_physical_list(ld)
			res = []
			File.open("/proc/mdstat", "r"){ |f| f.each_line { |l| l.chop!
				next unless l =~ /^md#{ld}/
				l.split(" ").each{ |ent|
					state = ld
					next unless ent =~ /(\w+)\[\d+\]/
					state = "hotspare" if spare?($1)
					state = "failed" if failed?($1)
					drv = phys_to_scsi($1)

					res.push( { :num => drv, :state => state } )
				}
			}}
			return res
		end

		# ======================================================================

		def _physical_list
			# Resulting hash
			res = {}

			for device in list_devices
				# Possibility to skip USB mass storage devices
				# next if usb_device?(device)
				target = phys_to_scsi(device.gsub(/^\/dev\//, ''))
				d = { :state => 'unknown' }
				d[:model] = physical_read_file(device, "device/model") or ""
				d[:revision] = physical_read_file(device, "device/rev") or ""
				d[:size] = physical_read_file(device, "size") or 0
				d[:size] = d[:size].to_f * 512 / 1048576
				d[:serial] = physical_read_file(device, "device/serial")
				d[:serial] = physical_get_serial_via_udev(device) unless d[:serial]

				if raid_member?(device)
					d[:state] = 'hotspare' if spare?(device)
					d[:state] = 'failed' if failed?(device)
				else
					d[:state] = 'free'
				end
				res[target] = d
			end

			_logical_list.each do |logical|
				logical[:physical].each do |target|
					next if failed?( scsi_to_device(target) )
					next if res[target][:state] == 'hotspare'
					if res[target][:state].is_a? Array
						res[target][:state] << logical[:num]
					else
						res[target][:state] = [ logical[:num] ]
					end
				end
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
			raise NotImplementedError
		end

		def set_physical_hotspare_1(drv)
			raise NotImplementedError
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
				"/dev/" + $1 if l =~ /^\s+[38]\s+\d+\s+\d+\s+([a-z]+)$/ }.compact.select { |d|
					not phys_belongs_to_adapters(d) }
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

		def failed?(device)
			# Delete '/dev/' before device name
			name = device.gsub(/^\/dev\//, '')

			# Ex. sda[0](F)
			return (not File.read(MDSTAT_LOCATION).grep(/#{name}\[[^\[]*\]\(F\)/).empty?)
		end

		def usb_device?(device)
			name = device.gsub(/^\/dev\//, '')
			return (not File.read("/sys/block/#{name}/uevent").grep(/usb/).empty?)
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
				return $2.split.last.gsub('raid','')
			end			
		end

		# Returns next free name for md device
		def next_raid_device_name
			last_id = raids.map{ |dev| dev.gsub(/\/dev\/md/, '').to_i }.sort[-1]
			return last_id.nil? ? "/dev/md0" : "/dev/md#{last_id + 1}"
		end

		# Converts physical name (hda) to SCSI enumeration (1:0)
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

		# Converts SCSI enumeration (1:0) to physical device name (hda)
		def scsi_to_device(id)
			raise Error.new("Invalid physical disc specification \"#{id}\": \"a:b\" or \"a:b:c\" expected") unless id =~ /^([01]):(\d+)(:(\d+))?$/
			res = ($1 == '1') ? '/dev/hd' : '/dev/sd'
			res += ('a'[0] + $2.to_i).chr
			res += $4 if $4
			return res
		end

		# Read single line from block device-related files in sysfs
		def physical_read_file(device, source)
			begin
				return File.open("/sys/block/#{device.gsub(/^\/dev\//, '')}/#{source}", "r").readline.chop
			rescue Errno::ENOENT
				return nil
			end
		end

		def physical_get_serial_via_udev(device)
			info = `udevinfo --query=env --name=#{device}`
			info =~ /ID_SERIAL_SHORT=(.*)\n/
			return $1 if $1
			info =~ /ID_SERIAL=(.*)\n/
			return $1 ? $1 : ""
		end

		# Determine if device belongs to any known by Einarc controller
		def phys_belongs_to_adapters(device)
			sysfs_pciid = File.readlink("/sys/block/#{device.gsub(/^\/dev\//, '')}/device").split("/").select { |f|
				f =~ /^\d+:\d+:[\w\.]+$/
			}[-1]
			vendor_id = File.open("/sys/bus/pci/devices/#{sysfs_pciid}/vendor").readline.chop.gsub(/^0x/, "")
			product_id = File.open("/sys/bus/pci/devices/#{sysfs_pciid}/device").readline.chop.gsub(/^0x/, "")
			sub_vendor_id = File.open("/sys/bus/pci/devices/#{sysfs_pciid}/subsystem_vendor").readline.chop.gsub(/^0x/, "")
			sub_product_id = File.open("/sys/bus/pci/devices/#{sysfs_pciid}/subsystem_device").readline.chop.gsub(/^0x/, "")

			return RAID::find_adapter_by_pciid(vendor_id, product_id, sub_vendor_id, sub_product_id) ? true : false
		end
	end
end
