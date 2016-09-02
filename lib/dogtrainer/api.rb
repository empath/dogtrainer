require 'dogapi'
require 'dogapi/v1'
require 'dogtrainer/logging'

module DogTrainer
  # Helper methods to upsert/ensure existence and configuration of DataDog
  # Monitors, TimeBoards and ScreenBoards.
  class API
    include DogTrainer::Logging

    # Initialize class; set instance configuration.
    #
    # @param api_key [String] DataDog API Key
    # @param app_key [String] DataDog Application Key
    # @param notify_to [String] DataDog notification recpipent string for
    #   monitors. This is generally one or more @-prefixed DataDog users or
    #   notification recipients. It can be set to nil if you are only managing
    #   screenboards and timeboards. For further information, see:
    #   http://docs.datadoghq.com/monitoring/#notifications
    # @param repo_path [String] Git or HTTP URL to the repository containing
    #   code that calls this class. Will be added to notification messages so
    #   that humans know where to make changes to monitors. If nil, the return
    #   value of #get_repo_path
    def initialize(api_key, app_key, notify_to, repo_path = nil)
      logger.debug 'initializing DataDog API client'
      @dog = Dogapi::Client.new(api_key, app_key)
      @monitors = nil
      @timeboards = nil
      @screenboards = nil
      @notify_to = notify_to
      if repo_path.nil?
        @repo_path = get_repo_path
        logger.debug "using repo_path: #{@repo_path}"
      else
        @repo_path = repo_path
      end
    end

    # Return a human-usable string identifying where to make changes to the
    # resources created by this class. Returns the first of:
    #
    # 1. ``GIT_URL`` environment variable, if set and not empty
    # 2. ``CIRCLE_REPOSITORY_URL`` environment variable, if set and not empty
    # 3. If the code calling this class is part of a git repository on disk and
    #    ``git`` is present on the system and in PATH, the URL of the first
    #    remote for the repository.
    #
    # If none of these are found, an error will be raised.
    def get_repo_path
      %w(GIT_URL CIRCLE_REPOSITORY_URL).each do |vname|
        return ENV[vname] if ENV.has_key?(vname) && !ENV[vname].empty?
      end
      # try to find git repository
      # get the path to the calling code;
      #   caller[0] is #initialize, caller[1] is what instantiated the class
      path, = caller[1].partition(':')
      repo_path = get_git_url_for_directory(File.dirname(path))
      if repo_path.nil?
        raise 'Unable to determine source code path; please ' \
        'specify repo_path option to DogTrainer::API'
      end
      repo_path
    end

    # Given the path to a directory on disk that may be a git repository,
    # return the URL to its first remote, or nil otherwise.
    #
    # @param dir_path [String] Path to possible git repository
    def get_git_url_for_directory(dir_path)
      logger.debug "trying to find git remote for: #{dir_path}"
      conf = nil
      Dir.chdir(dir_path) do
        begin
          conf = `git config --local -l`
        rescue
          conf = nil
        end
      end
      return nil if conf.nil?
      conf.split("\n").each do |line|
        return Regexp.last_match(1) if line =~ /^remote\.[^\.]+\.url=(.+)/
      end
      nil
    end

    #########################################
    # BEGIN monitor-related shared methods. #
    #########################################

    # Given the name of a metric we're monitoring and the comparison method,
    # generate alert messages for the monitor.
    #
    # This method is intended for internal use by the class, but can be
    # overridden if the implementation is not desired.
    #
    # @param metric_desc [String] description/name of the metric being
    #   monitored.
    # @param comparison [String] comparison operator or description for metric
    #   vs threshold; i.e. ">=", "<=", "=", "<", etc.
    # @option mon_type [String] type of monitor as defined in DataDog
    #   API docs.
    def generate_messages(metric_desc, comparison, mon_type)
      message = [
        "{{#is_alert}}'#{metric_desc}' should be #{comparison} {{threshold}}, ",
        "but is {{value}}.{{/is_alert}}\n",
        "{{#is_recovery}}'#{metric_desc}' recovered  (current value {{value}} ",
        "is #{comparison} threshold of {{threshold}}).{{/is_recovery}}\n",
        '(monitor and threshold configuration for this alert is managed by ',
        "#{@repo_path}) #{@notify_to}"
      ].join('')
      escalation = "'#{metric_desc}' is still in error state (current value " \
        "{{value}} is #{comparison} threshold of {{threshold}})"
      [message, escalation]
    end

    # Return a hash of parameters for a monitor with the specified
    # configuration. For further information, see:
    # http://docs.datadoghq.com/api/#monitors
    #
    # @param name [String] name for the monitor; must be unique per DataDog
    #   account
    # @param message [String] alert/notification message for the monitor
    # @param query [String] query for the monitor to evaluate
    # @param threshold [Float or Hash] evaluation threshold for the monitor;
    #   if a Float is passed, it will be provided as the ``critical`` threshold;
    #   otherise, a Hash in the form taken by the DataDog API should be provided
    #   (``critical``, ``warning`` and/or ``ok`` keys, Float values)
    # @param [Hash] options
    # @option options [String] :escalation_message optional escalation message
    #   for escalation notifications. Defaults to nil.
    # @option options [Boolean] :alert_no_data whether or not to alert on lack
    #   of data. Defaults to true.
    # @option options [String] :mon_type type of monitor as defined in DataDog
    #   API docs. Defaults to 'metric alert'.
    # @option options [Integer] :renotify_interval the number of minutes after
    #   the last notification before a monitor will re-notify on the current
    #   status. It will re-notify only if not resolved. Default: 60. Set to nil
    #   to disable re-notification.
    def params_for_monitor(
      name,
      message,
      query,
      threshold,
      options = {
        escalation_message: nil,
        alert_no_data: true,
        mon_type: 'metric alert',
        renotify_interval: 60
      }
    )
      options[:alert_no_data] = true unless options.key?(:alert_no_data)
      options[:mon_type] = 'metric alert' unless options.key?(:mon_type)
      options[:renotify_interval] = 60 unless options.key?(:renotify_interval)

      # handle threshold hash
      thresh = if threshold.is_a?(Hash)
                 threshold
               else
                 { 'critical' => threshold }
               end

      monitor_data = {
        'name' => name,
        'type' => options[:mon_type],
        'query' => query,
        'message' => message,
        'tags' => [],
        'options' => {
          'notify_audit' => false,
          'locked' => false,
          'timeout_h' => 0,
          'silenced' => {},
          'thresholds' => thresh,
          'require_full_window' => false,
          'notify_no_data' => options[:alert_no_data],
          'renotify_interval' => options[:renotify_interval],
          'no_data_timeframe' => 20
        }
      }
      monitor_data['options']['escalation_message'] = \
        options[:escalation_message] unless options[:escalation_message].nil?
      monitor_data
    end

    # Create or update a monitor in DataDog with the given name and data/params.
    # This method handles either creating the monitor if one with the same name
    # doesn't already exist in the specified DataDog account, or else updating
    # an existing monitor with the same name if one exists but the parameters
    # differ.
    #
    # For further information on parameters and options, see:
    # http://docs.datadoghq.com/api/#monitors
    #
    # This method calls #generate_messages to build the notification messages
    # and #params_for_monitor to generate the parameters.
    #
    # @param mon_name [String] name for the monitor; must be unique per DataDog
    #   account
    # @param query [String] query for the monitor to evaluate
    # @param threshold [Float or Hash] evaluation threshold for the monitor;
    #   if a Float is passed, it will be provided as the ``critical`` threshold;
    #   otherise, a Hash in the form taken by the DataDog API should be provided
    #   (``critical``, ``warning`` and/or ``ok`` keys, Float values)
    # @param comparator [String] comparison operator for metric vs threshold,
    #   describing the inverse of the query. I.e. if the query is checking for
    #   "< 100", then the comparator would be ">=".
    # @param [Hash] options
    # @option options [Boolean] :alert_no_data whether or not to alert on lack
    #   of data. Defaults to true.
    # @option options [String] :mon_type type of monitor as defined in DataDog
    #   API docs. Defaults to 'metric alert'.
    # @option options [Integer] :renotify_interval the number of minutes after
    #   the last notification before a monitor will re-notify on the current
    #   status. It will re-notify only if not resolved. Default: 60. Set to nil
    #   to disable re-notification.
    # @option options [String] :message alert/notification message for the
    #   monitor; if omitted, will be generated by #generate_messages
    # @option options [String] :escalation_message optional escalation message
    #   for escalation notifications. If omitted, will be generated by
    #   #generate_messages; explicitly set to nil to not add an escalation
    #   message to the monitor.
    def upsert_monitor(
      mon_name,
      query,
      threshold,
      comparator,
      options = {
        alert_no_data: true,
        mon_type: 'metric alert',
        renotify_interval: 60,
        message: nil
      }
    )
      options[:alert_no_data] = true unless options.key?(:alert_no_data)
      options[:mon_type] = 'metric alert' unless options.key?(:mon_type)
      options[:renotify_interval] = 60 unless options.key?(:renotify_interval)

      msg, esc = generate_messages(mon_name, comparator, options[:mon_type])
      message = if options[:message].nil?
                  msg
                else
                  options[:message]
                end
      escalation = if options.key?(:escalation_message)
                     options[:escalation_message]
                   else
                     esc
                   end

      rno = options[:renotify_interval]
      mon_params = params_for_monitor(mon_name, message, query, threshold,
                                      escalation_message: escalation,
                                      alert_no_data: options[:alert_no_data],
                                      mon_type: options[:mon_type],
                                      renotify_interval: rno)
      logger.info "Upserting monitor: #{mon_name}"
      monitor = get_existing_monitor_by_name(mon_name)
      return create_monitor(mon_name, mon_params) if monitor.nil?
      logger.debug "\tfound existing monitor id=#{monitor['id']}"
      do_update = false
      mon_params.each do |k, _v|
        unless monitor.include?(k)
          logger.debug "\tneeds update based on missing key: #{k}"
          do_update = true
          break
        end
        next unless monitor[k] != mon_params[k]
        logger.debug "\tneeds update based on difference in key #{k}; " \
          "current='#{monitor[k]}' desired='#{mon_params[k]}'"
        do_update = true
        break
      end
      unless do_update
        logger.debug "\tmonitor is correct in DataDog."
        return monitor['id']
      end
      res = @dog.update_monitor(monitor['id'], mon_params['query'], mon_params)
      if res[0] == '200'
        logger.info "\tMonitor #{monitor['id']} updated successfully"
        return monitor['id']
      else
        logger.error "\tError updating monitor #{monitor['id']}: #{res}"
      end
    end

    # Create a monitor that doesn't already exist; return its id
    #
    # @param mon_name [String] mane of the monitor to create
    # @param mon_params [Hash] params to pass to the DataDog API call. Must
    #   include "type" and "query" keys.
    def create_monitor(_mon_name, mon_params)
      res = @dog.monitor(mon_params['type'], mon_params['query'], mon_params)
      if res[0] == '200'
        logger.info "\tMonitor #{res[1]['id']} created successfully"
        return res[1]['id']
      else
        logger.error "\tError creating monitor: #{res}"
      end
    end

    # Get all monitors from DataDog; return the one named ``mon_name`` or nil
    #
    # This caches all monitors from DataDog in an instance variable.
    #
    # @param mon_name [String] name of the monitor to return
    def get_existing_monitor_by_name(mon_name)
      if @monitors.nil?
        @monitors = @dog.get_all_monitors(group_states: 'all')
        logger.info "Found #{@monitors[1].length} existing monitors in DataDog"
        if @monitors[1].empty?
          logger.error 'ERROR: Docker API call returned no existing monitors.' \
            ' Something is wrong.'
          exit 1
        end
      end
      @monitors[1].each do |mon|
        return mon if mon['name'] == mon_name
      end
      nil
    end

    ###########################################
    # BEGIN dashboard-related shared methods. #
    ###########################################

    # Create a graph definition (graphdef) to use with Boards APIs. For further
    # information, see: http://docs.datadoghq.com/graphingjson/
    #
    # @param title [String] title of the graph
    # @param queries [Array or String] a single string graph query, or an
    #   Array of graph query strings.
    # @param markers [Hash] a hash of markers to set on the graph, in
    #   name => value format.
    def graphdef(title, queries, markers = {})
      queries = [queries] unless queries.is_a?(Array)
      d = {
        'definition' => {
          'viz' => 'timeseries',
          'requests' => []
        },
        'title' => title
      }
      queries.each do |q|
        d['definition']['requests'] << {
          'q' => q,
          'conditional_formats' => [],
          'type' => 'line'
        }
      end
      unless markers.empty?
        d['definition']['markers'] = []
        markers.each do |name, val|
          d['definition']['markers'] << {
            'type' => 'error dashed',
            'val' => val.to_s,
            'value' => "y = #{val}",
            'label' => "#{name}==#{val}"
          }
        end
      end
      d
    end

    # Create or update a timeboard in DataDog with the given name and
    # data/params. For further information, see:
    # http://docs.datadoghq.com/api/#timeboards
    #
    # @param dash_name [String] Account-unique dashboard name
    # @param graphs [Array] Array of graphdefs to add to dashboard
    def upsert_timeboard(dash_name, graphs)
      logger.info "Upserting timeboard: #{dash_name}"
      desc = "created by DogTrainer RubyGem via #{@repo_path}"
      dash = get_existing_timeboard_by_name(dash_name)
      if dash.nil?
        d = @dog.create_dashboard(dash_name, desc, graphs)
        logger.info "Created timeboard #{d[1]['dash']['id']}"
        return
      end
      logger.debug "\tfound existing timeboard id=#{dash['dash']['id']}"
      needs_update = false
      if dash['dash']['description'] != desc
        logger.debug "\tneeds update of description"
        needs_update = true
      end
      if dash['dash']['title'] != dash_name
        logger.debug "\tneeds update of title"
        needs_update = true
      end
      if dash['dash']['graphs'] != graphs
        logger.debug "\tneeds update of graphs"
        needs_update = true
      end

      if needs_update
        logger.info "\tUpdating timeboard #{dash['dash']['id']}"
        @dog.update_dashboard(
          dash['dash']['id'], dash_name, desc, graphs
        )
        logger.info "\tTimeboard updated."
      else
        logger.info "\tTimeboard is up-to-date"
      end
    end

    # Create or update a screenboard in DataDog with the given name and
    # data/params. For further information, see:
    # http://docs.datadoghq.com/api/screenboards/ and
    # http://docs.datadoghq.com/api/?lang=ruby#screenboards
    #
    # @param dash_name [String] Account-unique dashboard name
    # @param widgets [Array] Array of Hash widget definitions to pass to
    #   the DataDog API. For further information, see:
    #   http://docs.datadoghq.com/api/screenboards/
    def upsert_screenboard(dash_name, widgets)
      logger.info "Upserting screenboard: #{dash_name}"
      desc = "created by DogTrainer RubyGem via #{@repo_path}"
      dash = get_existing_screenboard_by_name(dash_name)
      if dash.nil?
        d = @dog.create_screenboard(board_title: dash_name,
                                    description: desc,
                                    widgets: widgets)
        logger.info "Created screenboard #{d[1]['id']}"
        return
      end
      logger.debug "\tfound existing screenboard id=#{dash['id']}"
      needs_update = false
      if dash['description'] != desc
        logger.debug "\tneeds update of description"
        needs_update = true
      end
      if dash['board_title'] != dash_name
        logger.debug "\tneeds update of title"
        needs_update = true
      end
      if dash['widgets'] != widgets
        logger.debug "\tneeds update of widgets"
        needs_update = true
      end

      if needs_update
        logger.info "\tUpdating screenboard #{dash['id']}"
        @dog.update_screenboard(dash['id'], board_title: dash_name,
                                            description: desc,
                                            widgets: widgets)
        logger.info "\tScreenboard updated."
      else
        logger.info "\tScreenboard is up-to-date"
      end
    end

    # get all timeboards from DataDog; return the one named ``dash_name`` or nil
    # returns the timeboard definition hash from the DataDog API
    def get_existing_timeboard_by_name(dash_name)
      if @timeboards.nil?
        @timeboards = @dog.get_dashboards
        puts "Found #{@timeboards[1]['dashes'].length} existing timeboards " \
          'in DataDog'
        if @timeboards[1]['dashes'].empty?
          puts 'ERROR: Docker API call returned no existing timeboards. ' \
            'Something is wrong.'
          exit 1
        end
      end
      @timeboards[1]['dashes'].each do |dash|
        return @dog.get_dashboard(dash['id'])[1] if dash['title'] == dash_name
      end
      nil
    end

    # get all screenboards from DataDog; return the one named ``dash_name`` or
    # nil returns the screenboard definition hash from the DataDog API
    def get_existing_screenboard_by_name(dash_name)
      if @screenboards.nil?
        @screenboards = @dog.get_all_screenboards
        puts "Found #{@screenboards[1]['screenboards'].length} existing " \
          'screenboards in DataDog'
        if @screenboards[1]['screenboards'].empty?
          puts 'ERROR: Docker API call returned no existing screenboards. ' \
            'Something is wrong.'
          exit 1
        end
      end
      @screenboards[1]['screenboards'].each do |dash|
        return @dog.get_screenboard(dash['id'])[1] if dash['title'] == dash_name
      end
      nil
    end
  end
end
