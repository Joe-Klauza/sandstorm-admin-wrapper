require 'file-tail'
require_relative 'rcon-client'
require_relative 'server-monitor'
require_relative 'server-updater'
require_relative 'subprocess'

include Process

class SandstormServerDaemon
  attr_accessor :executable
  attr_accessor :server_root_dir
  attr_accessor :arguments
  attr_accessor :rcon_ip
  attr_accessor :rcon_port
  attr_accessor :rcon_pass
  attr_reader :active_game_port
  attr_reader :active_rcon_port
  attr_reader :active_query_port
  attr_reader :active_rcon_pass
  attr_reader :buffer
  attr_reader :config
  attr_reader :rcon_buffer
  attr_reader :rcon_client
  attr_reader :game_pid
  attr_reader :threads
  attr_reader :monitor
  attr_reader :log_file

  def initialize(config, daemons, mutex, rcon_client, server_buffer, rcon_buffer)
    @config = config
    @name = @config['server-config-name']
    @daemons = daemons
    @daemons_mutex = mutex
    @rcon_ip = '127.0.0.1'
    @buffer = server_buffer
    @rcon_buffer = rcon_buffer
    @rcon_client = rcon_client
    @game_pid = nil
    @monitor = nil
    @threads = {}
    @buffer[:persistent] = true
    @rcon_buffer[:persistent] = true
    @buffer[:filters] = [
      Proc.new { |line| line.gsub!(/\x1b\[[0-9;]*m/, '') } # Remove color codes
    ]
    @log_file = nil
    start_daemon
    log "Daemon initialized"
  end

  def log(message, exception=nil, level: :debug)
    super("Server [PID #{@game_pid} Game Port #{@config['server_game_port']}] #{@buffer[:uuid]} | #{message}", exception, level: level) # Call the log function created by logger
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

  def do_send_rcon(command, host: nil, port: nil, pass: nil, buffer: nil)
    host ||= @rcon_ip
    port ||= @active_rcon_port || @config['server_rcon_port']
    port ||= @active_rcon_pass
    pass ||= @active_rcon_pass || @config['server_rcon_password']
    buffer ||= @rcon_buffer
    log "Calling RCON client for command: #{command}"
    @rcon_client.send(host, port, pass, command, buffer: buffer)
  end

  def do_start_server
    @daemons_mutex.synchronize do
      if server_running? || (@threads[:game_server] && @threads[:game_server].alive?)
        "Server is already running. PID: #{@game_pid}"
      else
        log "Starting server", level: :info
        @threads[:game_server] = get_game_server_thread
        sleep 0.1 until @game_pid && @log_file
        "Server is starting. PID: #{@game_pid}"
      end
    end
  end

  def do_restart_server
    log "Restarting server", level: :info
    server_running? ? kill_server_process : do_start_server
    "Server restarting."
  end

  def do_stop_server
    log "Stopping server", level: :info
    return 'Server not running.' unless server_running?
    # No need to do anything besides remove it from monitoring
    # We want the signal to be sent to the thread's subprocess
    # so that the thread has time to set the status/message in the buffer
    thread = @threads.delete(:game_server)
    kill_server_process
  end

  def kill_server_process(signal: nil)
    signal = 'KILL' if signal.nil? # TERM can hang shutting down EAC. KILL doesn't, but might not disconnect players (instead they time out).
    return "Unable to send #{signal} (#{Signal.list[signal]}) signal to server; no known PID!" unless @game_pid
    message = "Sent #{signal} (#{Signal.list[signal]}) signal to PID #{@game_pid}."
    Process.kill(signal, @game_pid)
    log message, level: :info
    @game_pid = nil
    message
  end

  def run_game_server(executable=@config['server_executable'], arguments=$config_handler.get_server_arguments(@config))
    @buffer.reset
    @rcon_buffer.reset
    log "Applying config"
    $config_handler.apply_server_config_files @config, @config['server-config-name']
    @active_game_port = @config['server_game_port']
    @active_query_port = @config['server_query_port']
    @active_rcon_port = @config['server_rcon_port']
    @active_rcon_password = @config['server_rcon_password']
    log "Spawning game process: #{executable} #{arguments.join(' ')}", level: :info
    SubprocessRunner.run(
      [executable, *arguments],
      buffer: @buffer,
      pty: false,
      no_prefix: true,
      formatter: Proc.new { |output, _| WINDOWS ? "#{datetime} | #{output.chomp}" : output.chomp } # Windows doesn't have the timestamp, so we'll add our own to make it look nice.
    ) do |pid|
      @game_pid = pid
      Thread.new { @monitor = ServerMonitor.new('127.0.0.1', @active_query_port, @active_rcon_port, @active_rcon_password, name: @name, rcon_buffer: @rcon_buffer, interval: 5, delay: 10) }
      @rcon_tail_thread = Thread.new do
        last_modified_log_time = File.mtime(Dir[File.join(SERVER_LOG_DIR, '*.log')].sort_by{|f| File.mtime(f) }.last).to_i rescue 0
        other_used_logs = @daemons.map { |_, daemon| daemon.log_file }
        @rcon_buffer[:data] << "[PID: #{@game_pid} Game Port: #{@config['server_game_port']}] Waiting to detect log file in use"
        log "Waiting to detect log file in use"
        loop do
          updated_log = Dir[File.join(SERVER_LOG_DIR, '*.log')].reject { |f| f.include?('backup') || other_used_logs.include?(f) }.sort_by{ |f| File.mtime(f) }.last || File.join(SERVER_LOG_DIR, 'Insurgency.log')
          if File.mtime(updated_log).to_i > last_modified_log_time
            log "Found log file in use: #{updated_log.sub(USER_HOME, '~')}"
            @log_file = updated_log
            break
          end
          sleep 0.2
        end
        @rcon_buffer[:data] << "[PID: #{@game_pid} Game Port: #{@config['server_game_port']}] RCON log file detected: #{log_file.sub(USER_HOME, '~')}"
        begin
          File.open(@log_file) do |log|
            log.extend(File::Tail)
            log.interval = 1
            log.backward(0)
            last_line_was_rcon = false
            log.tail do |line|
              next if line.nil?
              if line.include? 'LogRcon'
                last_line_was_rcon = true
              elsif last_line_was_rcon
                if line =~ /^\[\d{4}\.\d{2}\.\d{2}-\d{2}\.\d{2}\.\d{2}:/
                  last_line_was_rcon = false
                  next
                end
              else
                next
              end
              @rcon_buffer[:data] << line.gsub(/\x1b\[[0-9;]*m/, '').chomp
            end
          end
        rescue => e
          log "Error in RCON tail thread (retrying)", e
          retry
        end
      ensure
        @rcon_buffer[:message] = "RCON log tailing complete."
        @rcon_buffer[:status] = true
      end
    end
    log 'Game process exited', level: :info
  ensure
    begin
      kill_server_process
    rescue Errno::ESRCH
    end
    @monitor.stop unless @monitor.nil?
    @monitor = nil
    @rcon_tail_thread.kill unless @rcon_tail_thread.nil?
    @rcon_tail_thread = nil
    @log_file = nil
    socket = @rcon_client.sockets["127.0.0.1:#{@active_rcon_port}"]
    @rcon_client.delete_socket(socket) unless socket.nil?
    $config_handler.apply_server_bans
  end

  def get_game_server_thread
    @game_pid = nil
    Thread.new do
      run_game_server
    rescue => e
      log "Game server failed", e
    end
  end

  def start_daemon(thread_check_interval: 1)
    @daemon_thread = Thread.new do
      while true
        while @threads.empty? || @threads.values.all?(&:alive?)
          sleep thread_check_interval
        end
        dead_threads = @threads.select { |_, t| !t.alive? }.keys
        log "Dead daemon thread(s) detected: #{dead_threads.join(' ')}"
        dead_threads.each do |key|
          log "Starting #{key} thread", level: :info
          @threads[key] = public_send("get_#{key.to_s}_thread")
        end
        sleep thread_check_interval
      end
    rescue => e
      log "Error in daemon's self-monitoring thread", e
      raise
    end
  end
end
