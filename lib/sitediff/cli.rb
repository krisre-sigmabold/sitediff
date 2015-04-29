require 'thor'
require 'sitediff/diff'
require 'sitediff/sanitize'
require 'sitediff/fetch'
require 'sitediff/cache'
require 'sitediff/util/webserver'
require 'sitediff/config/creator'
require 'open-uri'
require 'uri'

class SiteDiff
  class Cli < Thor
    class_option 'directory',
      :type => :string,
      :aliases => '-C',
      :desc => "Go to a given directory before running."

    # Thor, by default, exits with 0 no matter what!
    def self.exit_on_failure?
      true
    end

    # Thor, by default, does not raise an error for use of unknown options.
    def self.check_unknown_options?(config)
      true
    end

    option 'dump-dir',
      :type => :string,
      :default => File.join('.', 'output'),
      :desc => "Location to write the output to."
    option 'paths-file',
      :type => :string,
      :desc => 'Paths are read (one at a line) from PATHS: ' +
               'useful for iterating over sanitization rules',
      :aliases => '--paths-from-file'
    option 'paths',
      :type => :array,
      :aliases => '-p',
      :desc => "Fetch only these specific paths"
    option 'before',
      :type => :string,
      :desc => "URL used to fetch the before HTML. Acts as a prefix to specified paths",
      :aliases => '--before-url'
    option 'after',
      :type => :string,
      :desc => "URL used to fetch the after HTML. Acts as a prefix to specified paths.",
      :aliases => '--after-url'
    option 'before-report',
      :type => :string,
      :desc => "Before URL to use for reporting purposes. Useful if port forwarding.",
      :aliases => '--before-url-report'
    option 'after-report',
      :type => :string,
      :desc => "After URL to use for reporting purposes. Useful if port forwarding.",
      :aliases => '--after-url-report'
    option 'cached',
      :type => :string,
      :enum => %w[none all before after],
      :default => 'before',
      :desc => "Use the cached version of these sites, if available."
    desc "diff [OPTIONS] [CONFIGFILES]", "Perform systematic diff on given URLs"
    def diff(*config_files)
      config = chdir(config_files)

      # override config based on options
      paths = options['paths']
      if paths_file = options['paths-file']
        if paths then
          SiteDiff::log "Can't have both --paths-file and --paths", :error
          exit -1
        end

        unless File.exists? paths_file
          raise Config::InvalidConfig,
            "Paths file '#{paths_file}' not found!"
        end
        SiteDiff::log "Reading paths from: #{paths_file}"
        config.paths = File.readlines(paths_file)
      end
      config.paths = paths if paths

      config.before['url'] = options['before'] if options['before']
      config.after['url'] = options['after'] if options['after']

      cache = SiteDiff::Cache.new
      cache.write_tags << :before << :after
      cache.read_tags << :before if %w[before all].include?(options['cached'])
      cache.read_tags << :after if %w[after all].include?(options['cached'])

      sitediff = SiteDiff.new(config, cache, !options['quiet'])
      sitediff.run

      failing_paths = File.join(options['dump-dir'], 'failures.txt')
      sitediff.dump(options['dump-dir'], options['before-report'],
        options['after-report'], failing_paths)
    rescue Config::InvalidConfig => e
      SiteDiff.log "Invalid configuration: #{e.message}", :error
    rescue SiteDiffException => e
      SiteDiff.log e.message, :error
    end

    option :port,
      :type => :numeric,
      :default => SiteDiff::Util::Webserver::DEFAULT_PORT,
      :desc => 'The port to serve on'
    option 'dump-dir',
      :type => :string,
      :default => 'output',
      :desc => 'The directory to serve'
    desc "serve [OPTIONS]", "Serve the sitediff output directory over HTTP"
    def serve
      chdir([], :config => false)

      SiteDiff::Util::Webserver.serve(options[:port], options['dump-dir'],
        :announce => true).wait
    end

    option :output,
      :type => :string,
      :default => 'sitediff',
      :desc => 'Where to place the configuration',
      :aliases => ['-o']
    option :depth,
      :type => :numeric,
      :default => 3,
      :desc => 'How deeply to crawl the given site'
    option :rules,
      :type => :string,
      :enum => %w[yes no disabled],
      :default => 'disabled',
      :desc => 'Whether rules for the site should be auto-created'
    desc "init URL [URL]", "Create a sitediff configuration"
    def init(*urls)
      creator = SiteDiff::Config::Creator.new(*urls)
      creator.create(
        :depth => options[:depth],
        :directory => options[:output],
        :rules => options[:rules] != 'no',
        :rules_disabled => (options[:rules] == 'disabled'),
      ) do |tag, info|
        SiteDiff.log "Visited #{info.uri}, cached"
      end

      SiteDiff.log "Created #{creator.config_file}", :success
      SiteDiff.log "You can now run 'sitediff diff'", :success
    end

    option :url,
      :type => :string,
      :desc => 'A custom base URL to fetch from'
    desc "store [CONFIGFILES]",
      "Cache the current contents of a site for later comparison"
    def store(*config_files)
      config = chdir(config_files)
      config.validate(:need_before => false)

      cache = SiteDiff::Cache.new
      cache.write_tags << :before

      base = options[:url] || config.after['url']
      fetcher = SiteDiff::Fetch.new(cache, config.paths, :before => base)
      fetcher.run do |path, res|
        SiteDiff.log "Visited #{path}, cached"
      end
    end

  private
    def chdir(files, opts = {})
      opts = { :config => true }.merge(opts)

      dir = options['directory']
      Dir.chdir(dir) if dir

      if opts[:config]
        SiteDiff::Config.new(files, :search => !dir)
      elsif !dir
        SiteDiff::Config.search
      end
    end
  end
end
