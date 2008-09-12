# vim: ai noexpandtab

module RAID
	class Amcc < BaseRaid
		TWCLI = "#{$EINARC_LIB}/amcc/cli"
		# FIXME get this from configure?
		SG3INQ = "/usr/bin/sg_inq"

		def initialize(adapter_num = nil)
			@adapter_num = adapter_num
		end

		# ======================================================================

		def self.query(res)
			run(" info").each { |l|
				if l =~ /^c[0-9]+/ then
					x = l.split(/ +/)
					version = ''
					run("/#{x[0]} show firmware").each { |f|
						version = f.split(/ +/)[-1] if f =~ /Firmware Version/
					}
					res << {
						:driver => 'amcc',
						:num => x[0][1..-1],
						:model => x[1],
						:version => version,
					}
				end
			}
			raise Error.new('amcc: failed to query adapter list') if $?.exitstatus != 0
			return res
		end

		# ======================================================================

		def _adapter_info
			res = {}
			run(" show all").each { |l|
				if l =~ /^\/c[0-9]+/ then
					key, value = l.split(/ = /)
					key.slice!(/^\/c[0-9]+ /)
					key = case key
						when 'Serial Number' then 'Serial number'
						when 'Firmware Version' then 'Firmware version'
						else key
						end
					res[key] = value
				end
			}
			# as per http://www.3ware.com/KB/article.aspx?id=15127
			# and http://pci-ids.ucw.cz/iii/?i=13c1
			res['PCI vendor ID'] = '13c1'
			res['PCI product ID'] = case res['Model']
				when /^9690/ then '1005'
				when /^9650/ then '1004'
				when /^9550/ then '1003'
				when /^9/ then '1002'
				when /^[78]/ then '1001'
				end
			return res
		end

		def adapter_restart
			raise NotImplementedError
		end

		# ======================================================================

		def _task_list
			raise NotImplementedError
		end

		# ======================================================================

		def log_clear
			raise NotImplementedError
		end

		def _log_list
			res=[]
			n=0
