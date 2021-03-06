require 'yaml'
require 'hashie'

module SportNginAwsAuditor

  class DefaultPaths
    class << self
      def config
        File.join(self.home,'.aws_auditor.yml')
      end

      def home
        ENV['HOME'] ? ENV['HOME'] : "."
      end
    end
  end

  class Config
    class << self

      def config
        config_data.to_hash
      end

      def load(path)
        if File.exist?(path)
          load_config(path)
          return config
        else
          return {}
        end
      end

      def config_data
        @config_data ||= Hashie::Mash.new
      end
      private :config_data

      def method_missing(method, args=false)
        config_data.send(method, args)
      end
      private :method_missing

      def load_config(file)
        YAML.load_file(file).each{ |key,value| config_data.assign_property(key, value) }
      end
      private :load_config

    end
  end
end
