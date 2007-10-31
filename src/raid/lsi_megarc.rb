module RAID
	class LSIMegaRc < BaseRaid
		MEGARC = "#{$EINARC_LIB}/lsi_megarc/cli"

		def initialize(adapter_num = nil)
			adapter_num = 0 if !adapter_num
			@args = "-a#{adapter_num}"
			@dev = []
		end

		# ======================================================================

		def self.query(res)
			stage = 0
			megarc('-AllAdpInfo').each { |l|
				if stage == 0
					stage = 1 if l =~ /AdapterNo/
				else
					if l =~ /^\s*(\d+)\s+(.*?)\s+(.*?)\s*$/
						res << {
							:driver => 'lsi_megarc',
							:num => $1.to_i,
							:model => $3,
							:version => $2,
						}
					else
						warn l
					end
				end
			}
		end

		# ======================================================================

		def _adapter_info
			out = megarc("-ctlrinfo #{@args}")
			out.slice!(0)
			out.each { |l|
				l.gsub!(/\t\t/, "\n")
				l.gsub!(/ : /, "\t")
				l.gsub!(/^Board SN: /, "Board SN\t")
			}
			res = {}
			out.join("\n").split(/\n/).each { |x|
				key, value = x.split(/\t/)
				key = case key
		                when 'Board SN' then 'Serial number'
		                else key
		                end
				res[key] = value
			}
			return res
		end

		def adapter_restart
			restart_module('megaraid_mbox')
		end

		# ======================================================================

		def log_clear
			out = megarc("-clrNVRAMLog #{@args}");
			raise Error.new(out.join("\n")) if $?.exitstatus != 0
		end

		def _log_list
			seq = ctl = chn = tgt = event = nil
			res = []
			megarc("-getNVRAMLog #{@args}").each { |l|
				case l
				when /SeqNo=(.*?) ctl=(.*?) chn=(.*?) tgt=(.*)/
					seq = $1
					ctl = $2
					chn = $3
					tgt = $4
				when /Event=\s+(.*)/
					event = $1
				when /Logged at: (.*?) (\d+) (\d+):(\d+):(\d+) (\d+)/
					day = $2
					hour = $3
					minute = $4
					second = $5
					year = $6
					month = $1
					res << {
						:id => seq,
						:time => Time.local($6, $1, $2, $3, $4, $5),
						:where => "#{ctl}:#{chn}:#{tgt}",
						:what => event,
					}
				end
			}
			return res
		end

		# ======================================================================

		def _task_list
			res = []
			return res
		end

		# ======================================================================

		def _logical_list
			@logical = []
			num = nil
			megarc("-ldinfo #{@args} -Lall").each { |l|
				case l
				when /^Logical Drive\s*:\s*(\d+).*Status:\s*(.*?)\s*$/
					num = $1.to_i
					state = $2.downcase
					state = 'normal' if state == 'optimal'
					@logical[num] = {
						:num => num,
						:state => state,
						:physical => [],
						:physical_sizes => [],
						:dev => @dev[num],
					}
				when /SpanDepth\s*:\s*(.*?)\s+RaidLevel\s*:\s*(.*?)\s+RdAhead\s*:\s*(.*?)\s+Cache\s*:\s*(.*?)\s*$/
					@logical[num][:raid_level] = $2
				when /^(\d+)\s+(\d+)\s+0x(.*?)\s+0x(.*?)\s+(.*)$/
					@logical[num][:physical] << "#{$1.to_i}:#{$2.to_i}"
					@logical[num][:physical_sizes] << sectors2mb($4.hex)
				end
			}

			# LSI megarc doesn't know about real usable size of
			# logical disc - we have to calculate it ourselves
			@logical.each { |l|
				# RAID requires add physical partition sizes to be the same
				raise Error.new('Invalid RAID physical sizes encountered') if l[:physical_sizes].uniq.size != 1

				disc_size = l[:physical_sizes][0]
				disc_num = l[:physical_sizes].size

				# Formulas can be checked at
				# http://www.ibeast.com/content/tools/RaidCalc/RaidCalc.asp
				l[:capacity] = case l[:raid_level].to_i
				when 0
					disc_size * disc_num
				when 1
					disc_size / 2 # RAID 1 can't be other than 2 discs
				when 5
					disc_size * (disc_num - 1)
				else
					'?'
				end
			}
			return @logical
		end

		def logical_add(raid_level, discs = nil, sizes = nil, options = nil)

			# LSI doesn't support passthrough discs - emulate using RAID0
			raid_level = 0 if raid_level == 'passthrough'

			cmd = "-addCfg #{@args} -R#{raid_level}"
			cmd += ("[" + (discs.is_a?(Array) ? discs.join(',') : discs) + "]") if discs
			if sizes
				sizes = sizes.split(/,/) if sizes.respond_to?(:split)
				sizes = [sizes] unless sizes.respond_to?(:each)
				sizes.each { |s| cmd += " -sz#{s}" }
			end

			# GREYFIX: add stripe size option
			#cmd .= " -strpsz#{stripe_size}" if stripe_size;

			out = megarc(cmd)
			raise Error.new(out.join("\n")) if $?.exitstatus != 0

			out.each { |l|
				if l =~ /Unused Size.*? goes to extra logical drive-(.*)$/
					dout = megarc("-DelLd #{@args} -l#{$1}")
					raise Error.new(dout.join("\n") + ' while deleting extra filler logical drives') if $?.exitstatus != 0
				end
			}
		end

		def logical_delete(id)
			out = megarc("-DelLd #{@args} -l#{id}")
			raise Error.new(out.join("\n")) if $?.exitstatus != 0
		end

		def logical_clear
			out = megarc("-clrCfg #{@args}");
			raise Error.new(out.join("\n")) if $?.exitstatus != 0
		end

		def _physical_list
			@physical = {}
			channel = -2
			id = nil

			megarc("-logphysinfo #{@args}").each { |l|
				if channel == -2
					channel = -1 if l =~ /Physical Drive Information/
				else
					if l =~ /Channel (\d+)/
						channel = $1.to_i
					elsif l =~ /(\d+)MB drive.*ID\s+(\d+)/
						id = $2.to_i;
						@physical["#{channel}:#{id}"] = {
							:size => $1.to_i,
							:state => [],
						}
					end
				end
			}

			phys = nil

			megarc("-phys #{@args} -chAll -idAll").each { |l|
				case l
				when /Adapter \d+, Channel (\d+), Target ID (\d+)/
					phys = @physical["#{$1}:#{$2}"]
				when /Type\s*:\s*(.*?)\s+Vendor\s*:\s*(.*?)\s*$/
					phys[:vendor] = $2
				when /Product\s*:\s*(.*?)\s+Revision\s*:\s*(.*?)\s*$/
					phys[:model] = $1
					phys[:model] = phys[:vendor] + ' ' + phys[:model] if phys[:vendor]
					phys[:revision] = $2
				end
			}

			megarc("-physdrvSerialInfo #{@args} -chAll -idAll").each { |l|
				case l
				when /Adapter \d+, Channel (\d+), Target ID (\d+)/
					phys = @physical["#{$1}:#{$2}"]
				when /PhysDrvSerial#: (.*)/
					phys[:serial] = $1
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
			megarc "-ShowAlarm #{@args}"
		end

		def get_adapter_rebuildrate(x = nil)
			megarc("-GetRbldrate #{@args}")
		end

		def get_adapter_coercion(x = nil)
			l = megarc("-CoercionVu #{@args}")[0]
			return (case l
				when /^Coercion flag OFF/ then 0
				when /^Coercion flag ON/  then 1
			end)
		end

		def set_adapter_coercion_0(x)
			megarc("-CoercionOff #{@args}")
		end

		def set_adapter_coercion_1(x)
			megarc("-CoercionOn #{@args}")
		end

		def set_physical_hotspare_0(drv)
			megarc("-physSetHsp #{@args} pd[#{drv}]")
		end

		def set_physical_hotspare_1(drv)
			megarc("-physUnsetHsp #{@args} pd[#{drv}]")
		end

		def set_logical_readahead_on(id)
			megarc("-cldCfg #{@args} -L#{id} RA")
		end

		def set_logical_readahead_off(id)
			megarc("-cldCfg #{@args} -L#{id} RAN")
		end

		def set_logical_readahead_adaptive(id)
			megarc("-cldCfg #{@args} -L#{id} RAA")
		end

		def set_logical_write_writethrough(id)
			megarc("-cldCfg #{@args} -L#{id} WT")
		end

		def set_logical_write_writeback(id)
			megarc("-cldCfg #{@args} -L#{id} WB")
		end

		def set_logical_io_direct(id)
			megarc("-cldCfg #{@args} -L#{id} DIO")
		end

		def set_logical_io_cache(id)
			megarc("-cldCfg #{@args} -L#{id} CIO")
		end

		# ======================================================================

		private

		def megarc(command)
			out = `#{MEGARC} #{command}`.split("\n")
			out.slice!(0..9)
			out.collect! { |l| l.strip! }
			out.delete_if { |l| l =~ /^Finding Devices On / or l =~ /Scanning Ha / or l =~ /^\*\*\*\*\*\*/ or l.nil? }
#			puts out.join("\n"); puts "--------- OUTPUT FOLLOWS:"
			return out
		end

		def self.megarc(command)
			out = `#{MEGARC} #{command}`.split("\n")
			out.slice!(0..10)
			return out
		end

		def sectors2mb(x)
			x / 2048
		end
	end
end
