# encoding: utf-8
require 'active_support'
require 'active_support/core_ext/hash/indifferent_access'
require 'fileutils'
require 'hipchat'
require 'monitor'
require 'politics'
require 'politics/static_queue_worker'
require 'set'
require 'socket'
require 'timeout'

require 'models/project'
require 'models/build'
require 'models/bucket'
require 'models/log'

require_relative 'ec2'
require_relative 'command_line'
require_relative 'rake'
require_relative 'mailer'
require_relative 'bucket_store'

module DCC

class Worker
  include Politics::StaticQueueWorker
  include MonitorMixin
  include CommandLine

  attr_reader :admin_e_mail_address

  def initialize(group_name, memcached_servers, options = {})
    super()
    @hipchat_config = options[:hipchat] || {}
    @gui_base_url = options[:gui_base_url]
    options = {
      log_level: ::Logger::WARN,
      servers: memcached_servers,
    }.with_indifferent_access.merge(options)
    options[:log_level] = eval(options[:log_level]) if String === options[:log_level]
    log.level = options[:log_level]
    log.formatter = ::Logger::Formatter.new()
    Logger.setLog(log)
    register_worker group_name, 0, options
    EC2.add_tag(uri_tag_name, uri)
    @buckets = BucketStore.new
    @admin_e_mail_address = options[:admin_e_mail_address]
    @succeeded_before_all_tasks = []
    @prepared_bucket_groups = Set.new
    @bundled_ruby_versions = Set.new
    @currently_processed_bucket_id = nil
    if options[:tyrant]
      log.debug { "become tyrant" }
      instance_eval do
        alias :original_seize_leadership :seize_leadership
        def seize_leadership(ignore = nil)
          original_seize_leadership(1000000)
          @leader_uri = nil
          @nominated_at = Time.now
        end

        alias :original_nominate :nominate
        def nominate
          seize_leadership
        end

        def leader?
          uri == leader_uri
        end
      end
      seize_leadership
      fork do
        while true
          seize_leadership
          sleep 60
        end
      end
    end
  end

  def hostname
    Socket.ip_address_list.detect {|a| a.ipv4_private? }.ip_address
  end

  def bucket_request_context
    {
      hostname: Socket.gethostname
    }
  end

  def run
    log.debug "running"
    log_general_error_on_failure("running worker failed") do
      with_reset_rbenv do
        with_reset_rails_env do
          without_bundler do
            process_bucket do |bucket_id|
              @currently_processed_bucket_id = bucket_id
              bucket = retry_on_mysql_failure {Bucket.find(bucket_id)}
              log_bucket_error_on_failure(bucket, "processing bucket failed") do
                Timeout::timeout(7200) do
                  with_environment(RBENV_VERSION: bucket.build.project.ruby_version(bucket.name)) do
                    perform_task bucket
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  def prepare_task(bucket)
    build = bucket.build
    project = build.project
    git = project.git

    if @last_handled_build != build.id
      @prepared_bucket_groups.clear
      @bundled_ruby_versions.clear

      if (code = project.before_all_code)
        Dir.chdir(git.path) {code.call}
      end
    end

    ruby_version = project.ruby_version bucket.name
    unless @bundled_ruby_versions.include?(ruby_version)
      execute(%w(bundle install), :dir => git.path) if File.exists?(File.join(git.path, "Gemfile"))
      @bundled_ruby_versions.add ruby_version
    end

    bucket_group = project.bucket_group(bucket.name)
    unless @prepared_bucket_groups.include?(bucket_group)
      if (code = project.before_each_bucket_group_code)
        Dir.chdir(git.path) {code.call}
      end
      @prepared_bucket_groups.add(bucket_group)
    end
  end

  def perform_task(bucket)
    log.info "performing task #{bucket}"
    logs = bucket.logs
    build = bucket.build
    project = build.project
    git = project.git
    git.update :commit => build.commit, :make_pristine => git.current_commit != build.commit

    prepare_task(bucket)

    succeeded = true
    @succeeded_before_all_tasks = [] if @last_handled_build != build.id
    before_all_tasks = project.before_all_tasks(bucket.name) - @succeeded_before_all_tasks
    if !before_all_tasks.empty?
      succeeded = perform_rake_tasks(git.path, before_all_tasks, logs)
      @succeeded_before_all_tasks += succeeded ? before_all_tasks : []
      @last_handled_build = build.id
    end
    if succeeded
      succeeded &&= perform_rake_tasks(git.path, project.before_bucket_tasks(bucket.name), logs)
      succeeded &&= perform_rake_tasks(git.path, project.bucket_tasks(bucket.name), logs)
      succeeded = perform_rake_tasks(git.path, project.after_bucket_tasks(bucket.name), logs) &&
          succeeded
    end
    whole_log = ''
    logs.each do |log|
      whole_log << log.log
    end
    bucket.log = whole_log
    bucket.error_log = nil
    bucket.status = succeeded ? 10 : 40
    bucket.finished_at = Time.now
    bucket.save
    logs.clear
    if !succeeded
      bucket.build_error_log
      Mailer.failure_message(bucket).deliver
      notify_hipchat(bucket, succeeded)
    else
      last_build = project.last_build(:before_build => build)
      if last_build && (last_bucket = last_build.buckets.find_by_name(bucket.name)) &&
            last_bucket.status != 10
        Mailer.fixed_message(bucket).deliver
        notify_hipchat(bucket, succeeded)
      end
    end
  end

  def hipchat_room
    token = @hipchat_config[:token]
    room_id = @hipchat_config[:room]

    HipChat::Client.new(token, api_version: 'v1')[room_id]
  end

  def hipchat_user(project)
    if hipchat_user = (@hipchat_config[:user_mapping] || {})[project.github_user]
      " /cc @#{hipchat_user}"
    end
  end

  def notify_hipchat(bucket, succeeded)
    user = 'DCC'

    if succeeded
      color = 'green'
      event = 'repaired'
    else
      color = 'red'
      event = 'failed'
    end

    bucket_gui_url = "#{@gui_base_url}/project/show_bucket/#{bucket.id}"
    project = bucket.build.project
    message = "[#{project.name}] #{bucket.name} #{event} - " +
        "#{bucket_gui_url}#{hipchat_user(project)}"

    hipchat_room.send(user, message, {
      notify: true,
      message_format: 'text',
      color: color
    })
  end

  def perform_rake_task(path, task, logs)
    process_state = _perform_rake_task(path, task, logs)
    log.debug "process terminated? #{process_state.exited?} with status #{process_state.inspect}"
    if (process_state.signaled? && process_state.termsig == 6)
      log.debug "rake aborted - retry it once"
      logs.create(:log => "\n\n#{"-" * 80}\n\nrake aborted - retry it once\n\n#{"-" * 80}\n\n")
      process_state = _perform_rake_task(path, task, logs)
      log.debug "process terminated? #{process_state.exited?} with status #{process_state.inspect}"
    end
    process_state.exitstatus == 0
  end

  def _perform_rake_task(path, task, logs)
    log.debug "performing rake task #{task}"
    log_file = File.expand_path("../../../log/rake_#{SecureRandom.hex(8)}.log", __FILE__)
    rake = Rake.new(path, log_file)
    old_connection_pool = close_db_connections
    pid = fork do
      ActiveRecord::Base.establish_connection(old_connection_pool.spec.config)
      begin
        rake.rake(task)
      rescue
        exit 1
      end
      exit 0
    end
    ActiveRecord::Base.establish_connection(old_connection_pool.spec.config)
    log_length = 0
    while !Process.waitpid(pid, Process::WNOHANG)
      log_length += read_log_into_db(log_file, log_length, logs)
      sleep log_polling_intervall
    end
    read_log_into_db(log_file, log_length, logs)
    FileUtils.rm_rf log_file
    $?
  end

  def read_log_into_db(log_file, log_length, logs)
    log.debug "read #{log_file} from position #{log_length} into DB"
    log_content = ""
    begin
      log_content = File.open(log_file, 'r:iso-8859-1') {|f| f.seek(log_length) and f.read }.
          encode('ISO8859-1').force_encoding('UTF-8').chars.select(&:valid_encoding?).join
      log.debug "read log (length: #{log_content.bytesize}): #{log_content}"
    rescue Exception => e
      log.debug "could not read #{log_file}: #{e}"
    end
    if !log_content.empty?
      logs.create(:log => log_content)
      log_content.bytesize
    else
      0
    end
  end

  def log_polling_intervall
    return 10
  end

  def initialize_buckets
    log.debug "initializing buckets"
    update_buckets
  end

  def update_buckets
    log.debug "updating buckets"
    Project.find(:all).each do |project|
      if !project_in_build?(project)
        compute_buckets_and_finish_last_build_if_necessary(project)
      end
    end
  end

  def project_in_build?(project)
    buckets_pending = synchronize { !@buckets.empty?(project.name) }
    buckets_pending || (
      build = project.last_build
      build && !build.buckets.select do |b|
        begin
          case b.status
          when 20
            raise "bucket #{b} is pending but the leader did not know about it"
          when 30
            unless DRbObject.new(nil, b.worker_uri).processing?(b.id)
              raise "worker #{b.worker_uri} does not process #{b}"
            end
            true
          else
            false
          end
        rescue Exception => e
          log.debug "setting bucket #{b} to “processing failed”: status = #{b.status}, " +
              "reason: #{e.message}\n\n#{e.backtrace.join("\n")}"
          b.status = 35
          b.save
          false
        end
      end.empty?
    )
  end

  def processing?(bucket_id)
    log.debug "answering on processing?(#{bucket_id}): #{
        @currently_processed_bucket_id == bucket_id} for #{@currently_processed_bucket_id}"
    @currently_processed_bucket_id == bucket_id
  end

  def read_buckets(project)
    buckets = []
    as_dictator do
      log.info "reading buckets for project #{project}"
      log_project_error_on_failure(project, "reading buckets failed") do
        if project.wants_build?
          build_number = project.next_build_number
          build = project.builds.create(
            commit: project.current_commit,
            build_number: build_number,
            leader_uri: uri,
            leader_hostname: Socket.gethostname
          )
          project.buckets_tasks.each_key do |task|
            bucket = build.buckets.create(:name => task, :status => 20)
            buckets << bucket.id
          end
          project.update_state
        end
        project.last_system_error = nil
        project.save
      end
      log.debug "read buckets #{buckets.inspect}"
    end
    buckets
  end

  def next_bucket(requestor_uri, context)
    sleep(rand(21) / 10.0)
    bucket_spec = [synchronize {@buckets.next_bucket(requestor_uri)}, sleep_until_next_bucket_time]
    log.debug "got bucket spec #{bucket_spec.inspect}"
    if bucket_id = bucket_spec[0]
      log.debug "search bucket #{bucket_id}"
      bucket = synchronize { retry_on_mysql_failure { Bucket.find(bucket_id) } }
      log.debug "update bucket #{bucket_id}"
      bucket.worker_uri = requestor_uri
      bucket.worker_hostname = context[:hostname]
      bucket.status = 30
      bucket.started_at = Time.now
      bucket.save
      log.debug "deliver bucket #{bucket} to #{requestor_uri}"
      unless (build = bucket.build).started_at
        build.started_at = Time.now
        build.save
      end
    end
    bucket_spec
  end

  def log_bucket_error_on_failure(bucket, subject, &block)
    log_error_on_failure(subject, :bucket => bucket, &block)
  end

  def log_project_error_on_failure(project, subject, &block)
    log_error_on_failure(subject, :project => project, &block)
  end

  def log_general_error_on_failure(subject, &block)
    log_error_on_failure(subject, :email_address => admin_e_mail_address, &block)
  end

