# encoding: utf-8

require 'oj'
require 'rugged'
require 'singleton'
require_relative 'formatador'

class String
	def underscore
		gsub(/::/, '/').gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
				.gsub(/([a-z\d])([A-Z])/, '\1_\2'). tr("-", "_").downcase
	end

	def camel_case
		return self if self !~ /_/ && self =~ /[A-Z]+.*/
		split('_').map(&:capitalize).join
	end

	def id
		gsub(/[^[\w-]]+/, "_")
	end
end

module Diggit
	class Source
		attr_reader :url, :repository
		attr_accessor :entry

		def initialize(url)
			@url = url
			@entry = Journal.new_source_entry
			@repository = nil
		end

		def id
			@url.id
		end

		def folder
			Dig.it.file_path("sources/#{id}")
		end

		def error?
			!(@entry[:last_error].nil? || @entry[:last_error].empty?)
		end

		def error
			@entry[:last_error]
		end

		def error=(error)
			@entry[:last_error] = error
		end

		def state
			@entry[:state]
		end

		def state=(state)
			@entry[:state] = state
		end

		def new?
			@entry[:state] == :new
		end

		def cloned?
			@entry[:state] == :cloned
		end

		def add_performed_analysis(name)
			@entry[:performed_analyses] << name
		end

		def analysis_performed?(name)
			@entry[:performed_analyses].include?(name)
		end

		def analyses_performed?(*names)
			(names - @entry[:performed_analyses]).empty?
		end

		def del_performed_analysis(name)
			@entry[:performed_analyses].delete_if { |a| a == name }
		end

		def add_ongoing_analysis(name)
			@entry[:ongoing_analyses].include?(name)
		end

		def del_ongoing_analysis(name)
			@entry[:ongoing_analyses].delete_if { |a| a == name }
		end

		def analysis_ongoing?(name)
			@entry[:ongoing_analyses].include?(name)
		end

		def analyses_ongoing?(*names)
			(names - @entry[:ongoing_analyses]).empty?
		end

		def analysis?(name)
			analysis_ongoing?(name) || analysis_performed?(name)
		end

		def del_analysis(name)
			del_ongoing_analysis(name)
			del_performed_analysis(name)
		end

		def clone
			if File.exist?(folder)
				Rugged::Repository.new(folder)
			else
				Rugged::Repository.clone_at(url, folder)
			end
			self.state = :cloned
		rescue => e
			Log.error "Error cloning #{url}."
			self.error = Journal.dump_error(e)
		end

		def load_repository
			fail "Source not cloned #{url}." if new?
			@repository = Rugged::Repository.new(folder)
		end
	end

	class Journal
		def initialize(hash)
			@sources = {}
			@workspace = {}
			hash[:urls].each do |u|
				s = Source.new(u)
				s.entry = hash[:sources][u] if !hash[:sources].nil? && hash[:sources].key?(u)
				@sources[u] = s
			end
			@workspace = hash[:workspace]
			@workspace = Journal.new_workspace_entry if hash[:workspace].nil? || hash[:workspace].empty?
		end

		def sources
			@sources.values
		end

		def sources_by_state(state, error = false)
			@sources.select { |_u, s| s.state == state && s.error? == error }.values
		end

		def sources_by_ids(*ids)
			return sources if ids.empty?
			source_array = sources
			result = []
			ids.each do |id|
				fail "No such source index #{id}." if id >= source_array.length
				result << source_array[id]
			end
			result
		end

		def update_source(source)
			fail "No such source #{source}." unless @sources.key?(source.url)
			@sources[source.url] = source
			Dig.it.save_journal
		end

		def add_source(url)
			@sources[url] = Source.new(url) unless @sources.key?(url)
			Dig.it.save_journal
		end

		def join?(name)
			@workspace[:performed_joins].include?(name)
		end

		def add_join(name)
			@workspace[:performed_joins] << name
			Dig.it.save_journal
		end

		def join_error?
			!@workspace[:last_error].nil?
		end

		def join_error
			@workspace[:last_error]
		end

		def join_error=(error)
			@workspace[:last_error] = Journal.dump_error(error)
			Dig.it.save_journal
		end

		def to_hash
			entry_hash = {}
			@sources.each { |entry| entry_hash[entry[0]] = entry[1].entry }
			{ urls: @sources.keys, sources: entry_hash, workspace: @workspace }
		end

		def self.new_source_entry
			{ state: :new, performed_analyses: [], error_analyses: [], ongoing_analyses: [], last_error: {} }
		end

		def self.new_workspace_entry
			{ performed_joins: [], last_error: {} }
		end

		def self.dump_error(error)
			{ name: error.class.name, message: error.to_s, backtrace: error.backtrace }
		end
	end

	class Config
		attr_reader :analyses, :joins

		def initialize(hash)
			@analyses = []
			@joins = []
			hash[:analyses].each { |a| load_analysis(a) }
			hash[:joins].each { |j| load_join(j) }
		end

		def to_hash
			{ analyses: @analyses.map(&:name), joins: @joins.map(&:name) }
		end

		def add_analysis(name)
			load_analysis(name) unless @analyses.map(&:name).include?(name)
			Dig.it.save_config
		end

		def load_analysis(name)
			@analyses << Dig.it.plugin_loader.load_plugin(name, :analysis)
		end

		def del_analysis(name)
			@analyses.delete_if { |a| a.name == name }
			Dig.it.save_config
		end

		def get_analyses(*names)
			return analyses if names.empty?
			analyses.select { |a| names.include?(a.name) }
		end

		def add_join(name)
			load_join(name) unless @joins.map(&:name).include?(name)
			Dig.it.save_config
		end

		def load_join(name)
			@joins << Dig.it.plugin_loader.load_plugin(name, :join)
		end

		def del_join(name)
			@joins.delete_if { |j| j.name == name }
			Dig.it.save_config
		end

		def get_joins(*names)
			return joins if names.empty?
			joins.select { |j| joins.include?(j.name) }
		end

		def self.empty_config
			{ analyses: [], joins: [] }
		end
	end

	class PluginLoader
		include Singleton

		PLUGINS_TYPES = [:addon, :analysis, :join]

		def load_plugin(name, type, instance = false)
			plugin = search_plugin(name, type)
			if plugin
				if instance
					return plugin.new(Dig.it.options)
				else
					return plugin
				end
			else
				fail "Plugin #{name} not found."
			end
		end

		def search_plugin(name, type)
			plugin = nil
			if @plugins.key?(name)
				plugin = @plugins[name]
			else
				fail "Unknown plugin type #{type}." unless PLUGINS_TYPES.include?(type)
				if load_file(name, type)
					plugin = Object.const_get(name.camel_case)
					base_class = Object.const_get("Diggit::#{type.to_s.camel_case}")
					if plugin < base_class
						@plugins[name] = plugin
					else
						fail "Plugin #{name} not of kind #{type}."
					end
				end
			end
			plugin
		end

		def load_file(name, type)
			f_glob = PluginLoader.plugin_path(name, type, File.expand_path('../..', File.dirname(File.realpath(__FILE__))))
			f_home = PluginLoader.plugin_path(name, type, File.expand_path(Dig::DGIT_FOLDER, Dir.home))
			f_local = PluginLoader.plugin_path(name, type, Dig.it.folder)
			found = true
			if File.exist?(f_local)
				require f_local
			elsif File.exist?(f_home)
				require f_home
			elsif File.exist?(f_glob)
				require f_glob
			else
				found = false
			end
			found
		end

		def self.plugin_path(name, type, root)
			File.expand_path("#{name}.rb", File.expand_path(type.to_s, File.expand_path('plugins', root)))
		end

		def initialize
			@plugins = {}
		end
	end

	# Main diggit class.
	# It must be runned in a folder containing a `.dgit` folder with a proper configuration.
	# Access configuration, options, sources and journal from this object.
	# It implements the singleton pattern.
	# You can initialize it via {.init} and retrieve the instance via {.it}.
	# @!attribute [r] config
	# 	@return [Config] the config (serialized in .dgit/config).
	# @!attribute [r] options
	# 	@return [Hash<String,Object>] the options (serialized in .dgit/options).
	# @!attribute [r] journal
	# 	@return [Journal] the journal (serialized in .dgit/journal).
	# @!attribute [r] folder
	# 	@return [String] the folder in which diggit is running.
	# @!attribute [r] plugin_loader
	# 	@return [PluginLoader] utility classes to load plugins.
	class Dig
		DGIT_FOLDER = ".dgit"
		DGIT_SOURCES = "sources"
		DGIT_CONFIG = "config"
		DGIT_OPTIONS = "options"
		DGIT_JOURNAL = "journal"

		private_constant :DGIT_SOURCES, :DGIT_CONFIG, :DGIT_OPTIONS, :DGIT_JOURNAL

		attr_reader :config, :options, :journal, :plugin_loader, :folder

		@diggit = nil

		# Returns the diggit instance.
		# @return Dig the instance.
		def self.it
			fail "Diggit has not been initialized." if @diggit.nil?
			@diggit
		end

		# Initialize and return the diggit instance.
		# @return Dig the instance.
		def self.init(folder = '.')
			@diggit = Dig.new(folder)
			@diggit.load_options
			@diggit.load_config
			@diggit.load_journal
			@diggit
		end

		# Initialize a folder to be a diggit folder by creating an empty configuration.
		# @param folder the path to the folder.
		def self.init_dir(folder = '.')
			dgit_folder = File.expand_path(DGIT_FOLDER, folder)
			FileUtils.mkdir(dgit_folder)
			Oj.to_file(File.expand_path(DGIT_CONFIG, dgit_folder), Config.empty_config)
			Oj.to_file(File.expand_path(DGIT_OPTIONS, dgit_folder), {})
			FileUtils.touch(File.expand_path(DGIT_SOURCES, dgit_folder))
			Oj.to_file(File.expand_path(DGIT_JOURNAL, dgit_folder), {})
			FileUtils.mkdir(File.expand_path('sources', folder))
		end

		def initialize(folder)
			fail "Folder #{folder} is not a diggit folder." unless File.exist?(File.expand_path(DGIT_FOLDER, folder))
			@plugin_loader = PluginLoader.instance
			@folder = folder
		end

		def load_journal
			url_array = []
			IO.readlines(config_path(DGIT_SOURCES)).each { |l| url_array << l.strip }
			saved_hash = Oj.load_file(config_path(DGIT_JOURNAL))
			hash = { urls: url_array, sources: saved_hash[:sources], workspace: saved_hash[:workspace] }
			@journal = Journal.new(hash)
		end

		def save_journal
			hash = @journal.to_hash
			File.open(config_path(DGIT_SOURCES), "w") { |f| hash[:urls].each { |u| f.puts(u) } }
			Oj.to_file(config_path(DGIT_JOURNAL), { sources: hash[:sources], workspace: hash[:workspace] })
		end

		def load_options
			@options = Oj.load_file(config_path(DGIT_OPTIONS))
		end

		def save_options
			Oj.to_file(config_path(DGIT_OPTIONS), options)
		end

		def load_config
			@config = Config.new(Oj.load_file(config_path(DGIT_CONFIG)))
		end

		def save_config
			config_hash = @config.to_hash
			Oj.to_file(config_path(DGIT_CONFIG), config_hash)
		end

		def clone(*source_ids)
			@journal.sources_by_ids(*source_ids).select(&:new?).each(&:clone)
		ensure
			save_journal
		end

		def analyze(source_ids = [], analyses = [], mode = :run)
			@journal.sources_by_ids(*source_ids).select(&:cloned?).each do |s|
				@config.get_analyses(*analyses).each do |klass|
					a = klass.new(@options)
					s.load_repository
					a.source = s
					clean_analysis(s, a) if clean_mode?(mode) && s.analysis?(a.name)
					run_analysis(s, a) if run_mode?(mode) && !s.analysis_performed?(a.name)
				end
			end
		end

		def clean_mode?(mode)
			mode == :rerun || mode == :clean
		end

		def run_mode?(mode)
			mode == :rerun || mode == :run
		end

		def clean_analysis(s, a)
			a.clean
			s.del_analysis(a.name)
		ensure
			save_journal
		end

		def run_analysis(s, a)
			s.add_ongoing_analysis(a.name)
			a.run
			s.del_ongoing_analysis(a.name)
			s.add_performed_analysis(a.name)
		rescue => e
			Log.error "Error applying analysis #{a.name} on #{s.url}"
			s.error = Journal.dump_error(e)
		ensure
			save_journal
		end

		def join(source_ids = [], joins = [], mode = :run)
			@config.get_joins(*joins).each do |klass|
				j = klass.new(@options)
				j.clean if clean_mode?(mode)
				source_array = @journal.sources_by_ids(*source_ids)
						.select { |s| s.cloned? && s.analyses_performed?(*klass.required_analyses) }
				run_join(j, source_array) if run_mode?(mode) && !source_array.empty?
			end
		end

		def run_join(j, source_array)
			j.sources = source_array
			j.run
			@journal.add_join(j.name)
		rescue => e
			Log.error "Error applying join #{j.name}"
			@journal.join_error = e
		ensure
			save_journal
		end

		def config_path(name)
			File.expand_path(name, File.expand_path(DGIT_FOLDER, @folder))
		end

		def file_path(name)
			File.expand_path(name, @folder)
		end
	end
end