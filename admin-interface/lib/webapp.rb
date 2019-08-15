WINDOWS = Gem.win_platform?

require 'pry'
require 'cgi'
require 'net/http'
require 'openssl'
require 'sinatra/base'
require 'sys/proctable'
require 'sysrandom'
require 'toml-rb'
require 'webrick'
require 'webrick/https'
require_relative 'logger'
require_relative 'buffer'
require_relative 'certificate-generator'
require_relative 'daemon'
require_relative 'config-handler'
require_relative 'user'
require_relative 'rcon-client'

Encoding.default_external = "UTF-8"

log "Loading config"
$config_handler = ConfigHandler.new

class SandstormAdminWrapperSite < Sinatra::Base
  def self.set_up
    log "Initializing webserver"
    @@daemon = nil
    @@monitors = {}
    @@buffers = {}
    @@buffer_mutex = Mutex.new
    @@rcon_client = RconClient.new
    $config_handler.init_server_config_files
  end

  def which(command)
    exts = ENV['PATHEXT'] ? ENV['PATHEXT'].split(';') : ['']
    ENV['PATH'].split(File::PATH_SEPARATOR).each do |path|
      exts.each do |ext|
        exe = File.join(path, "#{command}#{ext}")
        return exe if File.executable?(exe) && !File.directory?(exe)
      end
    end
    nil
  end

  def steamcmd_installed?
    on_path = WINDOWS ? which("steamcmd.exe") : (which("steamcmd") || which("steamcmd.sh"))
    return on_path unless on_path.nil?
    in_dir = File.join WRAPPER_ROOT, 'steamcmd', 'installation', (WINDOWS ? "steamcmd.exe" : "steamcmd.sh")
    return in_dir if File.exist? in_dir
    false
  end

  def game_server_installed?
    return false if @@daemon.nil?
    return false unless @@daemon.server_installed?
    @@daemon.executable
  end

  def get_server_status
    return 'OFF' if @@daemon.nil?
    @@daemon.server_running? ? 'ON' : 'OFF'
  end

  def get_update_status
    return 'OFF' if @@daemon.nil?
    @@daemon.updates_running? ? 'ON' : 'OFF'
  end

  def check_prereqs
    steamcmd_path = steamcmd_installed?
    init_daemon(steamcmd_path) if steamcmd_path && @@daemon.nil?
    game_server_path = game_server_installed?
    return [steamcmd_path, game_server_path]
  end

  def get_update_info
    @@daemon.server_updater.get_update_info
  end

  def init_daemon(steamcmd_path)
    log "Initializing daemon...", level: :info
    @@daemon = SandstormServerDaemon.new(
      $config_handler.config['server_executable'],
      File.join(WRAPPER_ROOT, 'sandstorm-server'),
      steamcmd_path,
      $config_handler.config['steam_appinfovdf_path'],
      @@rcon_client,
      create_buffer('0').last,
      create_buffer('1').last
    )
  end

  def create_buffer(uuid=nil)
    @@buffer_mutex.synchronize do
      return [uuid, @@buffers[uuid]] unless @@buffers[uuid].nil?
      uuid = Sysrandom.uuid if uuid.nil?
      buffer = Buffer.new
      @@buffers[uuid] = buffer
      [uuid, buffer]
    end
  end

  set_up

  configure do
    working_directory = File.join File.dirname(__FILE__), '..', 'docroot'
    log "Setting webserver root dir to: #{working_directory.sub(USER_HOME, '~')}", level: :info
    set :root, working_directory
    enable :sessions, :logging, :dump_errors, :raise_errors, :show_exceptions
    # use Rack::CommonLogger, LOGGER
  end

  # Add a condition that we can use for various routes
  register do
    def auth(role)
      condition do
        begin
          unless has_role?(role)
            log "#{request.ip} | User unauthorized: '#{session[:user_id]}' requesting #{role}-privileged content", level: :warn
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
      has_role(:host)
    end

    def is_admin?
      has_role(:admin)
    end

    def is_user?
      has_role(:user)
    end
  end

  before do
    env['rack.logger'] = LOGGER
    env["rack.errors"] = LOGGER
    @user = $config_handler.users[session[:user_id]] if session[:user_id]
    # log "Redirecting unauthenticated user to login"
    # redirect "/login/#{CGI.escape request.path_info}" if @user.nil? && !(request.path_info.start_with? '/login')
    check_prereqs unless @@daemon
    request.body.rewind
    body = request.body.read
    request.body.rewind # Be kind
    # message = "Request: #{request.request_method}#{' ' << request.script_name unless request.script_name.strip.empty? } #{request.path_info}#{'?' << request.query_string unless request.query_string.strip.empty?} from #{request.ip}#{(' | Body: ' << body) unless body.strip.empty?}"
    # log message
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
        log "#{request.ip} | Logged in as #{known_user.name}", level: :info
        session[:user_id] = known_user.id
        return known_user.first_login? ? "/change-password#{destination}" : destination
      end
    end
    status 401
    "Failed to log in."
  end

  get '/logout' do
    session[:user_id] = nil
    redirect '/login'
  end

  get '/change-password(/:destination)?', auth: :user do
    @destination = "/#{params['destination']}".sub('/change-password', '')
    @first_login = !@user.initial_password.nil?
    erb :'change-password'
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
    destination
  end

  get '/wrapper-config', auth: :host do
    @config = load_webapp_config
    erb :'wrapper-config', layout: :'layout-main'
  end

  put '/wrapper-config/:action', auth: :host do
    wrapper_config = load_webapp_config
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
          save_webapp_config(wrapper_config)
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
    Thread.new do
      LOGGER.threshold :fatal # Turn down STDOUT logging
      `stty echo` unless WINDOWS # Ensure we have echoing enabled; something from logging turns them off...

      # Stuff

      binding.pry
    ensure
      LOGGER.threshold :debug
    end.join
    nil
  rescue Interrupt
  end

  get '/threads', auth: :user do
    return '' if @@daemon.game_pid.nil?
    process = Sys::ProcTable.ps(pid: @@daemon.game_pid)
    threads = WINDOWS ? process.thread_count : process.nlwp
    output = threads.nil? ? '' : "Threads: #{threads}"
    @monitor = @@daemon.monitor
    @info = @monitor.info unless @monitor.nil?
    return output if @info.nil?
    "#{output} | Players: #{@info[:rcon_players].size rescue ''} | Bots: #{@info[:rcon_bots].size rescue ''}"
  end

  get '/players', auth: :user do
    @monitor = @@daemon.monitor
    @info = @monitor.info unless @monitor.nil?
    erb :'players'
  end

  get '/update-info', auth: :user do
    @update_available, @old_build, @new_build = get_update_info
    erb(:'update-info')
  end

  get '/test', auth: :user do
    # Stuff
  end

  post '/restart-wrapper', auth: :host do
    Thread.new { sleep 0.2; exec 'bundle', 'exec', 'ruby', $PROGRAM_NAME, *ARGV }
    nil
  end

  get '/', auth: :user do
    @steamcmd_path, @game_server_path = check_prereqs
    redirect '/setup' unless @steamcmd_path && @game_server_path
    redirect '/control'
  end

  get '/about', auth: :user do
    erb(:about, layout: :'layout-main')
  end

  get '/setup', auth: :admin do
    @steamcmd_path, @game_server_path = check_prereqs
    erb(:'server-setup', layout: :'layout-main')
  end

  get '/config', auth: :admin do
    @config = $config_handler.config.dup
    erb(:'server-config', layout: :'layout-main')
  end

  get '/control', auth: :admin do
    @server_status = get_server_status
    erb(:'server-control', layout: :'layout-main') do
      redirect '/setup' if @@daemon.nil?
      @monitor = @@daemon.monitor rescue nil
      @info = @monitor.info rescue nil
      erb :players
    end
  end

  get '/tools/:resource', auth: :admin do
    @config = $config_handler.config.dup
    resource = params['resource']
    case resource
    when 'rcon'
      erb(:'rcon-tool', layout: :'layout-main')
    when 'steamcmd'
      @server_root_dir = @@daemon.server_root_dir rescue nil
      redirect '/setup' if @server_root_dir.nil?
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
      uuid, buffer = create_buffer
      Thread.new { @@daemon.do_run_steamcmd(options[:command].split("\n"), buffer: buffer) }
      uuid
    else
      status 400
      "Unknown resource: #{resource}"
    end
  end

  get '/script/:resource', auth: :user do
    resource = params['resource']
    case resource
    when 'server-status'
      get_server_status
    else
      status 500
      "Unknown resource: #{resource}"
    end
  end

  get '/buffer/:uuid(/:bookmark)?', auth: :admin do # Sensitive information could be contained in these buffers (passwords, paths); admins only.
    uuid = params['uuid']
    unless @@buffers.keys.include? uuid
      status 400
      return "Unknown UUID: #{uuid}"
    end
    buffer = @@buffers[uuid]
    @bookmark_uuid = params['bookmark']
    limit = 500

    buffer[:mutex].synchronize do # Synchronize with the writing thread to avoid mismatched indices when truncating, etc.
      buffer[:iterator] = buffer[:iterator].nil? ? 1 : buffer[:iterator] + 1
      # log "Buffer [#{uuid}][#{buffer[:iterator]}] arrived with bookmark: [#{@bookmark_uuid}] -> #{buffer[:bookmarks][@bookmark_uuid]}"
      # log "Buffer [#{uuid}][#{buffer[:iterator]}] Bookmarks: #{buffer[:bookmarks]}"
      if buffer[:bookmarks].length > 10
        log "Buffer has many bookmarks! Are that many clients connected? #{buffer}", level: :warn
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
      start_index = 0 if start_index > buffer[:data].length
      # log "Buffer [#{uuid}][#{buffer[:iterator]}] start_index unexpectedly negative" if start_index < 0
      new_bookmark_uuid = Sysrandom.uuid
      new_bookmark = (buffer[:data].length - start_index > limit) ? (start_index + limit) : buffer[:data].length
      # log "Buffer - Calculated new_bookmark: #{new_bookmark}"
      if new_bookmark == buffer[:data].length && !buffer[:status].nil?
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
    if @@daemon.nil?
      status 400
      return 'Server daemon not configured; ensure setup is complete.'
    end
    thread = params['thread']
    action = params['action']
    body = request.body.read
    request.body.rewind
    options = Oj.load body, symbol_keys: true
    validate = params['validate'] == "true"
    case thread
    when 'server'
      case action
      when 'install'
        uuid, buffer = create_buffer
        log "Installing server"
        Thread.new do
          @@daemon.do_install_server(buffer, validate: validate)
        end
        log "Server install thread started. Returning UUID: #{uuid}"
        uuid
      when 'update'
        uuid, buffer = create_buffer
        log "Updating server"
        Thread.new do
          @@daemon.do_update_server(buffer, validate: validate)
        end
        log "Server update thread started. Returning UUID: #{uuid}"
        uuid
      when 'start'
        @@daemon.do_start_server
      when 'stop'
        @@daemon.do_stop_server
      when 'restart'
        @@daemon.do_restart_server
      when 'rcon'
        begin
          uuid, buffer = create_buffer
          Thread.new { @@daemon.do_send_rcon(options[:command], host: options[:host], port: options[:port], pass: options[:pass], buffer: buffer) }
          uuid
        rescue => e
          log "Error while sending RCON", e
          status 500
          e.message
        end
      else
        status 400
        "Unknown action: #{action}"
      end
    when 'updates'
      case action
      when 'start'
        @@daemon.do_start_updates
      when 'stop'
        @@daemon.do_stop_updates
        'Updates stopped'
      when 'restart'
        @@daemon.do_restart_updates
        'Updates restarted'
      else
        status 400
        "Unknown action: #{action}"
      end
    else
      "Unknown thread: #{thread}"
    end
  end

  get '/config/file/:file', auth: :admin do
    file = File.join CONFIG_FILES_DIR, params['file'].gsub('..', '')
    if File.exist? file
      File.read(file)
    else
      status 400
      "File not found: #{file.sub(USER_HOME, '~')}"
    end
  end

  post '/config/file/:file', auth: :admin do
    file = params['file']
    content = params['content']
    content << "\n" unless content.end_with? "\n"
    File.write(File.join(CONFIG_FILES_DIR, file), content)
    "Wrote #{file}."
  end

  put '/config/:action', auth: :admin do
    if params['action'] == 'set'
      begin
        status, msg, current, old = $config_handler.set params['variable'], params['value']
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
      value = $config_handler.get params['variable']
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
          @@monitors[key] = ServerMonitor.new(config['ip'], config['query_port'], config['rcon_port'], config['rcon_password'], interval: 10, delay: 0, name: config['name'])
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
    key = "#{ip}:#{rcon_port}"
    @monitor = @@monitors[key] if @@monitors[key]
    @info = @monitor.info unless @monitor.nil?
    erb :'monitoring-details'
  end

  post '/admin/:action/:steam_id', auth: :admin do
    data = Oj.load(request.body.read)
    request.body.rewind
    reason = data['reason']
    steam_id = params[:steam_id]
    case params[:action]
    when 'ban'
      uuid, buffer = create_buffer
      Thread.new { @@rcon_client.send(data['ip'], data['port'], data['pass'], "permban #{steam_id}", buffer: buffer) }
      uuid
    when 'kick'
      uuid, buffer = create_buffer
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
    uuid, buffer = create_buffer
    Thread.new { @@rcon_client.send(options[:host], options[:port], options[:pass], options[:command], buffer: buffer) }
    uuid
  end
end

def load_webapp_config(config_file = WEBAPP_CONFIG)
  TomlRB.load_file config_file
rescue => e
  log "Couldn't load config from #{config_file}", e
  raise
end

def save_webapp_config(config, config_file = WEBAPP_CONFIG)
  File.write(config_file, TomlRB.dump(config))
end

def get_webrick_options(config = load_webapp_config)
  config = load_webapp_config
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
  config = load_webapp_config
  unless config['admin_interface_session_secret'].to_s.empty?
    class SandstormAdminWrapperSite
      config = load_webapp_config # Yay scope!
      set :session_secret, config['admin_interface_session_secret']
    end
  end
  options = get_webrick_options(config)
  log "Starting webserver with options: #{options}"
  begin
    $server = Rack::Server.new(options)
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
end
