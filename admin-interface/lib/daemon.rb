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
  attr_reader :buffer
  attr_reader :rcon_buffer
  attr_reader :rcon_client
  attr_reader :server_updater
  attr_reader :game_pid
  attr_reader :threads
  attr_reader :monitor

  def initialize(executable, server_root_dir, steamcmd_path, steam_appinfovdf_path, server_buffer, rcon_buffer)
    @executable = executable
    @server_root_dir = server_root_dir
    @rcon_ip = '127.0.0.1'
    @buffer = server_buffer
    @rcon_buffer = rcon_buffer
    @rcon_client = RconClient.new
    @server_updater = ServerUpdater.new(server_root_dir, steamcmd_path, steam_appinfovdf_path)
    @game_pid = nil
    @monitor = nil
    @threads = {}
    @config = $config_handler.config
    @buffer[:persistent] = true
    @rcon_buffer[:persistent] = true
    @buffer[:filters] = [
      Proc.new { |line| line.gsub!(/\x1b\[[0-9;]*m/, '') } # Remove color codes
    ]
    start_daemon
    log "Daemon initialized"
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

  def server_installed?
    File.exist? @executable
  end

  def updates_running?
    @threads[:game_update] && @threads[:game_update].alive?
  end

  def do_update_server(buffer=nil, validate: nil)
    was_running = server_running?
    if WINDOWS && was_running
      do_pre_update_warning
      do_stop_server
    end
    success, message = @server_updater.update_server(buffer, validate: validate)
    @update_pending = false if success
    WINDOWS ? do_start_server : (do_pre_update_warning; do_restart_server) if was_running
    message
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

  def do_run_steamcmd(command, buffer: nil)
    @server_updater.run_steamcmd(command, buffer: buffer)
  end

  def do_send_rcon(command, host: @rcon_ip, port: @active_rcon_port || @config['server_rcon_port'], pass: (@active_rcon_pass || @config['server_rcon_password']), buffer: nil)
    log "Calling RCON client for command: #{command}"
    @rcon_client.send(host, port, pass, command, buffer: buffer)
  end

  def do_start_updates
    if updates_running?
      "Server is already running. PID: #{@game_pid}"
    else
      log "Starting server", level: :info
      @threads[:game_update] = get_game_server_thread
      sleep 0.1 until @game_pid
      "Server is starting. PID: #{@game_pid}"
    end
  end

  def do_stop_updates
    log "Stopping updates", level: :info
    @threads.delete(:game_update).kill
    "Automated updates stopped."
  end

  def do_install_server(buffer=nil, validate: nil)
    log "Installing server..."
    @server_updater.update_server(buffer, validate: validate)
  end

  def do_start_server
    if server_running? || (@threads[:game_server] && @threads[:game_server].alive?)
      "Server is already running. PID: #{@game_pid}"
    else
      log "Starting server", level: :info
      @threads[:game_server] = get_game_server_thread
      sleep 0.1 until @game_pid
      "Server is starting. PID: #{@game_pid}"
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
    signal = 'KILL' if signal.nil?
    return "Unable to send #{signal} (#{Signal.list[signal]}) signal to server; no known PID!" unless @game_pid
    message = "Sent #{signal} (#{Signal.list[signal]}) signal to PID #{@game_pid}."
    Process.kill(signal, @game_pid)
    log message, level: :info
    @game_pid = nil
    message
  end

  def run_game_server(executable=@executable, arguments=$config_handler.get_server_arguments)
    log "Applying config"
    $config_handler.apply_server_config_files
    @active_game_port = @config['server_game_port']
    @active_query_port = @config['server_query_port']
    @active_rcon_port = @config['server_rcon_port']
    @active_rcon_password = @config['server_rcon_password']
    log "Spawning game process: #{executable} #{arguments.join(' ')}", level: :info
    SubprocessRunner.run(
      [executable, *arguments],
      buffer: @buffer,
      pty: false,
      no_prefix: true
    ) do |pid|
      @game_pid = pid
      Thread.new { @monitor = ServerMonitor.new('127.0.0.1', @active_query_port, @active_rcon_port, @active_rcon_password, delay: 10) }
      @rcon_tail_thread = Thread.new do
        begin
          File.open(RCON_LOG_FILE) do |log|
            log.extend(File::Tail)
            log.interval = 1
            log.backward(0)
            log.tail do |line|
              next if line.nil?
              if line.include? 'LogRcon'
                @last_line_was_rcon = true
              elsif @last_line_was_rcon
                if line =~ /^\[\d{4}\.\d{2}\.\d{2}-\d{2}\.\d{2}\.\d{2}:/
                  @last_line_was_rcon = false
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
      end
    end
    waitpid @game_pid
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
    socket = @rcon_client.sockets["127.0.0.1:#{@active_rcon_port}"]
    @rcon_client.delete_socket(socket) unless socket.nil?
  end

  def get_game_server_thread
    @game_pid = nil
    Thread.new do
      run_game_server
    rescue => e
      log "Game server failed", e
    end
  end

  def get_game_update_thread
    Thread.new do
      begin
        @server_updater.monitor_update do
          @update_pending = true
          do_update_server if $config['server_automatic_updates_enabled'].to_s.casecmp('true').zero?
        end
      rescue => e
        log "Game update thread failed", e
      end
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
