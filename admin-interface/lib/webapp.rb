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
require_relative 'daemon'
require_relative 'config-handler'

Encoding.default_external = "UTF-8"

log "Loading config"
$config_handler = ConfigHandler.new

class SandstormAdminWrapperSite < Sinatra::Base
  def self.set_up
    log "Initializing webserver"
    working_directory = File.join File.dirname(__FILE__), '..', 'docroot'
    log "Setting webserver root dir to: #{working_directory.sub(USER_HOME, '~')}", level: :info
    set :root, working_directory
    enable :sessions
    @@daemon = nil
    @@buffers = {}
    @@buffer_mutex = Mutex.new
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
    game_server_path = game_server_installed?
    init_daemon(steamcmd_path) if steamcmd_path && @@daemon.nil?
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

  before do
    env["rack.errors"] = LOGGER
    check_prereqs unless @@daemon
    request.body.rewind
    body = request.body.read
    request.body.rewind # Be kind
    # message = "Request: #{request.request_method}#{' ' << request.script_name unless request.script_name.strip.empty? } #{request.path_info}#{'?' << request.query_string unless request.query_string.strip.empty?} from #{request.ip}" # Body may contain sensitive info ##{(' | Body: ' << body) unless body.strip.empty?}"
    # log message
  end

  # after do
  #  log "Responding: #{response.body}"
  # end

  get '/pry' do
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

  get '/threads' do
    return '' if @@daemon.game_pid.nil?
    process = Sys::ProcTable.ps(pid: @@daemon.game_pid)
    threads = WINDOWS ? process.thread_count : process.nlwp
    threads.nil? ? '' : "Threads: #{threads}"
  end

  get '/players' do
    @info = @@daemon.monitor.info unless @@daemon.monitor.nil?
    erb :'players'
  end

  get '/update-info' do
    @update_available, @old_build, @new_build = get_update_info
    erb(:'update-info')
  end

  get '/test' do
    # Stuff
  end

  get '/restart' do
    exec 'bundle', 'exec', 'ruby', $PROGRAM_NAME, *ARGV
  end

  get '/' do
    @steamcmd_path, @game_server_path = check_prereqs
    redirect '/setup' unless @steamcmd_path && @game_server_path
    redirect '/control'
  end

  get '/setup' do
    @steamcmd_path, @game_server_path = check_prereqs
    erb(:'server-setup', layout: :'layout-main')
  end

  get '/config' do
    @config = $config_handler.config.dup
    erb(:'server-config', layout: :'layout-main')
  end

  get '/control' do
    @server_status = get_server_status
    erb(:'server-control', layout: :'layout-main') do
      @info = @monitor.info unless @monitor.nil?
      erb :players
    end
  end

  get '/tools/:resource' do
    @config = $config_handler.config.dup
    resource = params['resource']
    case resource
    when 'rcon'
      erb(:'rcon-tool', layout: :'layout-main')
    when 'steamcmd'
      @server_root_dir = @@daemon.server_root_dir
      erb(:'steamcmd-tool', layout: :'layout-main')
    else
      status 500
      "Unknown resource: #{resource}"
    end
  end

  post '/tools/:resource' do
    resource = params['resource']
    body = request.body.read
    options = Oj.load body, symbol_keys: true
    request.body.rewind
    case resource
    when 'rcon'
      options = Oj.load body, symbol_keys: true
      options.select { |_, v| v.nil? }.each { |k, _| options.delete k }
      uuid, buffer = create_buffer
      options[:buffer] = buffer
      Thread.new { @@daemon.do_send_rcon(options.delete(:command), options) }
      uuid
    when 'steamcmd'
      uuid, buffer = create_buffer
      Thread.new { @@daemon.do_run_steamcmd(options[:command].split("\n"), buffer: buffer) }
      uuid
    else
      status 400
      "Unknown resource: #{resource}"
    end
  end

  get '/script/:resource' do
    resource = params['resource']
    case resource
    when 'server-status'
      get_server_status
    else
      status 500
      "Unknown resource: #{resource}"
    end
  end

  get '/buffer/:uuid(/:bookmark)?' do
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

  post '/control/:thread/:action' do
    if @@daemon.nil?
      status 400
      return 'Server daemon not configured; ensure setup is complete.'
    end
    thread = params['thread']
    action = params['action']
    body = request.body.read
    options = Oj.load body, symbol_keys: true
    request.body.rewind
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
          Thread.new { @@daemon.do_send_rcon(options[:command], buffer: buffer) }
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

  get '/config/file/:file' do
    file = File.join CONFIG_FILES_DIR, params['file'].gsub('..', '')
    if File.exist? file
      File.read(file)
    else
      status 400
      "File not found: #{file.sub(USER_HOME, '~')}"
    end
  end

  post '/config/file/:file' do
    file = params['file']
    content = params['content']
    content << "\n" unless content.end_with? "\n"
    File.write(File.join(CONFIG_FILES_DIR, file), content)
    "Wrote #{file}."
  end

  put '/config/:action' do
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
end

def load_webapp_config(config_file = "#{File.dirname __FILE__}/../../config/config.toml")
  TomlRB.load_file config_file
rescue => e
  log "Couldn't load config from #{config_file}", e
  raise
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
      set :session_secret, config.admin_interface_session_secret
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
