module RAID

	VERSION = '1.4'

	# We have no modules loaded by default

	class Error < RuntimeError
		attr_reader :text

		def initialize(text)
			super
			@text = text.dup
		end
	end

	class BaseRaid
		attr_accessor :logical
		attr_accessor :physical

		METHODS = {
			'adapter' => %w(info restart get set),
			'log' => %w(clear list test discover dump),
			'physical' => %w(list get set),
			'logical' => %w(list add delete clear get set hotspare_add hotspare_delete physical_list),
			'task' => %w(list wait),
			'firmware' => %w(read write),
			'bbu' => %w(info)
		}

		def self.query_adapters
			res = []
			RAIDS.each_value { |r| r.query(res) }
			return res
		end

		def self.list_adapters
			res = query_adapters
			if $humanize
				puts "Type           Adapter #  Model                         Version"
				res.each { |a|
					printf(
						"%-15s%-11d%-30s%s\n",
						a[:driver], a[:num], a[:model], a[:version]
					)
				}
			else
				res.each { |a| puts "#{a[:driver]}\t#{a[:num]}\t#{a[:model]}\t#{a[:version]}" }
			end
		end

		def adapter_info
			_adapter_info.each_pair { |k, v|
				if $humanize
					printf "%-30s%s\n", k, v
				else
					puts "#{k}\t#{v}"
				end
			}
		end

		def log_list
			if $humanize then
				printf "%-4s%-32s%-20s%s\n", '#', 'Time', 'Where', 'What'
				_log_list.each { |l|
					printf "%-4s%-32s%-20s%s\n", l[:id], l[:time], l[:where], l[:what]
				}
			else
				_log_list.each { |l|
					puts "#{l[:id]}\t#{l[:time].strftime('%Y-%m-%d %H:%M:%S')}\t#{l[:where]}\t#{l[:what]}"
				}
			end
		end

		def log_discover
			if $humanize then
				if _log_discover.size > 0 then
					puts "Available log subsystems: " + _log_discover.join(", ")
				else
					puts "Adapter does not support log subsystems selection"
				end
			else
				puts _log_discover
			end
		end

		def log_dump(subsys = nil)
			concatenated_logs = ""
			if not subsys then
				_log_discover.each{ |ss| concatenated_logs << _log_dump(ss) }
			else
				raise Error.new("No such subsystem; available susbsystems: #{_log_discover.join(", ")}") unless _log_discover.include?(subsys)
				concatenated_logs = _log_dump(subsys)
			end

			puts concatenated_logs
		end

		def log_clear(subsys = nil)
			if not subsys then
				_log_discover.each{ |ss| _log_clear(ss) }
			else
				raise Error.new("No such subsystem; available susbsystems: #{_log_discover.join(", ")}") unless _log_discover.include?(subsys)
				_log_clear(subsys)
			end
		end

		def task_list
			if $humanize then
				printf "%-5s%-12s%-20s%s\n", '#', 'Where', 'What', 'Progress'
				_task_list.each { |l|
					printf "%-5s%-12s%-20s%s\n", l[:id], l[:where], l[:what], l[:progress]
				}
			else
				_task_list.each { |l|
					puts "#{l[:id]}\t#{l[:where]}\t#{l[:what]}\t#{l[:progress]}"
				}
			end
		end

		def task_wait
			tl = _task_list
			while not tl.empty? do
				yield(tl.collect { |l| l[:progress].to_s }.join(', ')) if block_given?
				sleep 60
				tl = _task_list
			end
		end

		def logical_list
			if $humanize then
				puts "#  RAID level   Physical drives                 Capacity     Device  State"
				_logical_list.each { |d|
					next unless d
					printf(
						"%-3d%-13s%-30s%10.2f MB  %-9s%s\n",
						d[:num], d[:raid_level], d[:physical].join(','), d[:capacity], d[:dev], d[:state]
					)
				}
			else
				_logical_list.each { |d|
					next unless d
					puts [d[:num], d[:raid_level], d[:physical].join(','), d[:capacity], d[:dev], d[:state]].join("\t")
				}
			end
		end

		def logical_physical_list(ld)
			if $humanize then
				puts "ID      State"
				_logical_physical_list(ld).each{ |d|
					printf("%-8s%s\n", d[:num], d[:state])
				}
			else
				_logical_physical_list(ld).each{ |d|
					puts [d[:num], d[:state]].join("\t")
				}
			end
		end

		def physical_list
			if $humanize then
				puts "ID      Model                    Revision       Serial                     Size     State"
				_physical_list.each_pair { |num, d|
					printf(
						"%-8s%-25s%-15s%-20s%11.2f MB  %s\n",
						num, d[:model], d[:revision], d[:serial], d[:size], 
							d[:state].is_a?(Array) ? d[:state].join(",") : d[:state]
					)
				}
			else
				_physical_list.each_pair { |num, d|
					puts "#{num}\t#{d[:model]}\t#{d[:revision]}\t#{d[:serial]}\t#{d[:size]}\t#{d[:state].is_a?(Array) ? d[:state].join(",") : d[:state]}"
				}
			end
		end
		
		def bbu_info
		    info = _bbu_info
		    if $humanize then
			puts "Manufacturer   Model    Serial  Capacity"
			printf("%-15s%-9s%-8s%-15s\n",
			info[:vendor], info[:device], info[:serial], info[:capacity])
		    else
			puts "#{info[:vendor]}\t#{info[:device]}\t#{info[:serial]}\t#{info[:capacity]}"				
		    end
		end

		def handle_property(obj_name, command, obj_num, prop_name, value = nil)
