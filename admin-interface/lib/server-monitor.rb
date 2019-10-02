require 'benchmark'
require_relative 'logger'
require_relative 'rcon-client'
require_relative 'server-query'

class ServerMonitor
  attr_reader :info
  attr_reader :name
  attr_reader :ip
  attr_reader :query_port
  attr_reader :rcon_port
  attr_reader :rcon_pass
  attr_reader :rcon_buffer

  def initialize(ip, query_port, rcon_port, rcon_pass, interval: 15.0, delay: 0, rcon_fail_limit: 30, query_fail_limit: 30, name: '', rcon_buffer: nil, daemon_handle: nil)
    @stop = false
    @ip = ip
    @query_port = query_port
    @rcon_port = rcon_port
    @rcon_pass = rcon_pass
    @interval = interval
    @rcon_fail_limit = rcon_fail_limit
    @query_fail_limit = query_fail_limit
    @name = name
    @rcon_buffer = rcon_buffer
    @rcon_buffer[:persistent] = true
    @daemon_handle = daemon_handle

    @rcon_client = RconClient.new
    @info = {
      a2s_connection_problem: true,
      rcon_connection_problem: true,
      server_down: true,
      rcon_players: nil,
      rcon_bots: nil,
      rcon_last_success: Time.now.to_i,
      a2s_info: nil,
      a2s_player: nil,
      a2s_rules: nil,
      a2s_last_success: Time.now.to_i
    }
    @player_log = []
    @host = "#{ip}:[#{query_port},#{rcon_port}]"
    @thread = Thread.new do
      if delay > 0
        log "Waiting #{delay} seconds to monitor"
        sleep delay
      end
      @thread = monitor unless @stop
    end
    log "Initialized monitor"
  end

  def [](thing)
    @info[thing]
  end

  def log(message, exception=nil, level: nil)
    super("#{@host} Monitor | #{message}", exception, level: level) # Call the log function created by logger
  end

  def get_uptime(original_start, now=Time.now.to_i)
    seconds_lapsed = now - original_start
    uptime = ''
    hours = seconds_lapsed / (60 * 60)
    minutes = (seconds_lapsed / 60) % 60
    seconds = seconds_lapsed % 60
    uptime << ("%d hours " % hours) if hours > 0
    uptime << ("%d minutes " % minutes) if hours > 0 || minutes > 0
    uptime << ("%d seconds" % seconds)
    uptime
  end

  def process_rcon_players(rcon_players, prev_rcon_players)
    "TODO"
  end

  def do_rcon_query
    rcon_players, rcon_bots = @rcon_client.get_players_and_bots(@ip, @rcon_port, @rcon_pass, buffer: @rcon_buffer, ignore_status: true, ignore_message: true)
    process_rcon_players(rcon_players, @info[:rcon_players])
    log "Got RCON players: #{rcon_players}"
    @info.merge!({
      rcon_connection_problem: false,
      server_down: false,
      rcon_players: rcon_players,
      rcon_bots: rcon_bots,
      rcon_last_success: Time.now.to_i
    })
  rescue => e
    log "RCON query failed", e
    @info[:rcon_connection_problem] = true
    rcon_fail_time = Time.now.to_i - @info[:rcon_last_success]
    log "Time since last RCON success: #{rcon_fail_time.to_s << 's'}", level: rcon_fail_time > @rcon_fail_limit ? :error : :warn
    if rcon_fail_time > @rcon_fail_limit
      @info[:server_down] = true
      if @daemon_handle.frozen_config['hang_recovery'].casecmp('true').zero?
        Thread.new do
          log "Restarting server due to repeated RCON failure", level: :warn
          response = @daemon_handle.do_restart_server
          log "Daemon response: #{response}"
        end
      end
    end
  end

  def do_server_query
    a2s_info = ServerQuery::a2s_info(@ip, @query_port)
    log "Got A2S_INFO: #{a2s_info}"
    a2s_player = ServerQuery::a2s_player(@ip, @query_port)
    log "Got A2S_PLAYER: #{a2s_player}"
    a2s_rules = ServerQuery::a2s_rules(@ip, @query_port)
    log "Got A2S_RULES: #{a2s_rules}"
    # Sometimes the server can be in a zombie state where server query succeeds
    # but nothing else works (including RCON); i.e. we shouldn't set server_down: false
    # based on a successful server query response if RCON is reporting as working (but
    # failure is more often indicative of an issue than RCON, which is more buggy)
    @info.merge!({
      a2s_connection_problem: false,
      a2s_info: a2s_info,
      a2s_player: a2s_player,
      a2s_rules: a2s_rules,
      a2s_last_success: Time.now.to_i
    })
    @info[:server_down] = @info[:rcon_connection_problem]
  rescue => e
    log "Server query failed", e
    @info[:a2s_connection_problem] = true
    query_fail_time = Time.now.to_i - @info[:a2s_last_success]
    log "Time since last server query success: #{query_fail_time.to_s << 's'}", level: query_fail_time > @query_fail_limit ? :error : :warn
    @info[:server_down] ||= (query_fail_time > @query_fail_limit) && @info[:rcon_connection_problem]
  end

  def stop
    @stop = true
    @rcon_buffer[:status] = true
    @rcon_buffer[:message] = "#{@host} Monitor stopped"
    @thread.kill if @thread.respond_to?('kill')
  end

  def monitor
    return nil if @stop
    Thread.new do
      @rcon_buffer.reset
      original_start = Time.now.to_i
      loop do
        lapsed = Benchmark.realtime do
          begin
            start = Time.now.to_i
            log "Retrieving RCON players"
            time_taken = Benchmark.realtime { do_rcon_query }
            log "Took #{"%.3f" % time_taken}s (Retrieving RCON players)"
            log "Retrieving Server Query info, players, and rules"
            time_taken = Benchmark.realtime { do_server_query }
            log "Took #{"%.3f" % time_taken}s (Retrieving Server Query info, players, and rules)"
          rescue => e
            log "error during monitoring!", e
            break
          end
        end
        log "Uptime: #{get_uptime(original_start)}"
        sleep_seconds = [@interval - lapsed, 0.0].max # Ensure we don't try to sleep with a negative value
        log "Server monitoring took #{"%.1f" % lapsed}s. Sleeping #{"%.1f" % sleep_seconds}s."
        sleep sleep_seconds
        if @stop
          log "Stopping monitor"
          next
        end
      end
    rescue => e
      log "Error while monitoring", e
    ensure
      log "Monitoring stopped."
    end
  end
end
