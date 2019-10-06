WINDOWS = Gem.win_platform?

require 'pry'
require 'cgi'
require 'net/http'
require 'openssl'
require 'sinatra/base'
require 'socket'
require 'sys/proctable'
require 'sysrandom'
require 'toml-rb'
require 'webrick'
require 'webrick/https'
require_relative '../ext/thread'
require_relative 'logger'
require_relative 'buffer'
require_relative 'certificate-generator'
require_relative 'daemon'
require_relative 'config-handler'
require_relative 'user'
require_relative 'rcon-client'
require_relative 'self-updater'
require_relative 'server-updater'

Encoding.default_external = "UTF-8"
LOGGER.threshold :info # Changes STDOUT only
log "Loading config"
$config_handler = ConfigHandler.new

class SandstormAdminWrapperSite < Sinatra::Base
  def self.set_up
    log "Initializing webserver"
    @@config = load_webapp_config
    @@daemons = {}
    @@daemons_mutex = Mutex.new
    @@monitors = {}
    @@buffers = {}
    @@buffer_mutex = Mutex.new
    @@wrapper_user_log = create_buffer.last
    @@wrapper_connection_log = create_buffer.last
    @@rcon_client = RconClient.new
    @@server_updater = ServerUpdater.new(SERVER_ROOT, STEAMCMD_EXE, STEAM_APPINFO_VDF)
    @@update_thread = nil
    @@prereqs_complete = false
    @@lan_access_bind_ip = Socket.ip_address_list.detect{ |intf| intf.ipv4_private? }.ip_address rescue '?'
    @@loaded_wrapper_version = @@config['wrapper_version']
    handle_arguments unless ARGV.empty?
    trap 'EXIT' do
      Thread.new do
        if @@daemons.any?
          log "Stopping daemons", level: :info
          @@daemons.each { |_, daemon| daemon.do_stop_server }
        end
      end.join
    end
  end

  def self.load_webapp_config
    FileUtils.cp(WEBAPP_CONFIG_SAMPLE, WEBAPP_CONFIG) unless File.exist?(WEBAPP_CONFIG)
    log "Loading wrapper config from #{File.basename WEBAPP_CONFIG}"
    config = TomlRB.load_file WEBAPP_CONFIG
    config['automatic_updates'] = true if config['automatic_updates'].nil?
    config
  rescue => e
    log "Couldn't load config from #{config_file}", e
    raise
  end

  def self.save_webapp_config(config, config_file = WEBAPP_CONFIG)
    log "Saving wrapper config"
    File.write(config_file, TomlRB.dump(config))
  end

  def self.handle_arguments
    args = ARGV.dup
    while true
      arg = args.shift
      break if arg.nil?
      case arg
      when '--start', '-s'
        val = args.shift
        break if val.nil?
        @@daemons_mutex.synchronize do
          config = $config_handler.server_configs[val]
          if config
            log "Starting daemon for #{val}", level: :info
            Thread.new { init_daemon(config.dup, start: true) }
          else
            log "Unknown server config: #{val}", level: :warn
          end
        end
      when '--log-level', '-l'
        val = args.shift.to_s.upcase.to_sym
        if Logger::Severity.constants.include? val
          log "Setting STDOUT logger threshold to #{val}", level: :info
          LOGGER.threshold val
        else
          log "Unknown log level: #{val}. Try one of these: #{Logger::Severity.constants.map(&:to_s).join(', ')}", level: :warn
        end
      else
        log "Unknown argument: #{arg}", level: :warn
      end
    end
  end

  def self.init_daemon(config, start: false)
    key = config['server_game_port']
    @@daemons_mutex.synchronize do
      log "Initializing daemon with game port [#{key}]", level: :info
      @@daemons[key] = SandstormServerDaemon.new(
        config,
        @@daemons,
        @@daemons_mutex,
        @@rcon_client,
        create_buffer.last,
        create_buffer.last
      )
    end
    @@daemons[key].do_start_server if start
    @@daemons[key]
  end

  def self.create_buffer(uuid=nil)
    @@buffer_mutex.synchronize do
      return [uuid, @@buffers[uuid]] unless @@buffers[uuid].nil?
      uuid = Sysrandom.uuid if uuid.nil?
      buffer = Buffer.new(uuid)
      @@buffers[uuid] = buffer
      [uuid, buffer]
    end
  end

  # def which(command)
  #   exts = ENV['PATHEXT'] ? ENV['PATHEXT'].split(';') : ['']
  #   ENV['PATH'].split(File::PATH_SEPARATOR).each do |path|
  #     exts.each do |ext|
  #       exe = File.join(path, "#{command}#{ext}")
  #       return exe if File.executable?(exe) && !File.directory?(exe)
  #     end
  #   end
  #   nil
  # end

  def steamcmd_installed?
    # on_path = WINDOWS ? which("steamcmd.exe") : (which("steamcmd") || which("steamcmd.sh"))
    # return on_path unless on_path.nil?
    STEAMCMD_EXE if File.exist? STEAMCMD_EXE
  end

  def game_server_installed?
    BINARY if File.exist? BINARY
  end

  def get_server_status(game_port)
    daemon = @@daemons[game_port]
    return 'OFF' if daemon.nil?
    daemon.server_running? ? 'ON' : 'OFF'
  end

  def get_update_status
    return 'OFF' if @@update_thread.nil?
    @@update_thread.alive? ? 'ON' : 'OFF'
  end

  def check_prereqs
    steamcmd_path = steamcmd_installed?
    game_server_path = game_server_installed?
    @@prereqs_complete = steamcmd_path && game_server_path
    @@update_thread = get_game_update_thread if @@prereqs_complete && @@update_thread.nil? && @@config['automatic_updates']
    return [steamcmd_path, game_server_path]
  end

  def get_update_info
    @@server_updater.get_update_info
  end

  def install_server(buffer=nil, validate: nil)
    log "Installing server..."
    success, message = @@server_updater.update_server(buffer, validate: validate)
    message
  end

  def update_server(buffer=nil, validate: nil)
    was_running = []
    if WINDOWS
      @@daemons.each do |key, daemon|
        if daemon.server_running?
          daemon.do_pre_update_warning
          daemon.do_stop_server
          was_running << key
        end
      end
    end
    success, message = @@server_updater.update_server(buffer, validate: validate)
    @update_pending = !success
    @@daemons.each do |key, daemon|
      if WINDOWS
        next unless was_running.include?(key)
        daemon.do_start_server
      else
        next unless daemon.server_running?
        daemon.do_pre_update_warning
        daemon.do_restart_server
      end
    end
    message
  end

  def run_steamcmd(command, buffer: nil)
    @@server_updater.run_steamcmd(command, buffer: buffer)
  end

  def get_game_update_thread
    Thread.new do
      begin
        @@server_updater.monitor_update do
          update_server if @@config['automatic_updates']
        end
      rescue => e
        log "Game update thread failed", e
      end
    end
  end

  def start_updates
    if @@update_thread
      log "Restarting updates", level: :info
      @@update_thread.kill
      @@update_thread = get_game_update_thread
      "Automated updates restarted"
    else
      log "Starting updates", level: :info
      @@update_thread = get_game_update_thread
      "Automated updates started"
    end
  end

  def stop_updates
    if @@update_thread
      log "Stopping updates", level: :info
      @@update_thread.kill
      @@update_thread = nil
      "Automated updates stopped"
    else
      "Automated updates not running"
    end
  end

  def zip_logs(zip_path, glob)
    log "Zipping logs from #{glob} into #{zip_path.sub(USER_HOME, '~')}"
    files_to_zip = Dir.glob(glob).map { |f| File.expand_path f }
    Zip::File.open(zip_path, Zip::File::CREATE) do |zipfile|
      files_to_zip.each do |f|
        log "Zipping #{f.sub(USER_HOME, '~')}"
        zipfile.add(File.basename(f), f)
      end
    end
  end

  set_up

  configure do
    working_directory = File.expand_path File.join File.dirname(__FILE__), '..', 'docroot'
    log "Setting webserver root dir to: #{working_directory.sub(USER_HOME, '~')}", level: :info
    set :root, working_directory
    enable :sessions, :dump_errors #, :raise_errors, :show_exceptions #, :logging
    set :raise_errors, false
    set :show_exceptions, false
    set :session_secret, @@config['admin_interface_session_secret'] unless @@config['admin_interface_session_secret'].empty?
  end

  # Add a condition that we can use for various routes
  register do
    def auth(role)
      condition do
        begin
          unless has_role?(role)
            message = "IP: #{request.ip} | User unauthorized: #{"'#{@user.name}' [#{@user.role}] (#{session[:user_id]})" rescue '[logged out]'} requesting #{role}-privileged content: #{request.path_info}"
            @@wrapper_user_log << "#{datetime} | #{message}"
            log message, level: :warn
            status 403
            redirect "/login#{CGI.escape(request.path_info) unless request.path_info.casecmp('/').zero?}" if request.request_method == 'GET'
            error = "403 Unauthorized - You don't have permission to do this."
            redirect "/error?status=403&message=#{CGI.escape error}"
            false
          end
        rescue => e
          log "#{request.ip} | Error checking auth status for role: #{role}", e
          status 500
          redirect "/login/#{CGI.escape(request.path_info) unless request.path_info.casecmp('/').zero?}" if request.request_method == 'GET'
          error = "500 Error - Unknown role: #{role}"
          redirect "/error?status=500&message=#{CGI.escape error}"
          false
        end
      end
    end
  end

  # Add helper functions for user authentication, etc.
  helpers do
    def logged_in?
      !@user.nil?
    end

    def has_role?(role)
      raise "Invalid role: #{role}" unless User::ROLES.keys.include?(role)
      logged_in? && User::ROLES[@user.role] >= User::ROLES[role]
    end

    def is_host?
      has_role?(:host)
    end

    def is_admin?
      has_role?(:admin)
    end

    def is_user?
      has_role?(:user)
    end

    def get_active_config
      active_config = (@@daemons.values.select{ |d| d.buffer[:uuid] == session[:active_daemon_uuid]}.first.config rescue nil) ||
          $config_handler.server_configs[session[:active_server_config]] ||
          (@@daemons.values.select { |d| d.config['server-config-name'] == session[:active_server_config] }.first.config rescue nil) ||
          $config_handler.server_configs.values.last
      log "Got active server config with name #{active_config['server-config-name']} (game port #{active_config['server_game_port']})"
      active_config
    end
  end

  error do
    e = env['sinatra.error']
    log "#{request.ip} | Error occurred in route #{request.path}", e
    if is_host?
      "(#{e.class}) #{e.message} | Backtrace:<br>#{e.backtrace.join('<br>')}"
    else
      "An error occurred (#{e.class}). Please view the logs or contact the maintainer."
    end
  end

  before do
    env['rack.logger'] = LOGGER
    env['rack.errors'] = LOGGER
    @user = $config_handler.users[session[:user_id]] if session[:user_id]
    check_prereqs unless @@prereqs_complete
    request.body.rewind
    # body = request.body.read
    # request.body.rewind # Be kind
    timestamp = datetime
    message = "IP: #{request.ip} | #{"User: #{@user.name} | " if @user}Request: #{request.request_method}#{' ' << request.script_name unless request.script_name.strip.empty? } #{request.path_info}#{'?' << request.query_string unless request.query_string.strip.empty?}" # #{(' | Body: ' << body) unless body.strip.empty?}"
    log message
    @@wrapper_user_log.push "#{timestamp} | #{message}" if request.request_method != 'GET'
    @@wrapper_connection_log.push "#{timestamp} | #{message} | Agent: #{request.user_agent}"
    nil
  end

  # after do
  #  log "Responding: #{response.body}"
  # end

  %i(get post put).each do |method|
    send method, '/error' do
      status params['status']
      params['message']
    end
  end

  get '/confirm' do
    @yes = params[:yes]
    @no = params[:no]
    @title = params[:title]
    @body = params[:body]
    erb :confirm
  end

  get %r{/login(/)?(.*)} do
    @destination = '/' + params['captures'].last.sub('login', '')
    @destination = nil if @destination == '/'
    erb :login
  end

  post '/login' do
    data = Oj.load(request.body.read)
    request.body.rewind
    user = data['user']
    password = data['pass']
    destination = data['destination']
    if user && password
      known_user = $config_handler.users.values.select { |u| u.name == user }.first
      if known_user && known_user.password == password # BCrypt::Password == string comparison
        message = "IP: #{request.ip} | #{known_user.name} [#{known_user.role}] logged in (#{known_user.id})"
        log message, level: :info
        @@wrapper_user_log << "#{datetime} | #{message}"
        session[:user_id] = known_user.id
        return known_user.first_login? ? "/change-password#{destination}" : destination
      end
    end
    status 401
    "Failed to log in."
  end

  get '/logout' do
    user = $config_handler.users[session[:user_id]]
    halt 400, 'Not logged in' if user.nil?
    message = "IP: #{request.ip} | #{user.name} [#{user.role}] logged out (#{user.id})"
    log message, level: :info
    @@wrapper_user_log << "#{datetime} | #{message}"
    session[:user_id] = nil
    redirect '/login'
  end

  get '/status', auth: :user do
    @daemons = @@daemons
    @monitors = @@monitors
    erb :'server-status', layout: :'layout-main' do
      erb :'server-list'
    end
  end

  get '/server-list', auth: :user do
    @daemons = @@daemons
    @monitors = @@monitors
    erb :'server-list'
  end

  get '/server-daemons', auth: :admin do
    @daemons = @@daemons
    erb :'server-daemons', layout: :'layout-main'
  end

  get '/change-password(/:destination)?', auth: :user do
    @destination = "/#{params['destination']}".sub('/change-password', '')
    @first_login = !@user.initial_password.nil?
    erb :'change-password', layout: :'layout-main'
  end

  post '/change-password', auth: :user do
    data = Oj.load(request.body.read)
    request.body.rewind
    password = data['pass']
    destination = "#{data['destination']}"
    if password.strip.empty? || @user.password_matches?(password)
      status 400
      return "Invalid password. The password must be new and not blank!"
    end
    @user.password = password
    $config_handler.write_user_config
    destination
  end

  get '/wrapper-log', auth: :host do
    @user_log_id = @@wrapper_user_log[:uuid]
    @conn_log_id = @@wrapper_connection_log[:uuid]
    erb :'wrapper-log', layout: :'layout-main'
  end

  get '/wrapper-config', auth: :host do
    @config = @@config
    @lan_access_bind_ip = @@lan_access_bind_ip
    @wrapper_version = @@loaded_wrapper_version
    erb :'wrapper-config', layout: :'layout-main'
  end

  put '/wrapper-config/:action', auth: :host do
    wrapper_config = @@config
    variable = params['variable']
    value = params['value']
    value = value == 'true' if ['true', 'false'].include?(value)
    if params['action'] == 'set'
      begin
        if wrapper_config.keys.include?(variable)
          old = variable == 'admin_interface_session_secret' ? '[REDACTED]' : wrapper_config[variable]
          wrapper_config[variable] = value
          value = variable == 'admin_interface_session_secret' ? '[REDACTED]' : wrapper_config[variable]
          log "Saving new wrapper config: #{wrapper_config}", level: :info
          self.class.save_webapp_config(wrapper_config)
          "Changed #{variable}: #{old} => #{value}"
        else
          status 400
          msg
        end
      rescue => e
        msg = "Failed to set #{variable + ' -> ' + variable == 'admin_interface_session_secret' ? '[REDACTED]' : value}"
        log msg, e
        status 400
        "#{msg} | #{e.class}: #{e.message}"
      end
    elsif params['action'] == 'get'
      value = wrapper_config[variable]
      if value.nil?
        status 404
        "Could not find value for #{variable}"
      else
        value.to_s
      end
    else
      status 400
      'Unknown action'
    end
  end

  get '/wrapper-users-list', auth: :host do
    @users = $config_handler.users
    erb :'wrapper-users-list'
  end

  get '/wrapper-users', auth: :host do
    @users = $config_handler.users
    erb :'wrapper-users', layout: :'layout-main' do
      erb :'wrapper-users-list'
    end
  end

  post '/wrapper-users/:action', auth: :host do
    action = params['action']
    data = Oj.load(request.body.read)
    request.body.rewind
    id = data['id']
    name = data['name']
    role = data['role'].to_s.downcase.to_sym

    case action
    when 'create'
      if name.to_s.empty? || role.to_s.empty?
        status 400
        'Missing name/role'
      elsif $config_handler.users.values.select { |u| u.name == name }.size > 0
        status 400
        'A user with that name already exists'
      else
        user = User.new(name, role)
        $config_handler.users[user.id] = user
        $config_handler.write_user_config
        'User created'
      end
    when 'delete'
      if id.to_s.empty?
        status 400
        'Missing ID'
      elsif $config_handler.users[id].nil?
        status 400
        'No such user'
      elsif $config_handler.users[id].role == :host && $config_handler.users.values.select { |u| u.role == :host }.size == 1
        status 400
        'Cannot delete last Host'
      else
        $config_handler.users.delete id
        $config_handler.write_user_config
        'User deleted'
      end
    when 'save'
      if name.to_s.empty? || role.to_s.empty?
        status 400
        'Missing name/role'
      elsif $config_handler.users[id].nil?
        status 400
        'No such user'
      elsif !User::ROLES.keys.include?(role)
        status 400
        'No such role'
      elsif role != :host && $config_handler.users[id].role == :host && $config_handler.users.values.select { |u| u.role == :host }.size == 1
        status 400
        'Cannot change role of last Host'
      else
        user = $config_handler.users[id]
        if user.name == name && user.role == role
          status 400
          'Nothing was changed'
        else
          user.name = name
          user.role = role
          $config_handler.write_user_config
          'User saved'
        end
      end
    else
      status 400
      'Unknown action'
    end
  end

  get '/pry', auth: :host do
    @buffers = @@buffers
    prev_threshold = LOGGER.threshold
    Thread.new do
      LOGGER.threshold :fatal # Turn down STDOUT logging
      `stty echo` unless WINDOWS || !$stdout.isatty # Ensure we have echoing enabled; something from logging turns it off...

      # Stuff

      binding.pry
    ensure
      `stty echo` unless WINDOWS || !$stdout.isatty
      LOGGER.threshold prev_threshold
    end.join
    nil
  rescue Interrupt
  end

  get '/threads/:game_port', auth: :user do
    daemon = @@daemons[params[:game_port]]
    @pid = daemon.game_pid if daemon
    process = Sys::ProcTable.ps(pid: @pid) if @pid
    threads = (WINDOWS ? process.thread_count : process.nlwp) if process
    @threads = threads || 0
    monitor = daemon.monitor rescue nil
    @info = monitor.info rescue nil
    erb :threads
  end

  get '/players/:game_port', auth: :user do
    daemon = @@daemons[params[:game_port]]
    @monitor = daemon.monitor rescue nil
    @info = @monitor.info rescue nil
    erb :'players'
  end

  get '/update-info', auth: :user do
    @update_available, @old_build, @new_build = get_update_info
    erb(:'update-info')
  end

  post '/restart-wrapper', auth: :host do
    @@daemons.each { |_, daemon| daemon.do_stop_server }
    ENV['HOME'] = USER_HOME
    # The below exec doesn't work on Windows (port conflict?), so we'll exit with a particular code instead, to be handled by the start script
    if WINDOWS
      at_exit do
        exit 2
      end
      Thread.new { sleep 0.2; log "Replacing the current process..."; exit }
    else
      # If we changed gems in an update, try to install them
      output = `bundle`
      puts output
      Thread.new { sleep 0.2; log "Replacing the current process..."; exec 'bundle', 'exec', 'ruby', $PROGRAM_NAME, *ARGV }
    end
    ''
  end

  post '/update-wrapper', auth: :host do
    version = SelfUpdater.update_to_latest
    @@config['wrapper_version'] = version
    self.class.save_webapp_config @@config
    "Updated to #{version}! Restart the wrapper to apply."
  rescue => e
    status 500
    e.message
  end

  get '/', auth: :user do
    @steamcmd_path, @game_server_path = check_prereqs
    if is_admin?
      redirect '/setup' unless @steamcmd_path && @game_server_path
      redirect '/control'
    else
      redirect '/status'
    end
  end

  get '/about', auth: :user do
    erb(:about, layout: :'layout-main')
  end

  get '/setup', auth: :admin do
    @steamcmd_path, @game_server_path = check_prereqs
    @automatic_updates = @@config['automatic_updates']
    erb(:'server-setup', layout: :'layout-main')
  end

  get '/config', auth: :admin do
    redirect '/setup' unless @@prereqs_complete
    config = get_active_config
    config_name = config['server-config-name']
    @config = $config_handler.server_configs[config_name] || $config_handler.server_configs.first
    if config_name.to_s.empty?
      status 400
      return "Unknown config"
    end
    $config_handler.init_server_config_files config_name
    @game_ini = ERB.new(CONFIG_FILES[:game_ini][:local_erb]).result(binding)
    @engine_ini = ERB.new(CONFIG_FILES[:engine_ini][:local_erb]).result(binding)
    @admins_txt = ERB.new(CONFIG_FILES[:admins_txt][:local_erb]).result(binding)
    @mapcycle_txt = ERB.new(CONFIG_FILES[:mapcycle_txt][:local_erb]).result(binding)
    @bans_json = ERB.new(CONFIG_FILES[:bans_json][:local_erb]).result(binding)
    erb(:'server-config', layout: :'layout-main')
  end

  get '/control', auth: :admin do
    redirect '/setup' unless @@prereqs_complete
    @config = get_active_config
    daemon = @@daemons[@config['server_game_port']] || @@daemons.values.select { |d| d.config['server-config-name'] == session[:active_server_config] }.first
    if daemon
      log "/control working with daemon name #{daemon.config['server-config-name']} (active game port #{daemon.active_game_port})"
    else
      log "/control Failed to get running daemon for config with name #{@config['server-config-name']} (game port #{@config['server_game_port']})"
    end
    @game_port = daemon.server_running? ? daemon.active_game_port : @config['server_game_port'] rescue @config['server_game_port']
    @rcon_port = daemon.server_running? ? daemon.active_rcon_port : @config['server_rcon_port'] rescue @config['server_rcon_port']
    @query_port = daemon.server_running? ? daemon.active_query_port : @config['server_query_port'] rescue @config['server_query_port']
    @server_status = get_server_status(@game_port)
    @pid = daemon.game_pid if daemon
    process = Sys::ProcTable.ps(pid: @pid) if @pid
    threads = (WINDOWS ? process.thread_count : process.nlwp) if process
    @threads = threads || 0
    @monitor = daemon.monitor rescue nil
    @info = @monitor.info rescue nil
    erb(:'server-control', layout: :'layout-main')
  end

  get '/tools/:resource', auth: :admin do
    @config = get_active_config
    resource = params['resource']
    case resource
    when 'rcon'
      erb(:'rcon-tool', layout: :'layout-main')
    when 'steamcmd'
      redirect '/setup' unless steamcmd_installed?
      @server_root_dir = SERVER_ROOT
      erb(:'steamcmd-tool', layout: :'layout-main')
    when 'monitor'
      erb(:'monitor-tool', layout: :'layout-main')
    else
      status 500
      "Unknown resource: #{resource}"
    end
  end

  post '/tools/:resource', auth: :admin do
    resource = params['resource']
    body = request.body.read
    options = Oj.load body, symbol_keys: true
    request.body.rewind
    case resource
    when 'steamcmd'
      uuid, buffer = self.class.create_buffer
      Thread.new { run_steamcmd(options[:command].split("\n"), buffer: buffer) }
      uuid
    else
      status 400
      "Unknown resource: #{resource}"
    end
  end

  get '/server-control-status' do
    @config = get_active_config
    daemon = @@daemons[@config['server_game_port']] || @@daemons.values.select { |d| d.config['server-config-name'] == session[:active_server_config] }.first
    if daemon
      log "/server-control-status working with daemon name #{daemon.config['server-config-name']} (active game port #{daemon.active_game_port})"
    else
      log "/server-control-status Failed to get running daemon for config with name #{@config['server-config-name']} (game port #{@config['server_game_port']})"
    end
    @game_port = daemon.server_running? ? daemon.active_game_port : @config['server_game_port'] rescue @config['server_game_port']
    @rcon_port = daemon.server_running? ? daemon.active_rcon_port : @config['server_rcon_port'] rescue @config['server_rcon_port']
    @query_port = daemon.server_running? ? daemon.active_query_port : @config['server_query_port'] rescue @config['server_query_port']
    @server_status = get_server_status(@game_port)
    @pid = daemon.game_pid if daemon
    process = Sys::ProcTable.ps(pid: @pid) if @pid
    threads = (WINDOWS ? process.thread_count : process.nlwp) if process
    @threads = threads || 0
    @monitor = daemon.monitor rescue nil
    @info = @monitor.info rescue nil
    erb :'server-control-status'
  end

  get '/server-status/:game_port', auth: :user do
    game_port = params[:game_port]
    get_server_status(game_port)
  end

  get '/buffer/:uuid(/:bookmark)?', auth: :admin do # Sensitive information could be contained in these buffers (passwords, paths); admins only.
    uuid = params['uuid']
    unless @@buffers.keys.include? uuid
      status 400
      return "Unknown UUID: #{uuid}"
    end
    buffer = @@buffers[uuid]
    @bookmark_uuid = params['bookmark']
    limit = buffer[:limit]

    buffer[:mutex].synchronize do # Synchronize with the writing thread to avoid mismatched indices when truncating, etc.
      buffer[:iterator] = buffer[:iterator].nil? ? 1 : buffer[:iterator] + 1
      # log "Buffer [#{uuid}][#{buffer[:iterator]}] arrived with bookmark: [#{@bookmark_uuid}] -> #{buffer[:bookmarks][@bookmark_uuid]}"
      # log "Buffer [#{uuid}][#{buffer[:iterator]}] Bookmarks: #{buffer[:bookmarks]}"
      if buffer[:bookmarks].length > 100
        log "Buffer has many bookmarks! Are that many clients connected? #{buffer[:uuid]} (#{buffer[:bookmarks].length} bookmarks)", level: :warn
        log "Purging first 20 bookmarks", level: :warn
        20.times { buffer[:bookmarks].shift }
      end
      unless buffer[:bookmarks].keys.include?(@bookmark_uuid) || @bookmark_uuid.nil?
        status 400
        return "Failed to tail log (Unknown Bookmark UUID: #{@bookmark_uuid})."
      end
      if buffer[:bookmarks][@bookmark_uuid] == -1 # Client read everything; ready for outcome
        obj = {
          :status => buffer[:status].dup,
          :message => buffer[:message].dup
        }

        @@buffer_mutex.synchronize do
          @@buffers[uuid][:persistent] ? @@buffers[uuid].reset : @@buffers.delete(uuid)
        end
        return Oj.dump(obj, mode: :compat)
      end

      start_index = buffer[:bookmarks][@bookmark_uuid] || 0
      start_index = 0 if start_index > buffer.size
      # log "Buffer [#{uuid}][#{buffer[:iterator]}] start_index unexpectedly negative" if start_index < 0
      new_bookmark_uuid = Sysrandom.uuid
      new_bookmark = (buffer.size - start_index > limit) ? (start_index + limit) : buffer.size
      # log "Buffer - Calculated new_bookmark: #{new_bookmark}"
      if new_bookmark == buffer.size && !buffer[:status].nil?
        # Process is done. The next bookmark will be an indicator to send status and message next time
        # as well as slice to the end of the array below
        new_bookmark = -1
      end
      if new_bookmark == start_index
        new_bookmark_uuid = @bookmark_uuid
      else
        buffer[:bookmarks][new_bookmark_uuid] = new_bookmark
        buffer[:bookmarks].delete @bookmark_uuid
      end
      # log "Buffer - Command done. Moved to : #{new_bookmark}" if new_bookmark == -1

      data_response = start_index == new_bookmark ? [] : buffer[:data][start_index..new_bookmark]
      response_object = {
        :bookmark => new_bookmark_uuid,
        :data => data_response
      }
      # log "Buffer [#{uuid}][#{buffer[:iterator]}] Responding #{start_index}..#{new_bookmark}: #{data_response}"
      # log "Buffer [#{uuid}][#{buffer[:iterator]}] Bookmarks: #{buffer[:bookmarks]}"
      Oj.dump(response_object, mode: :compat)
    end
  end

  post '/control/:thread/:action', auth: :admin do
    thread = params['thread']
    action = params['action']
    body = request.body.read
    request.body.rewind
    options = Oj.load body, symbol_keys: true
    daemon = @@daemons[options[:game_port]] rescue nil
    if daemon.nil? && !['install', 'update', 'start'].include?(action)
      status 400
      return "Could not find daemon for game port #{options[:game_port]}"
    end
    validate = params['validate'] == "true"
    case thread
    when 'server'
      case action
      when 'install'
        uuid, buffer = self.class.create_buffer
        log "Installing server"
        Thread.new do
          install_server(buffer, validate: validate)
        end
        log "Server install thread started. Returning UUID: #{uuid}"
        uuid
      when 'update'
        uuid, buffer = self.class.create_buffer
        log "Updating server"
        Thread.new do
          update_server(buffer, validate: validate)
        end
        log "Server update thread started. Returning UUID: #{uuid}"
        uuid
      when 'start'
        config = $config_handler.server_configs[options[:config_name]]
        if config.nil?
          status 400
          return "Unknown config: #{options[:config_name]}"
        end
        daemon = if @@daemons[config['server_game_port']].nil? && (@@daemons.values.select { |d| d.name == config['server-config-name'] }.empty? rescue true)
          @@daemons[config['server_game_port']] = self.class.init_daemon config
        else
          @@daemons[config['server_game_port']] || @@daemons.values.select { |d| d.name == config['server-config-name']}.first
        end
        daemon.config.merge!(config)
        session[:active_daemon_uuid] = daemon.buffer[:uuid]
        daemon.do_start_server
      when 'stop'
        body daemon.do_stop_server
        session[:active_daemon_uuid] = nil if daemon.buffer[:uuid] == session[:active_daemon_uuid]
      when 'delete'
        @@daemons.delete(@@daemons.key daemon).implode
      when 'restart'
        daemon.config.merge!($config_handler.server_configs[daemon.name]) if $config_handler.server_configs[daemon.name]
        if daemon.server_running?
          daemon.do_restart_server
        else
          status 400
          "Server is not running"
        end
      when 'rcon'
        begin
          Thread.new { daemon.do_send_rcon(options[:command], host: options[:host], port: options[:port], pass: options[:pass], buffer: daemon.rcon_buffer) }
          daemon.rcon_buffer[:uuid]
        rescue => e
          log "Error while sending RCON", e
          status 500
          e.message
        end
      else
        status 400
        "Unknown action: #{action}"
      end
    else
      "Unknown thread: #{thread}"
    end
  end

  get '/config/file/:file', auth: :admin do
    config_name = params['config']
    file = params['file'].gsub('..', '')
    file = File.join CONFIG_FILES_DIR, (file == 'Bans.json' ? '' : config_name), file
    if File.exist? file
      File.read(file)
    else
      status 400
      "File not found: #{file.sub(USER_HOME, '~')}"
    end
  end

  post '/config/file/:file', auth: :admin do
    config_name = params['config']
    file = params['file']
    content = params['content']
    content << "\n" unless content.end_with? "\n"
    file = File.join(CONFIG_FILES_DIR, config_name, file)
    FileUtils.mkdir_p(File.dirname(file))
    File.write(file, content)
    "Wrote #{file.sub(USER_HOME, '~')}."
  end

  put '/config/:action', auth: :admin do
    if params['action'] == 'set'
      begin
        value = case params['variable']
        when 'server_mutators'
          params['value'].split(',')
        else
          params['value']
        end
        status, msg, current, old = $config_handler.set params['config'], params['variable'], value
        if status
          "Changed #{params['variable']}: #{old} => #{current}"
        else
          status 400
          msg
        end
      rescue => e
        msg = "Failed to set #{params['variable'] + ' -> ' + params['value']}"
        log msg, e
        status 400
        "#{msg} | #{e.class}: #{e.message}"
      end
    elsif params['action'] == 'get'
      value = $config_handler.get params['config'], params['variable']
      if value.nil?
        status 404
        "Could not find value for #{params['variable']}"
      else
        value.to_s
      end
    else
      status 400
      'Unknown action'
    end
  end

  get '/daemons', auth: :admin do
    @daemons = @@daemons
    erb :daemons
  end

  get '/daemon/:game_port', auth: :admin do
    daemon = @@daemons[params[:game_port]]
    if daemon.nil?
      status 400
      "Could not find server daemon for game port #{params[:game_port]}"
    else
      session[:active_daemon_uuid] = daemon.buffer[:uuid]
      log "Set active_server_config to daemon config with name #{daemon.config['server-config-name']} (original game port #{daemon.config['server_game_port']})"
      nil
    end
  end

  get '/monitors', auth: :admin do
    @monitors = @@monitors
    erb :monitors
  end

  get '/monitor-config', auth: :admin do
    name = params['name']
    Oj.dump $config_handler.monitor_configs[name]
  end

  post '/monitor-config/:name', auth: :admin do
    name = params['name']
    data = Oj.load(request.body.read)
    request.body.rewind
    config = data['config']
    if config['ip'] && config['query_port'] && config['rcon_port'] && config['rcon_password']
      $config_handler.monitor_configs[name] = {
        'ip' => config['ip'], 'query_port' => config['query_port'], 'rcon_port' => config['rcon_port'], 'rcon_password' => config['rcon_password'],
      }
      $config_handler.write_monitor_configs
      'Monitor config saved'
    else
      status 400
      'Missing parameter(s)'
    end
  end

  delete '/monitor-config/:name', auth: :admin do
    name = params['name']
    if $config_handler.monitor_configs[name]
      $config_handler.monitor_configs.delete name
      "Monitor config deleted"
    else
      code 400
      "Unknown monitor config"
    end
  end

  get '/monitor-configs', auth: :admin do
    @configs = $config_handler.monitor_configs
    erb :'monitor-configs'
  end

  get '/monitor/:ip/:rcon_port', auth: :admin do
    # Get UUID for RCON buffer for tailing
    key = "#{params['ip']}:#{params['rcon_port']}"
    if @@monitors[key]
      @@monitors[key].rcon_buffer[:uuid]
    else
      status 400
      'Unknown monitor'
    end
  end

  post '/monitor/:action', auth: :admin do
    data = Oj.load(request.body.read)
    request.body.rewind
    config = data['config']
    action = params['action']
    case action
    when 'start'
      if config['name'] && config['ip'] && config['query_port'] && config['rcon_port'] && config['rcon_password']
        key = "#{config['ip']}:#{config['rcon_port']}"
        if @@monitors[key]
          status 409
          "Monitor with key #{key} already exists"
        else
          @@monitors[key] = ServerMonitor.new(config['ip'], config['query_port'], config['rcon_port'], config['rcon_password'], rcon_buffer: self.class.create_buffer.last, interval: 10, delay: 0, name: config['name'])
          "Started monitor with key #{key}"
        end
      else
        status 400
        'Missing parameter(s)'
      end
    when 'stop'
      if config['ip'] && config['rcon_port']
        key = "#{config['ip']}:#{config['rcon_port']}"
        if @@monitors[key]
          @@monitors[key].stop
          @@monitors.delete key
          "Monitor stopped"
        else
          status 400
          "Monitor with key #{key} doesn't exist"
        end
      else
        status 400
        'Missing parameter(s)'
      end
    else
      status 400
      'Unknown action'
    end
  end

  get '/monitoring-details/:ip/:rcon_port', auth: :admin do
    @info = {}
    ip = params[:ip]
    rcon_port = params[:rcon_port]
    matching_daemons = @@daemons.select { |_, daemon| daemon.server_running? && daemon.active_rcon_port == rcon_port }
    @monitor = if ip == '127.0.0.1' && matching_daemons.size == 1
      matching_daemons.first.last.monitor
    else
      key = "#{ip}:#{rcon_port}"
      @@monitors[key] if @@monitors[key]
    end
    @info = @monitor.info rescue nil
    erb :'monitoring-details'
  end

  post '/admin/:action/:steam_id', auth: :admin do
    data = Oj.load(request.body.read)
    request.body.rewind
    reason = data['reason']
    steam_id = params[:steam_id]
    case params[:action]
    when 'ban'
      uuid, buffer = self.class.create_buffer
      # Thread.new { @@rcon_client.send(data['ip'], data['port'], data['pass'], "banid #{steam_id}", buffer: buffer) }
      Thread.new { @@rcon_client.send(data['ip'], data['port'], data['pass'], "permban #{steam_id}", buffer: buffer) }
      uuid
    when 'kick'
      uuid, buffer = self.class.create_buffer
      Thread.new { @@rcon_client.send(data['ip'], data['port'], data['pass'], "kick #{steam_id}", buffer: buffer) }
      uuid
    else
      status 400
      'Unknown action'
    end
  end

  post '/rcon', auth: :admin do
    body = request.body.read
    request.body.rewind
    options = Oj.load body, symbol_keys: true
    log "Calling RCON client for command: [#{options[:host]}:#{options[:port]}] (TX >>) #{options[:command]}"
    uuid, buffer = self.class.create_buffer
    Thread.new { @@rcon_client.send(options[:host], options[:port], options[:pass], options[:command], buffer: buffer) }
    uuid
  end

  get '/server-configs', auth: :admin do
    @configs = $config_handler.server_configs
    erb :'server-configs'
  end

  get '/server-config/:name', auth: :admin do
    config_name = params['name']
    config = $config_handler.server_configs[config_name]
    if config
      log "Set active server config to config with name #{config_name} (game port #{config['server_game_port']})"
      session[:active_daemon_uuid] = nil
      session[:active_server_config] = config_name
      Oj.dump(config)
    else
      status 400
      "Unknown server config: #{config_name}"
    end
  end

  post '/server-config/:name', auth: :admin do
    overwrote = !$config_handler.server_configs[params['name']].nil?
    settings = Oj.load(request.body.read)
    request.body.rewind
    $config_handler.create_server_config params['name'], settings
    "#{overwrote ? 'Overwrote' : 'Saved' } #{params['name']}"
  end

  delete '/server-config/:name', auth: :admin do
    config_name = params['name']
    if $config_handler.server_configs[config_name]
      $config_handler.delete_server_config config_name
      "Deleted #{params['name']}"
    else
      status 400
      "Server config not found: #{params['name']}"
    end
  end

  get '/get-buffer/:game_port/:type', auth: :admin do
    game_port = params[:game_port]
    daemon = @@daemons[game_port]
    if daemon.nil?
      status 400
      return "No daemon exists for game port #{game_port}"
    end
    type = params[:type]
    case type
    when 'server'
      daemon.buffer[:uuid]
    when 'rcon'
      daemon.rcon_buffer[:uuid]
    else
      status 400
      "Unknown buffer type: #{type}"
    end
  end

  post '/automatic-updates/:action', auth: :admin do
    action = params['action']
    case action
    when 'disable'
      @@config['automatic_updates'] = false
      self.class.save_webapp_config @@config
      stop_updates
    when 'enable'
      @@config['automatic_updates'] = true
      self.class.save_webapp_config @@config
      start_updates
    else
      status 400
      "Unknown action: #{action}"
    end
  end

  get '/generate-password', auth: :admin do
    ConfigHandler.generate_password
  end

  get '/download-server-logs(/:config_name)?', auth: :admin do
    config_name = params['config_name']
    zip_path = File.expand_path File.join SERVER_LOG_DIR, "#{ConfigHandler.sanitize_directory(config_name) + '-' if config_name}sandstorm-logs-#{DateTime.now.strftime('%Y-%m-%d_%H-%M-%S')}.zip"
    zip_logs zip_path, File.join(SERVER_LOG_DIR, config_name ? "#{config_name}*.log" : '*.log')
    begin
      send_file zip_path, filename: File.basename(zip_path), disposition: :attachment
    ensure
      Thread.new { FileUtils.rm zip_path }
    end
  end

  get '/download-wrapper-logs', auth: :host do
    zip_path = File.expand_path File.join WEBAPP_ROOT, 'log', "saw-logs-#{DateTime.now.strftime('%Y-%m-%d_%H-%M-%S')}.zip"
    zip_logs zip_path, File.join(WEBAPP_ROOT, 'log', '*.log*')
    begin
      send_file zip_path, filename: File.basename(zip_path), disposition: :attachment
    ensure
      Thread.new { FileUtils.rm zip_path }
    end
  end
end

def get_webrick_options(config = SandstormAdminWrapperSite.load_webapp_config)
  webrick_options = {
    AccessLog: [[LOGGER, WEBrick::AccessLog::COMMON_LOG_FORMAT], [LOGGER, WEBrick::AccessLog::REFERER_LOG_FORMAT]],
    Host:      config['admin_interface_bind_ip'],
    Port:      config['admin_interface_bind_port'],
    Logger:    LOGGER, # Logger.new(IO::NULL),
    app:       SandstormAdminWrapperSite, # app must be lowercase
    SSLEnable: config['admin_interface_use_ssl']
  }

  if config['admin_interface_use_ssl']
    webrick_options.merge!({
      SSLVerifyClient: config['admin_interface_verify_ssl'] ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE,
      SSLCertName:     [[ 'CN', WEBrick::Utils::getservername ]]
    })
    if File.exist?(config['admin_interface_ssl_cert']) && File.exist?(config['admin_interface_ssl_key'])
      webrick_options.merge!({
        SSLCertificate: OpenSSL::X509::Certificate.new(File.read config['admin_interface_ssl_cert']),
        SSLPrivateKey:  OpenSSL::PKey::RSA.new(File.read config['admin_interface_ssl_key'])
      })
    else
      # Make temporary cert/key, since WEBrick's defaults won't work with modern browsers
      cert, key = CertificateGenerator.generate
      log "Writing generated certs to file", level: :info
      config['admin_interface_ssl_cert'] = GENERATED_SSL_CERT
      config['admin_interface_ssl_key'] = GENERATED_SSL_KEY
      SandstormAdminWrapperSite.save_webapp_config(config)
      File.write GENERATED_SSL_CERT, cert
      File.write GENERATED_SSL_KEY, key
      webrick_options.merge!({
        SSLCertificate: cert,
        SSLPrivateKey: key,
      })
    end
  end
  webrick_options
rescue => e
  log "Couldn't create webrick options", e
  raise
end

begin
  config = SandstormAdminWrapperSite.load_webapp_config
  options = get_webrick_options(config)
  log "Starting webserver with options: #{options}"
  begin
    $server = Rack::Server.new(options)
    Thread.new { sleep 1; log "Webserver initialized! Visit: http#{'s' if config['admin_interface_use_ssl']}://#{config['admin_interface_bind_ip'] == '0.0.0.0' ? '127.0.0.1' : config['admin_interface_bind_ip']}:#{config['admin_interface_bind_port']}", level: :info }
    $server.start
  rescue Exception => e
    raise if e.is_a? StandardError
    log "Exception caused webserver exit", e
  end
rescue => e
  log "Error caused webserver exit", e
  exit 1
ensure
  log "Webserver stopped"
  $config_handler.write_config
  `stty echo` unless WINDOWS || !$stdout.isatty
end