#			p obj_name, obj_num, command, prop_name, value

			avail = public_methods.grep(/^#{command}_#{obj_name}_/).collect { |x|
				x.gsub!(/^#{command}_#{obj_name}_/, '')
				x.gsub!(/_.*?$/, '') if x =~ /_/
				x
			}.uniq.join(', ')

			raise Error.new("Property not specified; available properties: #{avail}") unless prop_name

			case command
			when 'get'
				method_name = "get_#{obj_name}_#{prop_name}"
				raise Error.new("Unknown property '#{prop_name}'; available properties: #{avail}") if public_methods.grep(method_name).empty?
				puts send(method_name, obj_num)
			when 'set'
				if not public_methods.grep("set_#{obj_name}_#{prop_name}_#{value}").empty?
					send("set_#{obj_name}_#{prop_name}_#{value}", obj_num)
				elsif not public_methods.grep("set_#{obj_name}_#{prop_name}").empty?
					send("set_#{obj_name}_#{prop_name}", obj_num, value)
				else
					possible = public_methods.grep(/^set_#{obj_name}_#{prop_name}_/).collect { |x|
						x.gsub!(/^set_#{obj_name}_#{prop_name}_/, '')
					}
					raise Error.new(
						if possible.empty?
							"Unknown property '#{prop_name}'; available properties: #{avail}"
						else
							"Invalid value for property '#{prop_name}'; valid values: " + possible.join(', ')
						end
					)
				end
			end
		end

		def handle_method(arg)
			obj_name = arg.shift
			raise Error.new('Object not specified; available objects: ' + METHODS.keys.join(', ')) unless obj_name
			obj = self.class::METHODS[obj_name]
			raise Error.new("Unknown object '#{obj_name}'; available objects: " + METHODS.keys.join(', ')) unless obj

			command = arg.shift
			raise Error.new('Command not specified; available commands: ' + obj.join(', ')) unless command
			raise Error.new("Unknown command '#{command}' in object '#{obj_name}'; available commands: " + obj.join(', ')) if obj.grep(command).empty?

			if command == 'set' or command == 'get'
				if obj_name == 'adapter'
					handle_property(obj_name, command, nil, arg[0], arg[1])
				else
					raise Error.new('Object identifier not specified') unless arg[0]
					handle_property(obj_name, command, arg[0], arg[1], arg[2])
				end
			else
				send("#{obj_name}_#{command}", *arg)
			end
		end

		private
		def restart_module(mod)
			msg = `rmmod -f #{mod}`
			raise Error.new(msg) if $?.exitstatus != 0
			empty = File.open('/proc/partitions').readlines

			msg = `modprobe #{mod}`
			raise Error.new(msg) if $?.exitstatus != 0
			full = File.open('/proc/partitions').readlines

			@dev = []
			(full - empty).each { |l|
				name = l[22..-2]
				@dev << name unless name =~ /\d$/
			}
		end

		def find_dev_by_name(name)
			for dir in Dir["/sys/block/*/device/"]
				dev = dir.gsub(/^\/sys\/block/, '/dev').gsub(/\/device\/$/, '')
				mpath = dir + 'model'
				next unless File.readable?(mpath)
				name_read = File.open(mpath) do |f|
					f.readline.chomp.strip;
				end
				return dev if name_read == name
			end
			return nil
		end
	end
end

require 'raid/build-config'
begin
	require "#{$EINARC_VAR}/config"
rescue LoadError
	RAID::RAIDS = {}
end