#Ctl  Date                        Severity  Alarm Message
#------------------------------------------------------------------------------
#c0   [Tue Jul  8 14:52:10 2008]  INFO      Battery charging completed
#c0   [Tue Jul  8 18:20:05 2008]  INFO      Verify started: unit=0
# 1         2   3 4  5  6  7                8
#c0   [Tue Jul  8 18:20:05 2008]  INFO      Verify started: unit=1
			run(' show alarms').each { |l|
				#           1              2      3      4     5     6      7            8
				if l =~ /^c(\d+) +\[\w+ +(\w+) +(\d+) +(\d+):(\d+):(\d+) +(\d+)\] +\w+ +(.*)/ then
					res << {
						:id => n,
						:time => Time.local($7,$2,$3,$4,$5,$6),
						:where => $1,
						:what => $8,
					}
					n += 1
				end
			}
			return res
		end

		# ======================================================================
		
		# use SCSI INQUIRY to get the serial number from each disk
		# returns a hash with {serialnumber,diskname} where diskname is like 'sda' 
		private
		def __get_disk_serials
			diskserials={}
			return diskserials if !File.executable?(SG3INQ)
			__list_disks.each { |d|
				devfile=File.join("/dev",d)
				serial=""
				`#{SG3INQ} #{devfile}`.each{ |l|
					serial = l.split(" ")[-1] if l =~ /Unit serial number/
				}
				diskserials[serial]=d
			}
			return diskserials
		end

		# list all disks in the system (e.g. ['sda','sdb','sdc'])
		private
		def __list_disks
			disks=[]
			Dir.glob('/sys/block/*').each() { |x|
				# not a ramdisk or loop or somesuch
				if File.exists?(File.join(x,"device")) then
					# not removable either
					a=File.new(File.join(x,"removable"))
					disks << File.basename(x) if a.readline=="0\n"
				end
			}
			return disks
		end

		def _logical_list
			# FIXME: show spares?
			@logical = []
			mapping = {} # between units and ports

			run(' show').each { |l|
				case l
	# Unit  UnitType  Status         %RCmpl  %V/I/M  Stripe  Size(GB)  Cache  AVrfy
	# ------------------------------------------------------------------------------
	# u0    RAID-1    OK             -       -       -       465.651   ON     OFF    
	# u1    RAID-5    OK             -       -       64K     931.303   ON     OFF    
	# u2    RAID-5    OK             -       -       64K     931.303   ON     OFF    
				when /^u([0-9]+) +(\S+) +(\S+) +(\S+) +(\S+) +(\S+) +([0-9\.]+) +(\S)/
					m = Regexp.last_match
					logical << {
						:num => m[1],
						:dev => nil,
						:physical => [],
						:state => case m[3]
							when 'OK' then 'normal'
							when /REBUILD/ then 'rebuilding'
							when /INITIALIZING/ then 'initializing'
							else m[3]
							end,
						:raid_level => m[2],
						# remove trailing 'K'
						:stripe => (m[6] == '-') ? nil : m[6][1..-1],
						# 3ware reports in GiB, einarc in MiB
						:capacity => 1024 * (m[7].to_f),
						:cache => (m[8] == 'ON') ? 'writeback' : 'writethrough',
					}
					mapping[m[1]] = []
					# ports come later in the output, that's why
					# we have some 'mapping' magic here
					# also, unit numbers are NOT contiguous
	# Port   Status           Unit   Size        Blocks        Serial
	# ---------------------------------------------------------------
	# p0     OK               u0     465.76 GB   976773168     WD-WCASU1168570     
	# p1     OK               u0     465.76 GB   976773168     WD-WCASU1168141     
	# p2     OK               u1     465.76 GB   976773168     WD-WCASU1168002     
	# p3     OK               u1     465.76 GB   976773168     WD-WCASU1168560     
				when /^p([0-9]+)\s+(\S+)\s+u([0-9]+)/
					unitno = $3
					portno = $1
					mapping[unitno] << portno
				end
			}
			# get serial numbers for all disks
			ds=__get_disk_serials
			# put the physical mapping into the logical-disk structure
			# as well as the disk names
			logical.each_index { |i|
				logical[i][:physical] = mapping[logical[i][:num]]
				ser=''
				run("/u#{logical[i][:num]} show serial").each{ |l|
					ser=l.split(" = ")[-1] if l =~ /serial number/
				}
				logical[i][:dev] = ds[ser]
			}
			return @logical
		end

		# ======================================================================

		def logical_add(raid_level, discs = nil, sizes = nil, options = nil)
			case raid_level
				when "passthrough" then raid_level="single" 
				when "spare" then raid_level="spare" 
				when /^[0-9]+$/ then raid_level="raid#{raid_level}"
				when /^RAID-([0-9])+$/ then raid_level="raid#{$1}"
				when /^raid-([0-9])+$/ then raid_level="raid#{$1}"
				when /^raid([0-9])+$/ then raid_level="raid#{$1}"
				when /^RAID([0-9])+$/ then raid_level="raid#{$1}"
				else raise Error.new("Unknown RAID level \"#{raid_level}\"")
			end
			# no disks specified -> all disks
			# FIXME this doesn't seem to work
			#discs = _physical_list.keys unless discs
			
			discs=discs.gsub(",",":")

			# "sizes" is not supported, 3ware creates units on whole disks

			# sensible defaults
			# note that the current 9650SE has a problem with SMART enabled
			# and qpolicy=on at the same time, under heavy load (2008-08-19)
			storsave="balance"
			qpolicy="on"
			cache="on"
			autoverify="off"
			stripe="64k"
			name=""

			if options
				options = options.split(/,/)
				options.each { |o|
					if o =~ /^(.*?)=(.*?)$/
						case $1
							when 'stripe' then stripe="#{$2}k"
							when 'qpolicy' then qpolicy="#{$2}"
							when 'storsave' then storsave="#{$2}"
							when 'name' then name="#{$2}"
							when 'cache' then cache="#{$2}"
							when 'nocache' then cache="off"
							else raise Error.new("Unknown option \"#{o}\"")
						end
					else
						raise Error.new("Unable to parse option \"#{o}\"")
					end
				}
			end

			cmd=" add type=#{raid_level} disk=#{discs} stripe=#{stripe} storsave=#{storsave}"
			cmd += " nocache" if cache!="on"
			cmd += " noqpolicy" if qpolicy!="on"
			cmd += " name=#{name}" if name!=""

			run(cmd)
		end

		def logical_delete(id)
			run("/u#{id} del quiet")
		end

		def logical_clear
			_logical_list.each{ |l|
				logical_delete(l[:num])
			}
		end

		def _physical_list
			res = {} # overall mapping
			run(' show').each { |l|
				# don't query ports with no disks on them
				# that causes tw_cli to throw up :-P
				next if l =~ /NOT-PRESENT/
				if l =~ /^p([0-9]+) /
					p = $1
					pd = res[p] = {}
					# query the details.
					run("/p#{p} show all").each { |l|
						case l
						when /p#{p} Status = (\S+)/
							pd[:state] = $1.downcase
						when /Model = (.*)$/
							pd[:model] = $1.strip
						when /Firmware Version = (.*)$/
							pd[:revision] = $1.strip
						when /Capacity = ([0-9\.]+)/
							pd[:size] = 1024 * ($1.to_f)
						when /Serial = (.*)/
							pd[:serial] = $1.strip
						end # case per_port
					}
				end # if this_is_a_valid_port
			}
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

		def _bbu_info
			raise NotImplementedError
		end
		
		# ======================================================================

		def get_adapter_raidlevels(x = nil)
			raise NotImplementedError
		end

		def get_adapter_rebuildrate(x = nil)
			raise NotImplementedError
		end

		def set_physical_hotspare_0(drv)
			raise NotImplementedError
		end

		def set_physical_hotspare_1(drv)
			logical_add("spare",drv,"","")
		end
		
		def get_logical_stripe(num)
			raise NotImplementedError
		end

		# Converts physical name (sda) to SCSI enumeration (1:0)
		def phys_to_scsi(name)
			raise NotImplementedError
		end

		# run one command, instance method
		private
		def run(command)
			puts("DEBUG: #{TWCLI} /c#{@adapter_num}#{command}")
			out = `#{TWCLI} /c#{@adapter_num}#{command}`.split("\n").collect { |l| l.strip }
			raise Error.new(out.join("\n")) if $?.exitstatus != 0
			return out
		end

		# class method for self.query()
		private
		def self.run(command)
			out = `#{TWCLI} #{command}`.split("\n").collect { |l| l.strip }
			raise Error.new(out.join("\n")) if $?.exitstatus != 0
			return out
		end
	end
end