private

  def retry_on_mysql_failure
    yield
  rescue ActiveRecord::StatementInvalid => e
    if e.message =~ /MySQL server has gone away/
      log.debug "MySQL server has gone away … retry with new connection"
      connection_pool = close_db_connections
      ActiveRecord::Base.establish_connection(connection_pool.spec.config)
      sleep 3
      result = yield
      log.debug "retry with new connection succeeded"
      result
    else
      log.debug "ActiveRecord::StatementInvalid occurred #{e.message}"
      raise e
    end
  end

  @@pbl = 0
  def log_error_on_failure(subject, options = {})
    log.debug "entering protected block (->#{@@pbl += 1})"
    begin
      retry_on_mysql_failure do
        retry_on_mysql_failure do
          yield
        end
      end
    rescue ActiveRecord::StatementInvalid => e
      log.debug "retrying with new MySQL connection failed for three times"
      raise e
    end
    log.debug "leaving protected block (->#{@@pbl -= 1})"
  rescue Exception => e
    log.debug "error #{e.class} occurred in protected block (->#{@@pbl -= 1})"
    bucket = options[:bucket] &&
        retry_on_mysql_failure { Bucket.select([:log, :error_log]).find(options[:bucket].id) }
    msg = "uri: #{uri} (#{Socket.gethostname})\n" +
        "leader_uri: #{leader_uri}#{bucket && " (#{bucket.build.leader_hostname})"}\n\n" +
        "#{e.message}\n\n#{e.backtrace.join("\n")}"
    log.error "#{subject}\n#{msg}"
    if bucket
      bucket.status = 35
      bucket.log = "#{bucket.log}\n\n------ Processing failed ------\n\n#{subject}\n\n#{msg}"
      bucket.save
    elsif project = options[:project]
      project.last_system_error = "#{subject}\n\n#{msg}"
      project.save
    end
    if options[:email_address]
      Mailer.dcc_message(options[:email_address], subject, msg).deliver
    end
  end

  def perform_rake_tasks(path, tasks, logs)
    succeeded = true
    log.debug "performing rake tasks #{tasks}"
    tasks.each {|task| succeeded = perform_rake_task(path, task, logs) && succeeded}
    succeeded
  end

  def compute_buckets_and_finish_last_build_if_necessary(project)
    build = project.last_build
    log.info "finished?: checking build #{build || '<nil>'} (#{
        build && build.finished_at || '<nil>'})"
    if build && !build.finished_at
      log.debug "marking project #{project.name}'s build #{build.identifier} as finished"
      build.finished_at = Time.now
      build.save
    end
    buckets = read_buckets(project)
    synchronize do
      @buckets.set_buckets project.name, buckets
    end
  end

  def with_environment(additional_env, &block)
    original_env = ENV.to_hash
    additional_env = additional_env.stringify_keys
    string_only_version = additional_env.merge(additional_env) do |k, v|
      v.nil? ? nil : v.to_s
    end
    ENV.update(string_only_version)
    yield if block_given?
  ensure
    ENV.replace(original_env)
  end

  def without_bundler(&block)
    with_environment({
      "RUBYOPT" => nil,
      "RUBYLIB" => nil,
      "BUNDLE_GEMFILE" => nil,
      "BUNDLE_BIN_PATH" => nil,
      "BUNDLE_ORIG_MANPATH" => nil,
    }, &block)
  end

  def with_reset_rails_env(&block)
    with_environment({
      "RAILS_ENV" => nil,
    }, &block)
  end

  def with_reset_rbenv(&block)
    with_environment({
      "RBENV_VERSION" => nil,
      "RBENV_DIR" => nil,
      "GEM_PATH" => nil,
      "GEM_HOME" => nil,
      "PATH" => ENV['PATH'].split(':').select do |path|
        path !~ %r|^#{ENV["RBENV_ROOT"]}/versions/|
      end.join(':')
    }, &block)
  end

  def close_db_connections
    ActiveRecord::Base.connection_pool.tap do |pool|
      pool.connections.each do |connection|
        while connection.open_transactions > 0
          connection.decrement_open_transactions
        end
      end
      pool.disconnect!
    end
  end

  def uri_tag_name
    "dcc:#{group_name}:uri"
  end

  def find_workers
    EC2.neighbours.map {|i| i.tags[uri_tag_name] }
  end

  def cleanup
    EC2.add_tag(uri_tag_name, nil)
  end
end

end
