# Software RAID module needs autodetect to distinguish standalone
# physical HDDs from logical HDDs made by hardware RAID controllers
require 'einarc/autodetect'

require 'einarc/extensions/hotspare'

module Einarc
	# Software RAID on Linux (md)
	class Software < BaseRaid

		include Extensions::Hotspare

		MDSTAT_PATTERN = /^md(\d+)\s:\s( (?:active|inactive) \s* (?:\([^)]*\))? \s* \S*)\s(.+)$/x
		MDSTAT_LOCATION = '/proc/mdstat'

		RETRIES_NUMBER = 5

		def initialize(adapter_num = nil)
			super()
			check_software_requirements
			find_all_arrays
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
			res['RAID Level Supported'] = '0, 1, 4, 5, 6, 10'
			res['Kernel Version'] = `uname -r`.chomp
			res['mdadm Version'] = @software[:mdadm]
			return res
		end

		def find_all_arrays
			for l in run("--examine --scan").grep /^ARRAY/
				# ARRAY /dev/md0 UUID=12345678:12345678:12345678:12345678
				# ARRAY /dev/md1 level=raid0 num-devices=1 UUID=12345678:12345678:12345678:12345678
				# ARRAY /dev/md/0 metadata=1.2 UUID=9f9e9857:a13a2d99:4cf5a707:8f0059e9 name=OpenSAN:0

				l =~ /.*(\/dev\/\w+\/?\d+).*UUID=([\w:]+).*/
				name, uuid = $1, $2
				next unless ( name and uuid ) # mdadm 3.x can print arrays without any /dev entry
				name.gsub!( "md/", "md" )
				run("--assemble --uuid=#{uuid} #{name}") unless active?(name)
			end
		end

		def rescan_bus
			Dir.glob("/sys/class/scsi_host/*").each { |host|
				File.open("#{host}/scan", 'w') { |f| f.write("- - -") }
			}
		end

		def adapter_restart
			check_detached_hotspares
			_logical_list.each { |logical| run("--stop /dev/md#{logical[:num]}", retry_ = true) }
			rescan_bus
			find_all_arrays
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
						:where => lines[i - 2].gsub(/ : .+/, '').gsub(/^md/, '').chomp,
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

		def check_detached_hotspares
			File.open(MDSTAT_LOCATION, 'r') { |f| f.each_line { |l|
				if l =~ MDSTAT_PATTERN
					num = $1.to_i
					self.class.parse_physical_string($3).collect { |d| self.class.scsi_to_device(d) }.each { |d|
						run("/dev/md#{ num } --fail detached --remove detached") if ( detached?(d) and spare?(d) )
					}
				end
			} }
		end

		def array_detail(dev)
			info = {}
			drives = {}
			ld = {}

			run("--detail #{dev}", retry_ = true).each { |l|
				if l =~ /^\s*(.*) : (.*)$/
					info[$1] = $2
				elsif l =~ /^\s*\d+\s+\d+\s+\d+\s+\d+\s+(.*)$/
					$1 =~ /^(.*[^\s])\s+\/dev\/(\w+)$/
					drives[$2] = $1
				end
			}

			ld[:dev] = dev
			ld[:num] = $1.to_i if dev =~ /md(\d+)/
			ld[:capacity] = info["Array Size"].to_i / 1024
			ld[:stripe] = info["Chunk Size"].to_i
			ld[:raid_level] = info["Raid Level"] =~ /raid(\d+)/ ? $1 : "linear"
			states = {
				"clean" => "normal",
				"active" => "normal",
				"Not Started" => "degraded",
				"degraded" => "degraded",
				"resyncing" => "initializing",
				"recovering" => "rebuilding",
			}
			ld[:state] = states[ info["State"].split(", ").select { |s| states.has_key? s }.last ]
			ld[:physical] = drives.keys.select { |drive| drives[drive] and drives[drive] != "removed" }.collect { |drive| self.class.phys_to_scsi drive }

			return ld
		end

		def _logical_list
			@logical = []
			check_detached_hotspares
			raids.each { |ld| @logical << array_detail(ld) }
			return @logical
		end

		# ======================================================================

		def logical_add(raid_level, discs = nil, sizes = nil, options = nil)
			# Normalize arguments: "discs" and "sizes" are an array, "raid_level" is a string
			if discs
				discs = discs.split(/,/) if discs.respond_to?(:split)
				discs = [discs] unless discs.respond_to?(:each)
			end
			raise Error.new("Physical drives not specified") unless discs and !discs.empty?

			raid_level = raid_level.to_s

			phs = _physical_list
			discs = discs.inject([]) do |ary, address|
				ls = phs[address]
				raise Error.new("Physical drive #{ address } not found") unless ls
				raise Error.new("Physical drive #{ address } is not available; see state") if ls[:state] != "free"
				ary << {
					:address => address,
					:devnode => self.class.scsi_to_device(address),
					:info => ls
				}
			end

			if sizes
				sizes = sizes.split(/,/) if sizes.respond_to?(:split)
				sizes = [sizes] unless sizes.respond_to?(:each)
				raise Error.new('Software RAID does not support multiple arrays on the same devices creation') if sizes.length > 1
			else
				sizes = ["max"]
			end

			# Options are all the same for all commands, pre-parse them
			chunk_size = nil
			opt_cmd = ''
			if options
				options = options.split(/,/) if sizes.respond_to?(:split)
				options.each { |o|
					if o =~ /^(.*?)=(.*?)$/
						case $1
						when 'stripe'
							opt_cmd += "--chunk #{$2} "
							chunk_size = $2.to_i
						else
							raise Error.new("Unknown option \"#{o}\"")
						end
					else
						raise Error.new("Unable to parse option \"#{o}\"")
					end
				}
			end

			#raid0, 0, stripe, raid1, 1, mirror, raid5, 5, raid6, 6, raid10, 10
			case raid_level.downcase
			when 'passthrough'
				raise Error.new('Passthrough requires exactly 1 physical disc') unless discs.size == 1
				raid_level = 'linear'
			when '5'
				raise Error.new('RAID 5 requires 3 or more discs') unless discs.size >= 3
			when '6'
				raise Error.new('RAID 6 requires 4 or more discs') unless discs.size >= 4
			when '10'
				raise Error.new('RAID 10 requires an even number of discs, but at least 4') if discs.size % 2 != 0 or discs.size < 4
			end

			calculated_size = calculate_per_disc_requirements(discs, raid_level, sizes.first, chunk_size)

			# Creat RAID using mdadm
			out = `yes | mdadm --create --verbose #{next_raid_device_name} --auto=yes --size=#{ calculated_size } #{opt_cmd} --force --level=#{raid_level} --raid-devices=#{discs.size} #{discs.collect { |d| d[:devnode] }.join(' ')}`
			raise Error.new(out) unless $?.success?

			# Refresh lists
			@raids = @devices = nil
		end

		# ======================================================================

		def logical_delete(id)
			# Get list of disks
			disks = devices_of("/dev/md#{id}")

			# Stop RAID
			run("--stop /dev/md#{id}", retry_ = true)

			# Remove disks from RAID and zero superblocks
			disks.each{ |d| zero_superblock d }

			# Refresh lists
			@raids = @devices = nil
		end

		# ======================================================================

		def logical_clear
			# Consistently delete all devices
			raids.each { |r| logical_delete(r.gsub(/\/dev\/md/, '')) }

			# Refresh lists
			@raids = @devices = nil
		end

		# ======================================================================

		def logical_hotspare_add(ld, drv)
			raise Error.new("Device #{drv} is already in RAID") if raid_member?(self.class.scsi_to_device(drv))
			raise Error.new("Can not add hotspare to level 0 RAID") if level_of("/dev/md#{ld}") == '0'
			drv = self.class.scsi_to_device drv
			zero_superblock drv
			run("/dev/md#{ld} --add #{drv}")
		end

		def logical_hotspare_delete(ld, drv)
			raise Error.new("This drive is not hotspare") unless get_physical_hotspare(drv)
			raise Error.new("Hotspare is dedicated not to that array") if _logical_physical_list(ld).select { |d| d[:num] == drv }.empty?
			run("/dev/md#{ld} --remove #{self.class.scsi_to_device(drv)}")
		end

		# ======================================================================

		def _logical_physical_list(ld)
			res = []
			check_detached_hotspares
			File.open(MDSTAT_LOCATION, "r"){ |f| f.each_line { |l| l.chop!
				next unless l =~ /^md#{ld}/
				l.split(" ").each{ |ent|
					state = ld
					next unless ent =~ /(\w+)\[\d+\]/
					state = "hotspare" if spare?($1)
					state = "failed" if failed?($1)
					drv = self.class.phys_to_scsi($1)

					res.push( { :num => drv, :state => state } )
				}
			}}
			return res
		end

		# ======================================================================

		def _physical_list
			# Resulting hash
			res = {}

			for device in devices
				# Possibility to skip USB mass storage devices
				# next if usb_device?(device)
				target = self.class.phys_to_scsi(device.gsub(/^\/dev\//, ''))
				d = { :state => 'unknown' }
				d[:vendor] = physical_read_file(device, "device/vendor") or ""
				d[:vendor] = nil if d[:vendor] =~ /^ATA\s*$/
				d[:model] = physical_read_file(device, "device/model") or ""
				d[:model] = "#{d[:vendor]} #{d[:model]}" if d[:vendor]
				d[:revision] = physical_read_file(device, "device/rev") or ""
				d[:size] = physical_read_file(device, "size") or 0
				d[:size] = d[:size].to_f * 512 / 1048576
				d[:serial] = physical_get_serial(device)

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
					# Skip failed or non-existent drives
					next if failed?(self.class.scsi_to_device(target)) or not res[target]

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

		def _physical_smart(drv)
			needed_smart_section_re = /START OF READ SMART DATA SECTION/

			# Determine do we need to use "-d ata" option
			smart_output = `smartctl -A #{self.class.scsi_to_device drv}`
			smart_output = `smartctl -d ata -A #{self.class.scsi_to_device drv}` unless smart_output =~ needed_smart_section_re

			return parse_smart_output( smart_output )
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
			return %w{linear passthrough 0 1 4 5 6 10}
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

		def get_logical_writecache(num)
			ld = _logical_list.reject { |logical| logical[:num] != num.to_i }[0]
			raise Error.new("Unknown logical disc \"#{num}\"") unless ld
			ld[:physical].collect { |pd| get_physical_writecache pd }.count("0") == ld[:physical].length ? 0 : 1
		end

		def set_logical_writecache_0(num)
			ld = _logical_list.reject { |logical| logical[:num] != num.to_i }[0]
			raise Error.new("Unknown logical disc \"#{num}\"") unless ld
			ld[:physical].each{ |pd| set_physical_writecache_0 pd }
		end

		def set_logical_writecache_1(num)
			ld = _logical_list.reject { |logical| logical[:num] != num.to_i }[0]
			raise Error.new("Unknown logical disc \"#{num}\"") unless ld
			ld[:physical].each{ |pd| set_physical_writecache_1 pd }
		end

		# ======================================================================

		def set_logical_powersaving_0(num)
			ld = _logical_list.reject { |logical| logical[:num] != num.to_i }[0]
			raise Error.new("Unknown logical disc \"#{num}\"") unless ld
			ld[:physical].each{ |pd| set_physical_powersaving_0 pd }
		end

		# ======================================================================

		def sgmaps
			@sgmaps ||= list_sgmaps
		end

		def list_sgmaps()
			Hash[ `sg_map`.split("\n").map{ |m| m.split(/\s+/).reverse }.select{ |p| p.size > 1 } ]
		end

		def get_physical_wwn( drv )
			page = "0x19" # SAS SSP port control mode page
			subpage = "0x1" # SAS Phy Control and Discover mode subpage

			drv = self.class.scsi_to_device drv
			wwns = `sginfo -t #{page},#{subpage} #{ sgmaps[ drv ] }`.split("\n").grep(/^SAS address/).map{ |l| l.split(/\s+/).last }
			return wwns if wwns.size > 0
			# Otherwise we are dealing with the SATA
			# They can contain also two WWNs: the real one and
			# that is visible to system
			wwns = `sdparm --inquiry #{ drv }`.split("\n").collect{ |l| $1 if l =~ /^\s+(0x................)$/ }.compact
			return wwns
		end

		# ======================================================================

		def _adapter_expanders
			enclosure_scsi_id = 13

			`sg_map`.split("\n").map{ |m|
				m.split(/\s+/)
			}.select{ |p|
				p.size == 1
			}.flatten.collect{ |sg|
				product = nil
				device_type = nil
				`sginfo #{sg}`.split("\n").each { |l|
					device_type = $1 if l =~ /^Device Type\s+(\d+)$/
					product = $1 if l =~ /^Product:\s+(.+)$/
				}
				[ sg.gsub( "/dev/sg", ""), product.strip ] if device_type.to_i == enclosure_scsi_id
			}.compact
		end

		def get_physical_enclosure( drv )
			ses_page = "0xa" # Additional element status (SES-2)

			wwns = get_physical_wwn drv
			_adapter_expanders.each{ |enc, product|
				info = []
				`sg_ses --page #{ses_page} /dev/sg#{enc}`.split("\n").each{ |l|
					info << $1 if l =~ /bay number: (\d+)$/
					info << $1 if l =~ /^\s+SAS address: (\w+)$/
				}
				info.each_slice(2){ |p|
					return "#{ enc }:#{ p[0].to_i }" if wwns.include?( p[1] )
				}
			}
			return nil
		end

		# ======================================================================

		def get_physical_writecache( drv )
			return `sdparm --quiet --get WCE #{self.class.scsi_to_device drv}`.split[1]
		end

		def set_physical_writecache_0( drv )
			`sdparm --set WCE=0 #{self.class.scsi_to_device drv}`
		end

		def set_physical_writecache_1( drv )
			`sdparm --set WCE=1 #{self.class.scsi_to_device drv}`
		end

		# ======================================================================

		def set_physical_powersaving_0( drv )
			dev = self.class.scsi_to_device drv

			# All commands below may fail, but there is no need to check it
			# ATA/SATA: Try setting maximum performance mode of power management
			`hdparm -B 254 #{ dev } 2>/dev/null`

			# ATA/SATA: Try power management turning off at all
			# If it fail -- at least 254 value will stay
			`hdparm -B 255 #{ dev } 2>/dev/null`

			# ATA/SATA: Try setting suspend time to zero (disable)
			`hdparm -S 0 #{ dev } 2>/dev/null`

			# SAS: Turn off power-management, idle and standby timers
			[ "PM_BG", "IDLE", "STANDBY" ].map{ |v|
				`sdparm --set #{v}=0 #{ dev } 2>/dev/null`
			}
		end

		# ======================================================================

		def _bbu_info
			raise NotImplementedError
		end

		# ======================================================================

		private

		# Checks what software is present at the system, if it's sufficient for
		# us to continue at all or would require to use any workarounds.
		def check_software_requirements
			@software = {}

			begin
				@software[:mdadm] = run('--version').join
			rescue Error => e
				raise Error.new('mdadm is not available')
			end

			@software[:udevadm] = `udevadm --version`.chomp
			@software[:udevadm] = nil if $?.exitstatus != 0
		end

		def run(command, retry_ = false)
			tries = retry_ ? RETRIES_NUMBER : 0
			begin
				out = `mdadm #{command} 2>&1`.split("\n").collect { |l| l.strip }

				# Return an empty array at once, as there is no need to repeat
				# the whole process because of positive return code
				return [] if out.select { |l|
					l =~ /No devices listed in/ or l =~ /No suitable drives found for/
				}.size > 0

				raise Error.new(out.join("\n")) if $?.exitstatus != 0
			rescue Error => e
				if command =~ /detail/ and e.text =~ /does not appear to be active/
					begin
						run("--run #{ command.split.last }")
					rescue
						true
					end
					tries -= 1
					retry if tries >= 0
				end
				if e.text =~ /failed to stop array.*Device or resource busy/
					tries -= 1
					sleep 1
					retry if tries >= 0
				else
					raise Error.new( e.text )
				end
			end
			return out
		end

		def self.parse_physical_string(str)
			res = []
			str.split(/ /).each { |ph|
				res[$2.to_i] = phys_to_scsi($1) if ph =~ /^(.+)\[(\d+)\].*$/
			}
			return res.compact
		end

		def list_devices
			return File.open("/proc/partitions", "r").collect { |l|
				"/dev/" + $2 if l =~ /^\s+(3|8|22|65|66|67|68|69|70|71)\s+\d+\s+\d+\s+([a-z]+)$/ }.compact.select { |d|
					not phys_belongs_to_adapters(d) }
		end

		def devices
			@devices ||= list_devices
		end

		def raid_member?(device)
			name = device.gsub(/^\/dev\//, '')

			# Check name existence in mdstat file
			return (not File.readlines(MDSTAT_LOCATION).grep(Regexp.new(name)).empty?)
		end

		def spare?(device)
			name = device.gsub(/^\/dev\//, '')

			# Ex. sda[0](S)
			return (not File.readlines(MDSTAT_LOCATION).grep(/#{name}\[[^\[]*\]\(S\)/).empty?)
		end

		def failed?(device)
			name = device.gsub(/^\/dev\//, '')

			# Ex. sda[0](F)
			return (not File.readlines(MDSTAT_LOCATION).grep(/#{name}\[[^\[]*\]\(F\)/).empty?)
		end

		def usb_device?(device)
			name = device.gsub(/^\/dev\//, '')
			return ((not File.readlines("/sys/block/#{name}/uevent").grep(/usb/).empty?) or
				(File.readlink("/sys/block/#{name}" ) =~ /usb/))
		end

		def active?(device)
			name = device.gsub(/^\/dev\//, '')

			# Check RAID existence in mdstat file
			return (not File.readlines(MDSTAT_LOCATION).grep(Regexp.new(name)).empty?)
		end

		def detached?(device)
			name = device.gsub(/^\/dev\//, '')
			return (not devices.include?( "/dev/#{ name }" ))
		end

		def list_raids
			res = []
			id_last = nil
			for l in File.readlines(MDSTAT_LOCATION)
				# md0 : active raid0 sdb[1] sdc[0]
				(res[$1.to_i] = "/dev/md#{$1}" and id_last = $1.to_i) if l =~ MDSTAT_PATTERN
				res.delete_at(id_last) if l =~ /\ssuper\s/ # mdadm 3.x has unsupported "container" type
			end
			return res.compact
		end

		def raids
			@raids ||= list_raids
		end

		def devices_of(device)
			#md0 : active linear sdc[0]
			File.readlines(MDSTAT_LOCATION).grep(%r[^#{device.gsub(/\/dev\//, '') }]).grep(MDSTAT_PATTERN) do
				return $3.split(/\[\d+\](?:\(S\))? ?/).map{|d| d.gsub('(S)','') }.map{|d| "/dev/#{d}" }
			end
		end

		def level_of(device)
			File.readlines(MDSTAT_LOCATION).grep(%r[^#{device.gsub(/\/dev\//, '') }]).grep(MDSTAT_PATTERN) do
				return $2.split.last.gsub('raid','')
			end
		end

		# Returns next free name for md device
		def next_raid_device_name
			last_id = raids.map{ |dev| dev.gsub(/\/dev\/md/, '').to_i }.sort[-1]
			return last_id.nil? ? "/dev/md0" : "/dev/md#{last_id + 1}"
		end

		# Derive ASCII code for 'a', Ruby 1.8 and Ruby 1.9 compatible way
		ASCII_A = 'a'.respond_to?(:ord) ? 'a'.ord : 'a'[0]

		# Convert character to number, "a" => 1, "z" => 26
		def self.char_to_number(ch)
			if ch.respond_to?(:ord)
				# Ruby 1.9
				ch.ord - ASCII_A + 1
			else
				# Ruby 1.8
				ch[0] - ASCII_A + 1
			end
		end

		# Convert number to character, 1 => "a", 26 => "z"
		def self.number_to_char(num)
			(num + ASCII_A - 1).chr
		end

		# Converts physical name (hda) to SCSI enumeration (1:0)
		def self.phys_to_scsi(name)
			name =~ /^(s|h)d([a-z]+)(\d*)$/
			pre, root, post = $1, $2, $3
			return name unless pre and root

			dev_num = 0
			root.split(//).map { |c|
				char_to_number(c)
			}.reverse.each_with_index { |c, index|
				dev_num += c * 26 ** index
			}

			res = pre == 's' ? "0" : "1"
			res += ":#{dev_num}"
			res += ":#{post}" unless post.empty?
			return res
		end

		# Converts SCSI enumeration (1:0) to physical device name (hda)
		# Official Linux kernel algorithm is available in sd_format_disk_name(...) at
		# http://git.kernel.org/cgit/linux/kernel/git/torvalds/linux.git/tree/drivers/scsi/sd.c#n2763
		def self.scsi_to_device(id)
			raise Error.new("Invalid physical disc specification \"#{id}\": \"a:b\" or \"a:b:c\" expected") unless id =~ /^([01]):(\d+):?(\d+)?$/
			res = ($1 == '1') ? '/dev/hd' : '/dev/sd'

			i = $2.to_i - 1
			cs = []
			while i >= 0
				cs.unshift(i % 26)
				i = (i / 26) - 1
			end

			res += cs.map { |c| number_to_char(c + 1) }.join

			res += $3 if $3
			return res
		end

		# Get serial of a physical device (i.e. "/dev/sda"). Tries either
		# udevadm method (faster), reading sysfs file directly, or smartctl
		# method (slower, if udevadm is not available)
		def physical_get_serial(device)
			if @software[:udevadm]
				physical_get_serial_via_udev(device)
			else
				r = physical_get_serial_via_file(device)
				return r unless r.nil?
				return physical_get_serial_via_smart(device)
			end
		end

		def physical_get_serial_via_udev(device)
			info = `udevadm info --query=env --name=#{device}`
			info =~ /ID_SERIAL_SHORT=(.*)\n/
			return $1 if $1
			info =~ /ID_SERIAL=(.*)\n/
			return $1 ? $1 : ""
		end

		def physical_get_serial_via_file(device)
			physical_read_file(device, "device/serial")
		end

		def physical_get_serial_via_smart(device)
			return `smartctl --all #{ device }` =~ /^[Ss]erial number:\s*(\w+)$/i ? $1 : nil
		end

		def zero_superblock( device )
			run("--zero-superblock #{device}")
		end

		# Determine if device belongs to any known by Einarc controller
		def phys_belongs_to_adapters(device)
			if @software[:udevadm]
				phys_belongs_to_adapters_udevadm(device)
			else
				phys_belongs_to_adapters_manual(device)
			end
		end

		# Determine if a device belongs to any Einarc-handled adapters.
		# This version of procedure is a main implementation that uses udevadm.
		def phys_belongs_to_adapters_udevadm(device)
			# Try to determine via udev attribute walking
			def get_id( section, what )
				return section.collect { |l| l =~ /ATTRS.#{what}.==.*(\w{4})/; $1 if $1 }.compact.last
			end
			info = `udevadm info --attribute-walk --name=#{device}`
			headers = info.split(/\n/).select { |l| l =~ /looking at parent/ }
			sections = info.split(/^.*looking at parent.*$/)
			founded = false
			headers.select{ |h| h =~ /looking at parent.*\/devices\/pci.*\/\w{4}:\w{2}:\w{2}\.\w..$/ }.each { |h|
				section = sections[ headers.index( h ) + 1 ].split(/\n/)
				founded ||= Einarc::find_adapter_by_pciid(
					get_id(section, "vendor"),
					get_id(section, "device"),
					get_id(section, "subsystem_vendor"),
					get_id(section, "subsystem_device")
				) ? true : false
			}
			return founded if founded
		end

		# Determine if a device belongs to any Einarc-handled adapters.
		# This version of procedure is a fallback that uses manual sysfs
		# walking, when udevadm utility is not available.
		def phys_belongs_to_adapters_manual(device)
			bare_dev = device.gsub(/^\/dev\//, '')
			full_path = File.readlink("/sys/block/#{bare_dev}/device")

			path = "/sys/block/#{bare_dev}"
			full_path.split('/').each { |dir|
				path += "/#{dir}"
				return true if Einarc::find_adapter_by_pciid(
					*['vendor', 'device', 'subsystem_vendor', 'subsystem_device'].collect { |f|
						data = sysfs_read_file("#{path}/#{f}")
						data.gsub!(/^0x/, "") if data
						data
					}
				)
			}
			return false
		end

		def calculate_per_disc_requirements(discs, raid_level, requested_size, chunk_size)
			return "max" if requested_size == "max"

			chunk_size ||= 64
			count = discs.size
			requested_size = requested_size.to_f * 1024
			calculated_size = case raid_level
			when "1"
				requested_size
			when "4", "5"
				requested_size / (count - 1)
			when "6"
				requested_size / (count - 2)
			else
				# ignore size specified by passing the default value
				return "max"
			end
			# according to the man page, size specified should be a multiple of chunk size
			(calculated_size / chunk_size).to_i * chunk_size
		end
	end
end
