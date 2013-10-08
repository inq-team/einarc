module RAID
	VERSION = '2.0'

	# We have no modules loaded by default
end

require 'raid/baseraid'

require 'raid/build-config'
begin
	require "#{$EINARC_VAR}/config"
rescue LoadError
	RAID::RAIDS = {}
end
