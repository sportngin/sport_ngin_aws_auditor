require 'highline/import'
require 'colorize'
require 'aws-sdk'
require_relative "../notify_slack"
require_relative "../instance"
require_relative "../audit_data"

module SportNginAwsAuditor
  module Scripts
    class Audit
      extend AWSWrapper

      class << self
        attr_accessor :options, :audit_results
      end

      #################### EXECUTION ####################

      def self.execute(environment, options, global_options)
        aws(environment, global_options)
        collect_options(options, global_options)
        print_title
        @regions.each { |region| audit_region(region) }
      end

      def self.audit_region(region)
        print_region(region)
        @instance_types.each { |type| audit_instance_type(type, region) }
      end

      def self.audit_instance_type(type, region)
        @class = type.first
        @audit_results = AuditData.new({:instances => options[:instances], :reserved => options[:reserved],
                                        :class => type.first.to_s, :tag_name => @tag_name,
                                        :regexes => @ignore_instances_regexes, :region => region})
        @audit_results.gather_data

        unless @audit_results.data.empty?
          print_instance_type(type)
          print_audit_results if (type.last || @no_selection)
        end
      end

      def self.print_audit_results
        @audit_results.data.sort_by! { |instance| [instance.category, instance.type] }

        if @slack
          print_to_slack
        elsif options[:reserved] || options[:instances]
          @audit_results.data.each{ |instance| say "<%= color('#{instance.type}: #{instance.count}', :white) %>" }
        else
          print_to_terminal
        end
      end

      #################### PRINTING DATA TO TERMINAL ####################

      def self.print_to_terminal
        say_instances
        say_retired_ris unless @audit_results.retired_ris.empty?
        say_retired_tags unless @audit_results.retired_tags.empty?
      end

      def self.say_instances
        @audit_results.data.each do |instance|
          name = !@zone_output && (instance.tagged? || instance.running?) ? print_without_zone(instance.type) : instance.type
          count = instance.count
          color, rgb, prefix = color_chooser(instance)
          
          if instance.tagged?
            if instance.reason
              say "<%= color('#{prefix} #{name}: (expiring on #{instance.tag_value} because #{instance.reason})', :#{color}) %>"
            else
              say "<%= color('#{prefix} #{name}: (expiring on #{instance.tag_value})', :#{color}) %>"
            end
          elsif instance.ignored?
            say "<%= color('#{prefix} #{name}', :#{color}) %>"
          else
            say "<%= color('#{prefix} #{name}: #{count}', :#{color}) %>"
          end
        end
      end

      def self.say_retired_ris
        retired_ris = @audit_results.retired_ris
        say "The following reserved #{@class}Instances have recently expired in #{@display_name}:"

        retired_ris.each do |ri|
          if ri.availability_zone.nil?
            # if ri.to_s = 'Linux VPC  t2.small'...
            my_match = ri.to_s.match(/(\w*\s*\w*\s{1})\s*(\s*\S*)/)

            # then platform = 'Linux VPC '...
            platform = my_match[1] if my_match

            # and size = 't2.small'
            size = my_match[2] if my_match

            n = "#{platform}#{@audit_results.region} #{size}"
            say "#{n} (#{ri.count}) on #{ri.expiration_date}"
          else
            say "#{ri.to_s} (#{ri.count}) on #{ri.expiration_date}"
          end
        end
      end

      def self.say_retired_tags
        retired_tags = @audit_results.retired_tags
        say "The following #{@class}Instance tags have recently expired in #{@display_name}:"

        retired_tags.each do |tag|
          if tag.reason
            say "#{tag.instance_name} (#{tag.instance_type}) retired on #{tag.value} because #{tag.reason}"
          else
            say "#{tag.instance_name} (#{tag.instance_type}) retired on #{tag.value}"
          end
        end
      end

      #################### PRINTING DATA TO SLACK ####################

      def self.print_to_slack
        print_instances
        print_retired_ris unless @audit_results.retired_ris.empty?
        print_retired_tags unless @audit_results.retired_tags.empty?
      end

      def self.print_instances
        slack_instances = NotifySlack.new(nil, @options[:config_json])
        data_array = @audit_results.data.reject { |data| data.matched? }

        data_array.each do |data|
          type = !@zone_output && (data.tagged? || data.running?) ? print_without_zone(data.type) : data.type
          count = data.count
          color, rgb, prefix = color_chooser(data)

          if data.tagged?
            if data.reason
              text = "#{prefix} #{data.name}: (expiring on #{data.tag_value} because #{data.reason})"
            else
              text = "#{prefix} #{data.name}: (expiring on #{data.tag_value})"
            end
          elsif data.ignored?
            text = "#{prefix} #{data.name}"
          else
            text = "#{prefix} #{type}: #{count}"
          end

          slack_instances.attachments.push({"color" => rgb, "text" => text, "mrkdwn_in" => ["text"]})
        end

        slack_instances.perform
      end

      def self.print_retired_ris
        retired_ris = @audit_results.retired_ris
        message = "The following reserved #{@class}s have recently expired in #{@display_name}:\n"

        retired_ris.each do |ri|
          if ri.availability_zone.nil?
            # if ri.to_s = 'Linux VPC  t2.small'...
            my_match = ri.to_s.match(/(\w*\s*\w*\s{1})\s*(\s*\S*)/)

            # then platform = 'Linux VPC '...
            platform = my_match[1] if my_match

            # and size = 't2.small'
            size = my_match[2] if my_match

            name = "#{platform}#{@audit_results.region} #{size}"
          else
            name = ri.to_s
          end
          
          count = ri.count
          expiration_date = ri.expiration_date
          message << "*#{name}* (#{count}) on *#{expiration_date}*\n"
        end
          
        slack_retired_ris = NotifySlack.new(message, @options[:config_json])
        slack_retired_ris.perform
      end

      def self.print_retired_tags
        retired_tags = @audit_results.retired_tags
        message = "The following #{@class} tags have recently expired in #{@display_name}:\n"

        retired_tags.each do |tag|
          if tag.reason
            message << "*#{tag.instance_name}* (#{tag.instance_type}) retired on *#{tag.value}* because #{tag.reason}\n"
          else
            message << "*#{tag.instance_name}* (#{tag.instance_type}) retired on *#{tag.value}*\n"
          end
        end

        slack_retired_tags = NotifySlack.new(message, @options[:config_json])
        slack_retired_tags.perform
      end

      #################### OTHER HELPFUL METHODS ####################

      def self.gather_regions
        ec2 = Aws::EC2::Client.new(region: 'us-east-1')
        regions = ec2.describe_regions[:regions]
        us_regions = regions.select { |region| region.region_name.include?("us") }
        us_regions.collect { |r| r.region_name }
      end

      def self.collect_options(options, global_options)
        @options = options
        @display_name = global_options[:display] || environment
        @slack = options[:slack]
        @no_selection = !(options[:ec2] || options[:rds] || options[:cache])
        @zone_output = options[:zone_output]
        @regions = (global_options[:region].split(', ') if global_options[:region]) || gather_regions

        if options[:no_tag]
          @tag_name = nil
        else
          @tag_name = options[:tag]
        end

        @ignore_instances_regexes = []
        if options[:ignore_instances_patterns]
          options[:ignore_instances_patterns].split(', ').each do |r|
            @ignore_instances_regexes << Regexp.new(r)
          end
        end

        @instance_types = [["EC2Instance", options[:ec2]],
                           ["RDSInstance", options[:rds]],
                           ["CacheInstance", options[:cache]]]
      end

      def self.print_title
        if @slack
          puts "Condensed results from this audit will print into Slack instead of directly to an output."
          NotifySlack.new("_AWS AUDIT FOR #{@display_name}_", @options[:config_json]).perform
        else
          puts "AWS AUDIT FOR #{@display_name}".colorize(:yellow).on_red.underline
        end
      end

      def self.print_region(region)
        if @slack
          NotifySlack.new("_REGION: *_#{region}_*_", @options[:config_json]).perform
        else
          puts "REGION: #{region}".colorize(:white).on_blue.underline
        end
      end

      def self.print_instance_type(type)
        if @slack
          NotifySlack.new("*#{type.first}s*", @options[:config_json]).perform
        else
          puts "#{type.first}s".underline
        end
      end

      def self.print_without_zone(type)
        type.sub(/(-\d\w)/, '')
      end

      def self.color_chooser(instance)
        if instance.tagged?
          return "blue", "#0000CC", "TAGGED -"
        elsif instance.ignored?
          return "blue", "#0000CC", "IGNORED -"
        elsif instance.running?
          return "yellow", "#FFD700", "MISSING RI -"
        elsif instance.matched?
          return "green", "#32CD32", "MATCHED RI -"
        elsif instance.reserved?
          return "red", "#BF1616", "UNUSED RI -"
        end
      end
    end
  end
end
