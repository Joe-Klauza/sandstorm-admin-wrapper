require 'file-tail'
require_relative 'rcon-client'
require_relative 'server-monitor'
require_relative 'server-updater'
require_relative 'subprocess'

include Process

class SandstormServerDaemon
  attr_accessor :config
  attr_accessor :executable
  attr_accessor :server_root_dir
  attr_accessor :arguments
  attr_accessor :rcon_ip
  attr_accessor :rcon_port
  attr_accessor :rcon_pass
  attr_accessor :player_feed
  attr_accessor :steam_api_key
  attr_reader :frozen_config
  attr_reader :name
  attr_reader :id
  attr_reader :active_game_port
  attr_reader :active_rcon_port
  attr_reader :active_query_port
  attr_reader :active_rcon_pass
  attr_reader :buffer
  attr_reader :rcon_buffer
  attr_reader :chat_buffer
  attr_reader :rcon_client
  attr_reader :game_pid
  attr_reader :threads
  attr_reader :monitor
  attr_reader :log_file
  attr_reader :rcon_listening

  def initialize(config, daemons, mutex, rcon_client, server_buffer, rcon_buffer, chat_buffer, steam_api_key: '')
    @config = config
    @name = @config['server-config-name']
    @id = @config['id']
    @daemons = daemons
    @daemons_mutex = mutex
    @monitor_mutex = Mutex.new
    @rcon_ip = '127.0.0.1'
    @buffer = server_buffer
    @rcon_buffer = rcon_buffer
    @chat_buffer = chat_buffer
    @rcon_client = rcon_client
    @rcon_listening = false
    @game_pid = nil
    @monitor = nil
    @threads = {}
    @buffer[:persistent] = true
    @rcon_buffer[:persistent] = true
    @chat_buffer[:persistent] = true
    @chat_buffer[:filters] = [
      Proc.new do |line|
        line.gsub!(/\x1b\[[0-9;]*m/, '') # Remove color codes
        line.gsub!(/^(\d{4}\/\d{2}\/\d{2}) (\d{2}:\d{2}:\d{2}).*TX >>\) say/, '\1 \2 ADMIN:') # Cut down RCON messages (TX)
        line.gsub!(/^\[(\d{4})\.(\d{2})\.(\d{2})-(\d{2}).(\d{2}).(\d{2}).*LogChat: Display: /, '\1/\2/\3 \4:\5:\6 ') # Cut down server log messages (RX)
      end
    ]
    @buffer[:filters] = [
      Proc.new do |line|
        line.gsub!(/\x1b\[[0-9;]*m/, '') # Remove color codes
        line.prepend "#{get_server_id} | "
      end
    ]
    @rcon_buffer[:filters] = [
      Proc.new { |line| line.prepend "#{get_server_id} | " }
    ]
    @log_file = nil
    @player_feed = []
    @admin_ids = nil
    @steam_api_key = steam_api_key
    @exit_requested = false
    start_daemon
    log "Daemon initialized"
  end

  def log(message, exception=nil, level: nil)
    super("#{get_server_id} | #{message}", exception, level: level) # Call the log function created by logger
  end

  def get_server_id
    conf = @frozen_config || @config
    "[PID #{@game_pid || '(N/A)'} Ports #{[conf['server_game_port'], conf['server_query_port'], conf['server_rcon_port']].join(',')}]"
  end

  def server_running?
    if @game_pid.nil?
      return false
    end
    Process.kill(0, @game_pid)
    true
  rescue Errno::ESRCH
    false
  end

  def do_pre_update_warning(sleep_length: 5)
    log "Sending restart warning to server", level: :info
    message = 'say This server is restarting in 5 seconds to apply a new server update.'
    message << ' This may take some time.' if WINDOWS # Since we have to stop the server before downloading the update
    do_blast_message(message)
    sleep sleep_length
  rescue => e
    log "Error while trying to message players", e
  end

  def do_blast_message(message, amount: 3, interval: 0.2)
    amount.times do |i|
      do_send_rcon message
      sleep interval unless i + 1 == amount
    end
  end

  def is_sandstorm_admin?(steam_id)
    @admin_ids.include?(steam_id.to_s)
  end

  def do_send_rcon(command, host: nil, port: nil, pass: nil, buffer: nil, outcome_buffer: nil, no_rx: false)
    host ||= @rcon_ip
    port ||= @active_rcon_port || @config['server_rcon_port']
    port ||= @active_rcon_pass
    pass ||= @active_rcon_pass || @config['server_rcon_password']
    buffer ||= @rcon_buffer
    outcome_buffer ||= buffer
    log "Calling RCON client for command: #{command}"
    @rcon_client.send(host, port, pass, command, buffer: buffer, outcome_buffer: outcome_buffer, no_rx: no_rx)
  end

  def do_start_server
    @exit_requested = false
    # log "start daemons mutex wait"
    @daemons_mutex.synchronize do
      # log "start daemons mutex start"
      return "Exiting" if @exit_requested
      if server_running? || (@threads[:game_server] && @threads[:game_server].alive?)
        "Server is already running. PID: #{@game_pid}"
      else
        new_game_port = @config['server_game_port']
        if @active_game_port && @active_game_port != new_game_port
          # We need to move the daemon for future access
          log "Moving daemon #{@active_game_port} -> #{new_game_port}"
          former_tenant = @daemons[new_game_port]
          if former_tenant
            log "Stopping daemon #{former_tenant.name} using desired game port #{new_game_port}", level: :warn
            former_tenant.implode
          end
          @daemons[new_game_port] = @daemons.delete @active_game_port
        end
        log "Starting server", level: :info
        @server_started = false
        @server_failed = false
        @game_pid = nil
        @threads[:game_server] = get_game_server_thread
        sleep 0.1 until @game_pid || @server_failed
        @game_pid ? "Server is starting. PID: #{@game_pid}" : "Server failed to start!"
      end
      # log "start daemons mutex end"
    end
    # log "start daemons mutex clear"
  end

  def do_restart_server
    log "Restarting server", level: :info
    do_stop_server
    do_start_server
  end

  def do_stop_server
    @exit_requested = true
    # log "stop daemons mutex wait"
    @daemons_mutex.synchronize do
      # log "stop daemons mutex start"
      return 'Server not running.' unless server_running?
      log "Stopping server", level: :info
      # No need to do anything besides remove it from monitoring
      # We want the signal to be sent to the thread's subprocess
      # so that the thread has time to set the status/message in the buffer
      @server_thread_exited = false
      @threads.delete(:game_server)
      msg = kill_server_process
      log "Waiting for server thread to exit and clean up"
      sleep 0.2 until @server_thread_exited || @server_failed
      log "Server thread #{@server_failed ? "failed" : "exited and cleaned up"}"
      msg
      # log "stop daemons mutex end"
    end
    # log "stop daemons mutex clear"
  end

  def implode
    log "Daemon for server #{@name} (#{@config['id']}) imploding", level: :info
    @exit_requested = true
    @game_pid = nil
    @buffer.reset
    @buffer = nil
    @rcon_buffer.reset
    @rcon_buffer = nil
    Thread.new { @monitor.stop if @monitor }
    game_server_thread = @threads.delete :game_server
    kill_server_process
    game_server_thread.join
    @threads.keys.each do |thread_name|
      thread = @threads.delete thread_name
      thread.kill if thread.respond_to? :kill
    end
  end

  def kill_server_process(signal: nil)
    signal = 'KILL' if signal.nil? # TERM can hang shutting down EAC. KILL doesn't, but might not disconnect players (instead they time out).
    return "Unable to send #{signal} (#{Signal.list[signal]}) signal to server; no known PID!" unless @game_pid
    return "Server isn't running!" unless server_running?
    begin
      Process.kill(signal, @game_pid)
    rescue Errno::ESRCH
    end
    msg = "Sent #{signal} (#{Signal.list[signal]}) signal to PID #{@game_pid}."
    log msg, level: :info
    msg
  end

  def create_monitor
    @monitor_mutex.synchronize do
      if @monitor.nil?
        Thread.new { @monitor = ServerMonitor.new('127.0.0.1', @active_query_port, @active_rcon_port, @active_rcon_pass, name: @name, rcon_buffer: @rcon_buffer, interval: 5, daemon_handle: self) }
      end
      sleep 0.5 while @monitor.nil? && !(@exit_requested)
    end
  end

  def run_game_server
    log "Applying config"
    @frozen_config = @config.dup
    $config_handler.apply_server_config_files @frozen_config
    @admin_ids = $config_handler.get_server_config_file_content(:admins_txt, @frozen_config['id']).split("\n").map { |l| l[/\d{17}/] }.compact
    executable = BINARY
    arguments = $config_handler.get_server_arguments(@frozen_config)
    @active_game_port = @frozen_config['server_game_port']
    @active_query_port = @frozen_config['server_query_port']
    @active_rcon_port = @frozen_config['server_rcon_port']
    @active_rcon_pass = @frozen_config['server_rcon_password']
    @log_file = $config_handler.get_log_file(@frozen_config['id'])
    log "Spawning game process: #{[executable, *arguments].inspect}", level: :info
    SubprocessRunner.run(
      [executable, *arguments],
      buffer: @buffer,
      pty: false,
      no_prefix: true,
      formatter: Proc.new { |output, _| WINDOWS ? "#{datetime} | #{output.chomp}" : output.chomp } # Windows doesn't have the timestamp, so we'll add our own to make it look nice.
    ) do |pid|
      @game_pid = pid
      log "Game process spawned. Starting self-monitoring after detecting RCON listening message.", level: :info
      @rcon_tail_thread = Thread.new do
        # last_modified_log_time = File.mtime(Dir[File.join(SERVER_LOG_DIR, '*.log')].sort_by{|f| File.mtime(f) }.last).to_i rescue 0
        # other_used_logs = @daemons.map { |_, daemon| daemon.log_file }
        # @rcon_buffer[:data] << "[PID: #{@game_pid} Game Port: #{@active_game_port}] Waiting to detect log file in use"
        log "Waiting to ensure log file is in use"
        earlier = Time.now.to_i
        loop do
          last_updated = File.mtime(@log_file).to_i
          break if last_updated > earlier
          sleep 0.5
        end
        log "Log file is in use. Proceeding with log tailing."
        begin
          File.open(@log_file) do |log|
            log.extend(File::Tail)
            log.interval = 0.1
            log.backward(0)
            last_line_was_rcon = false
            log.tail do |line|
              next if line.nil?
              if line.include? 'LogRcon'
                last_line_was_rcon = true
                if line[/LogRcon: Error: Failed to create TcpListener at .* for rcon support/]
                  log "RCON failed to initialize: #{line}", level: :warn
                  kill_server_process
                elsif !@rcon_listening && line.include?('LogRcon: Rcon listening') && @monitor.nil?
                  @rcon_listening = true
                  create_monitor
                  Thread.new do
                    log "RCON listening. Waiting for Server Query success before ending server lock", level: :info
                    sleep 0.5 until @monitor.all_green? || @exit_requested
                    log "Server is ready (RCON and Query connected). Server start lock ending.", level: :info
                    @server_started = true
                  end
                elsif line.include? 'SANDSTORM_ADMIN_WRAPPER'
                elsif line[/^[\[\]0-9.:-]+\[[0-9 ]+\]LogRcon: \d+.\d+.\d+.\d+:\d+ <<\s+banid (.*)/]
                  @daemons.reject{ |_,d| d == self || !d.rcon_listening || d.nil? }.each do |id, daemon|
                    begin
                      args = $1.split(' ')
                      if args.size > 0
                        args = $config_handler.parse_banid_args(args)
                        daemon.do_send_rcon("banid #{args.join(' ')} SANDSTORM_ADMIN_WRAPPER") # Give a custom suffix so we don't recursively unban
                      end
                    rescue => e
                      log "Failed to 'banid #{$1}' from server #{daemon.name} (#{id})"
                    end
                  end
                elsif line[/^[\[\]0-9.:-]+\[[0-9 ]+\]LogRcon: \d+.\d+.\d+.\d+:\d+ <<\s+unban (\d+)/]
                  # Allow unbans with master bans
                  $config_handler.unban_master($1)
                  log "Unbanning ID #{$1} from all servers (unban command detected)", level: :info
                  @daemons.reject{ |_,d| d == self || !d.rcon_listening || d.nil? }.each do |id, daemon|
                    begin
                      daemon.do_send_rcon("unban #{$1} SANDSTORM_ADMIN_WRAPPER") # Give a custom suffix so we don't recursively unban
                    rescue => e
                      log "Failed to unban #{$1} from server #{daemon.name} (#{id})"
                    end
                  end
                end
              elsif last_line_was_rcon
                if line =~ /^\[\d{4}\.\d{2}\.\d{2}-\d{2}\.\d{2}\.\d{2}:/ || line =~ /^Log/
                  last_line_was_rcon = false
                end
              end
              if line.include? 'LogChat'
                @chat_buffer[:filters].each { |filter| filter.call(line) } # Remove color codes; add server ID
                @chat_buffer.synchronize { @chat_buffer.push line.chomp }
              elsif last_line_was_rcon
                @buffer[:filters].each { |filter| filter.call(line) } # Remove color codes; add server ID
                @rcon_buffer.synchronize { @rcon_buffer.push line.chomp }
              end
            end
          end
        rescue EOFError
        rescue => e
          log "Error in RCON tail thread!", e
          raise e
        ensure
          log "RCON tail thread stopped"
        end
      end
      log "RCON tailing thread started."
    end
    log 'Game process exited', level: :info
  ensure
    @rcon_tail_thread.kill rescue nil
  end

  def get_game_server_thread
    Thread.new do
      if !@exit_requested
        run_game_server
      end
    rescue => e
      @server_failed = true
      log "Game server failed", e
      Thread.new { @monitor.stop if @monitor }
      @threads.delete :game_server unless @server_started # If we can't even start the server, don't keep trying
      kill_server_process
    ensure
      @server_thread_exited = true
      begin
        @monitor.stop unless @monitor.nil?
        @monitor = nil
        @game_pid = nil
        @log_file = nil
        @rcon_listening = false
        socket = @rcon_client.sockets["127.0.0.1:#{@active_rcon_port}"]
        @rcon_client.delete_socket(socket) unless socket.nil?
      rescue => e
        log "Error while cleaning up game server thread", e
      end
      log "Game server thread exiting"
    end
  end

  def start_daemon(thread_check_interval: 2)
    @daemon_thread = Thread.new do
      while true
        while @threads.empty? || @threads.values.all?(&:alive?)
          sleep thread_check_interval
        end
        dead_threads = @threads.select { |_, t| !t.alive? }.keys
        log "Dead daemon thread(s) detected: #{dead_threads.join(' ')}"
        dead_threads.each do |key|
          if @threads[key]
            log "Starting #{key} thread", level: :info
            @threads[key] = public_send("get_#{key.to_s}_thread")
          end
        end
        sleep thread_check_interval
      end
    rescue => e
      log "Error in daemon's self-monitoring thread", e
      raise
    end
  end
end
