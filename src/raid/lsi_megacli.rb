module RAID
	class LSIMegaCli < BaseRaid
		PCI_IDS = {
			'1000-0411' => ["1000", "0411"],
			'1000-0060' => ["1000", "0060"],
			'1000-007c' => ["1000", "007c"],
			'1000-0078' => ["1000", "0078"],
			'1000-0079' => ["1000", "0079"],
			'1000-0413' => ["1000", "0413"],
			'1028-0015' => ["1028", "0015"],
		}

		MEGACLI = "#{$EINARC_LIB}/lsi_megacli/cli"

		def initialize(adapter_num = nil)
			adapter_num = 0 if !adapter_num
			@args = "-a#{adapter_num}"
			@dev = []
		end

		# ======================================================================

		def self.query(res)
			adapter_no = nil
			product = nil
			version = nil
			run('-AdpAllInfo -aall').each { |l|
				case l
				when /^Adapter #(\d+)$/
					adapter_no = $1.to_i
				when /^Product Name\s*:\s*(.*)$/
					product = $1.dup
				when /^FW Package Build\s*:\s*(.*)$/
					version = $1
					res << {
						:driver => 'lsi_megacli',
						:num => adapter_no,
						:model => product,
						:version => version,
					}
				end
			}
			return res
		end

		# ======================================================================

		def _adapter_info
			res = {}
			fw = []
			run("-AdpAllInfo #{@args}").each { |l|
				if l =~ /^(.*?)\s*:\s*(.*?)$/
					key = $1
					val = $2
					key = case key
					when /Vendor Id/ then 'PCI vendor ID'
					when /Device Id/ then 'PCI product ID'
					when /SubVendorId/ then 'PCI subvendor ID'
					when /SubDeviceId/ then 'PCI subproduct ID'
					else key
					end				
					res[key] = val
				end
			}

			# Get firmware version
			self.class.query(fw)
			fw.each { |a| res['Firmware version'] = a[:version] }

			return res
		end

		def adapter_restart
			restart_module('megaraid_sas')
		end

		# ======================================================================

		def _task_list
			res = []
			return res
		end

		# ======================================================================

		def log_clear
			run("-AdpEventLog -Clear #{@args}")
		end

		def _log_list
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

		def _logical_list
			@logical = []
			ld = nil
			enclosure = nil
			slot = nil
			run("-LdPdInfo #{@args}").each { |l|
				case l
				when /^Virtual Disk\s*:\s(\d+)/
					num = $1.to_i
					ld = @logical[num] = {
						:num => num,
						:physical => [],
					}
				when /^Size\s*:\s*(\d+)MB$/
					ld[:capacity] = $1.to_i
				when /^State\s*:\s*(.*?)$/
					state = $1.downcase
					state = 'normal' if state == 'optimal'
					ld[:state] = state
				when /^RAID Level\s*:\s*Primary-(\d+),\s*Secondary-(\d+),\s*RAID Level Qualifier-(\d+)$/
					ld[:raid_level] = $1
				when /^Enclosure Device ID\s*:\s*(\d+)$/
					enclosure = $1.to_i
				when /^Slot Number\s*:\s*(\d+)$/
					slot = $1.to_i
					ld[:physical] << "#{enclosure}:#{slot}"
				when /^Stripe Size: (\d+)kB$/
					ld[:stripe] = $1.to_i
				end
			}

			# Try to find corresponding /dev-entries
			devices = Dir.entries("/sys/block").collect { |dev|
					"/sys/block/#{dev}/device/model"
				}.select { |model|
					File.readable?(model)
				}.select { |model|
					File.open(model) { |f| f.readline } =~ /^MegaRAID/
				}.collect { |model|
					$1 if model =~ /block\/(\w+)\/device/
				}
			devs = {}
			devices.each { |dev|
				devs[ Dir.entries("/sys/block/#{dev}/device").collect { |ent|
					"#{$1}:#{$2}" if ent =~ /scsi_disk:\d+:(\d+):(\d+):\d/}.compact.last ] = dev
			}
			devs_ordered = devs.keys.sort.collect { |k| "/dev/#{devs[k]}" }
			@logical.each { |ld| ld[:dev] = devs_ordered.shift }
			return @logical
		end

		def logical_add(raid_level, discs = nil, sizes = nil, options = nil)
			# LSI doesn't support passthrough discs - emulate using RAID0
			raid_level = 0 if raid_level == 'passthrough'

			cmd = "-CfgLdAdd -r#{raid_level} "

			discs = _physical_list.keys unless discs
			cmd += ("[" + (discs.is_a?(Array) ? discs.join(',') : discs) + "]")

			if sizes
				sizes = sizes.split(/,/) if sizes.respond_to?(:split)
				sizes = [sizes] unless sizes.respond_to?(:each)
				sizes.each { |s| cmd += " -sz#{s}" }
			end

			if options
				options = options.split(/,/) if sizes.respond_to?(:split)
				options.each { |o|
					if o =~ /^(.*?)=(.*?)$/
						case $1
						when 'stripe' then cmd += " -strpsz#{$2}"
						else raise Error.new("Unknown option \"#{o}\"")
						end
					else
						raise Error.new("Unable to parse option \"#{o}\"")
					end
				}
			end
			cmd += " #{@args}"

			run(cmd)
		end

		def logical_delete(id)
			run("-CfgLdDel -L#{id} #{@args}")
		end

		def logical_clear
			run("-CfgClr #{@args}")
			run("-CfgForeign -Clear #{@args}")
		end

		def _physical_list
			@physical = {}
			enclosure = nil
			slot = nil
			phys = nil

			run("-pdlist #{@args}").each { |l|
				case l
				when /^Enclosure Device ID:\s*(.+)$/
					enclosure = $1
				when /^Slot Number:\s*(\d+)$/
					slot = $1.to_i
					pd_name = case enclosure
					when /\d+/
						"#{enclosure}:#{slot}"
					when 'N/A'
						":#{slot}"
					else
						raise Error.new("Unable to parse enclosure: #{enclosure}")
					end
					phys = @physical[pd_name] = {}
				when /^Coerced Size:\s*(\d+)MB/
					phys[:size] = $1.to_i
				when /^Inquiry Data: ATA/
					phys[:model] = l[22..37].strip
					phys[:serial] = l[42..61].strip
				when /^Inquiry Data:/
					#phys[:vendor] = l[14..21].strip
					phys[:model] = l[14..21].strip+' '+l[22..37].strip
					phys[:revision] = l[38..41].strip
					phys[:serial] = l[42..61].strip				
				when /^Firmware state: (.*?)$/
					phys[:state] = $1.downcase
					phys[:state] = 'free' if phys[:state] == 'unconfigured(good)'
				end
			}

			# Determine related LDs
			_logical_list.each_with_index { |l, i|
				l[:physical].each { |pd|
					@physical[pd][:state] << i
				}
			}
			@physical.each_value { |phys|
				phys[:state] = 'unknown' if phys[:state].empty?
			}

			return @physical
		end

		# ======================================================================

		def get_adapter_raidlevels(x = nil)
			[ '0', '1', '5', '6' ]
		end

		def get_adapter_alarm(x = nil)
			l = run("-AdpGetProp AlarmDsply #{@args}").join("\n")
			return (case l
				when /Alarm status is Enabled/  then 'enable'
				when /Alarm status is Disabled/ then 'disable'
			end)
		end

		def get_adapter_rebuildrate(x = nil)
			MEGACLI("-GetRbldrate #{@args}")
		end

		def get_adapter_coercion(x = nil)
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
			raise Error.new("There is no firmware file: \"#{filename}\".") unless File.exist?(filename)
			run("-AdpFwFlash -f #{filename} -a0")
		end

		# ======================================================================
		
		def _bbu_info
			info = {}
			run("-AdpBbuCmd -GetBbuDesignInfo #{@args}").each do |l|
			    case l
			    when /^Manufacture Name:\s*(.+)$/
				info[:vendor] = $1
			    when /^Serial Number:\s*(.+)$/
				info[:serial] = $1
			    when/^Design Capacity:\s*(.+)$/
				info[:capacity] = $1
			    when/^Device Name:\s*(.+)$/
				info[:device] = $1
			    end
			end
			info		    
		end
		
		# ======================================================================

		private

		def run(command)
			out = `#{MEGACLI} #{command}`.split("\n").collect { |l| l.strip }
			raise Error.new(out.join("\n")) if $?.exitstatus != 0
			return out
		end

		def self.run(command)
			`#{MEGACLI} #{command}`.split("\n").collect { |l| l.strip }
		end
	end
end
