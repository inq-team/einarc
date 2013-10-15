# Einarc module is a namespace for all classes that implement Einarc
# adapters functionality.
module Einarc
	# Current version constant.
	VERSION = '2.0'
end

require 'einarc/baseraid'

require 'einarc/build-config'
begin
	require "#{Einarc::EINARC_VAR}/config"
rescue LoadError
	Einarc::RAIDS = {}
end
