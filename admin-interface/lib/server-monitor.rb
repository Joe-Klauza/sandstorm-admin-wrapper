require 'benchmark'
require_relative 'logger'
require_relative 'rcon-client'
require_relative 'server-query'

class ServerMonitor
  attr_reader :info

  def initialize(ip, query_port, rcon_port, rcon_pass, interval: 15.0, delay: 0)
    @ip = ip
    @query_port = query_port
    @rcon_port = rcon_port
    @rcon_pass = rcon_pass
    @interval = interval

    @rcon_client = RconClient.new
    @info = {
      rcon_players: nil,
      rcon_bots: nil,
      rcon_last_success: nil,
      a2s_info: nil,
      a2s_player: nil,
      a2s_rules: nil,
      a2s_last_success: nil
    }
    @host = "#{ip}:[#{query_port},#{rcon_port}]"

    if delay > 0
      log "#{@host} Waiting #{delay} seconds to monitor"
      sleep delay
    end
    @thread = monitor
    log "#{@host} Initialized monitor"
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

  def do_rcon_query
    rcon_players, rcon_bots = @rcon_client.get_players_and_bots(@ip, @rcon_port, @rcon_pass)
    log "#{@host} Got RCON players: #{rcon_players}"
    @info.merge!({
      rcon_players: rcon_players,
      rcon_bots: rcon_bots,
      rcon_last_success: Time.now.to_i
    })
  rescue => e
    log "#{@host} RCON query failed", e
    log "#{@host} Time since last RCON success: #{(Time.now.to_i - @info[:rcon_last_success]).to_s << 's' rescue 'Never'}", level: :warn
  end

  def do_server_query
    a2s_info = ServerQuery::a2s_info(@ip, @query_port)
    log "#{@host} Got A2S_INFO: #{a2s_info}"
    a2s_player = ServerQuery::a2s_player(@ip, @query_port)
    log "#{@host} Got A2S_PLAYER: #{a2s_player}"
    a2s_rules = ServerQuery::a2s_rules(@ip, @query_port)
    log "#{@host} Got A2S_RULES: #{a2s_rules}"
    @info.merge!({
      a2s_info: a2s_info,
      a2s_player: a2s_player,
      a2s_rules: a2s_rules,
      a2s_last_success: Time.now.to_i
    })
  rescue => e
    log "#{@host} Server query failed", e
    log "#{@host} Time since last server query success: #{(Time.now.to_i - @info[:a2s_last_success]).to_s << 's' rescue 'Never'}", level: :warn
  end

  def stop
    @thread.kill if @thread.respond_to?('kill')
  end

  def monitor
    Thread.new do
      original_start = Time.now.to_i
      loop do
        lapsed = Benchmark.realtime do
          begin
            start = Time.now.to_i
            log "#{@host} Retrieving RCON players"
            time_taken = Benchmark.realtime { do_rcon_query }
            log "#{@host} Took #{"%.3f" % time_taken}s (Retrieving RCON players)"
            log "#{@host} Retrieving Server Query info, players, and rules"
            time_taken = Benchmark.realtime { do_server_query }
            log "#{@host} Took #{"%.3f" % time_taken}s (Retrieving Server Query info, players, and rules)"
          rescue => e
            log "#{@host} error during monitoring!", e
            exit 1
          end
        end
        log "Uptime: #{get_uptime(original_start)}"
        sleep_seconds = [@interval - lapsed, 0.0].max # Ensure we don't try to sleep with a negative value
        log "#{@host} Server monitoring took #{"%.1f" % lapsed}s. Sleeping #{"%.1f" % sleep_seconds}s."
        sleep sleep_seconds
      end
    rescue => e
      log "#{@host} Error while monitoring", e
    ensure
      log "#{@host} Monitoring stopped."
    end
  end
end
