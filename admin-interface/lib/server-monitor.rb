require 'benchmark'
require 'geocoder'
require_relative 'logger'
require_relative 'rcon-client'
require_relative 'server-query'
require_relative 'steam-api-client'

Geocoder.configure(ip_lookup: :ipapi_com) # :ipinfo_io (default, 1,000/day) :ipapi_com (150/min) #:geoip2 (no actual lookup; not reliable)

class ServerMonitor
  attr_reader :info
  attr_reader :name
  attr_reader :ip
  attr_reader :query_port
  attr_reader :rcon_port
  attr_reader :rcon_pass
  attr_reader :rcon_buffer

  def initialize(ip, query_port, rcon_port, rcon_pass, interval: 15.0, delay: 5, rcon_fail_limit: 60, query_fail_limit: 30, name: '', rcon_buffer: nil, daemon_handle: nil, welcome_message_delay: 20)
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
    @steam_api_client = SteamApiClient.new(@daemon_handle.steam_api_key) unless @daemon_handle.nil? || @daemon_handle.steam_api_key.to_s.empty?

    @rcon_client = RconClient.new
    @info = {
      a2s_connection_problem: true,
      rcon_connection_problem: true,
      server_down: true,
      rcon_players: [],
      rcon_bots: nil,
      rcon_last_success: Time.now.to_i,
      a2s_info: nil,
      a2s_player: nil,
      a2s_rules: nil,
      a2s_last_success: Time.now.to_i
    }
    @welcome_message_delay = welcome_message_delay
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

  def steam_duration_to_seconds(duration)
    duration.split(':').map { |a| a.to_i }.inject(0) do |total, current|
      total * 60 + current # Convert hours to minutes, add minutes, convert minutes to seconds, add seconds
    end
  end

  def seconds_to_steam_duration(seconds)
    hours = seconds / (60 * 60)
    minutes = (seconds / 60) % 60
    seconds = seconds % 60
    "%02d:%02d:%02d" % [hours, minutes, seconds]
  end

  def time_ago(timestamp)
    delta = Time.now.utc.to_i - timestamp.to_i
    value, unit = case delta
    when -1..45           then [nil, 'just now']
    when 46..60           then [nil, 'about a minute ago']
    when 61..3599         then [(delta / 60).round, 'minute']
    when 3600..86399      then [(delta / 3600.0), 'hour']
    when 86400..31535999  then [(delta / 86400.0), 'day']
    else [(delta / 31536000.0), 'year']
    end
    if value.nil?
      unit
    else
      if unit == 'minute'
        "%d minute#{'s' if value > 1} ago" % value
      else
        "%.1f #{unit}#{'s' if ("%.1f" % value).to_f >= 1.1} ago" % value
      end
    end
  end

  def process_rcon_players(rcon_players, prev_rcon_players)
    return if [rcon_players, prev_rcon_players].any?(&:nil?)
    players_gone = prev_rcon_players.reject { |prev| rcon_players.map { |current| current['steam_id'] }.include?(prev['steam_id']) }
    players_joined = rcon_players.reject { |current| prev_rcon_players.map { |prev| prev['steam_id'] }.include?(current['steam_id']) }

    now = Time.now.to_i
    # Look up players we haven't in the past 24 hours
    if @daemon_handle && (@steam_api_client || !@daemon_handle.steam_api_key.empty?)
      @steam_api_client = SteamApiClient.new(@daemon_handle.steam_api_key) if @steam_api_client.nil?
      ids_to_query = rcon_players.select { |p| now - $config_handler.players.dig(p['steam_id'], 'last_steam_lookup').to_i > 60 * 60 * 24 }.map { |p| p['steam_id'] }
      steam_users = @steam_api_client.get_info(ids_to_query)
      steam_bans = @steam_api_client.get_bans(ids_to_query)
      steam_users.each do |user|
        next unless user['steamid']
        # Add their Steam data to the RCON player to merge into all players later
        matching_player = rcon_players.select { |player| player['steam_id'] == user['steamid'] }.first
        matching_player['steam_info'] = {
          'steamid' => user['steamid'],
          'name' => user['personaname'] || '',
          'created' => user['timecreated'].to_s || '',
          'avatar' => user['avatar'] || '',
          'avatar_medium' => user['avatarmedium'] || '',
          'avatar_full' => user['avatarfull'] || '',
          'persona_state' => user['personastate'] || '',
          'primary_clan_id' => user['primaryclanid'] || '',
          'community_visibility_state' => user['communityvisibilitystate'] || '',
          'last_logoff' => user['lastlogoff'] || '',
          'comment_permission' => user['commentpermission'] || '',
          'profile_url' => user['profileurl'] || '',
          'persona_state_flags' => user['personastateflags'] || '',
          'game_server_ip' => user['gameserverip'] || '',
          'game_server_steam_id' => user['gameserversteamid'] || '',
          'game_extra_info' => user['gameextrainfo'] || '',
          'game_id' => user['gameid'] || ''
        }
        ban_info = steam_bans.select { |u| u['SteamId'] == user['steamid'] }.first
        matching_player['steam_info']['bans'] = {
          'community' => ban_info['CommunityBanned'], # Bool
          'vac' => ban_info['VACBanned'], # Bool
          'vac_number' => ban_info['NumberOfVACBans'].to_s,
          'days_since_last' => ban_info['DaysSinceLastBan'].to_s,
          'game_number' => ban_info['NumberOfGameBans'].to_s,
          'economy' => ban_info['EconomyBan'] # String
        }
        matching_player['last_steam_lookup'] = now
      end
    end

    # Welcome joined players
    players_joined.each do |player|
      if @daemon_handle
        is_admin = @daemon_handle.is_sandstorm_admin?(player['steam_id'])
        message_option = is_admin ? 'admin_join_message' : 'join_message'
        unless @daemon_handle.config[message_option].empty?
          Thread.new(message_option) do |message_option|
            message = @daemon_handle.config[message_option]
            message = message.gsub('${player_name}', player.dig('steam_info', 'name') || player['name']).gsub('${player_id}', player['steam_id'] || 'NULL')
            sleep @welcome_message_delay # Allow time to select a loadout and see the chat
            @rcon_client.send(@ip, @rcon_port, @rcon_pass, "say #{message}")
          end
        end
        log "Player joined: #{player['name']} (#{player['steam_id']})#{' (admin)' if is_admin}", level: :info
      else
        log "Player joined: #{player['name']} (#{player['steam_id']})", level: :info
      end
    end

    players_needing_ip_query = rcon_players.select do |p|
      now - $config_handler.players.dig(p['steam_id'], 'last_ip_lookup', p['ip']).to_i > 60 * 60 * 24
    end
    players_needing_ip_query.each do |player|
      if LOCAL_IP_PREFIXES.any?{ |prefix| player['ip'].start_with?(prefix) }
        # The user is likely within the same network as the server, so use the external IP
        if @daemon_handle
          # Local server external IP
          ip = EXTERNAL_IP
        else
          # Remote monitor external IP
          ip = @ip.dup
        end
        next if ip.empty?
      else
        ip = player['ip']
      end
      begin
        log "Looking up IP #{ip} for player #{player['name']} (#{player['steam_id']})"
        ip_info = Geocoder.search(ip).first || Geocoder.search(ip).first # Often fails on the first try with "Geocoding API's response was not valid JSON"
        if ip_info.nil? || !ip_info.respond_to?(:data)
          log "Couldn't find IP info for #{ip} for player #{player['name']} (#{player['steam_id']})"
          next
        end
        ip_info = ip_info.data
        log "Got info about IP #{ip} for player #{player['name']} (#{player['steam_id']}): #{ip_info}"
        $config_handler.players[player['steam_id']]['last_ip_lookup'] = {} if $config_handler.players[player['steam_id']]['last_ip_lookup'].nil?
        $config_handler.players[player['steam_id']]['ip_info'] = {} if $config_handler.players[player['steam_id']]['ip_info'].nil?
        $config_handler.players[player['steam_id']]['last_ip_lookup'][player['ip']] = now
        $config_handler.players[player['steam_id']]['ip_info'][player['ip']] = ip_info
      rescue => e
        log "Failed to look up IP #{player['ip']} (#{player['steam_id']})"
      end
    end

    # Merge the current data
    rcon_players.map do |player|
      if $config_handler.players[player['steam_id']].nil?
        $config_handler.players[player['steam_id']] = player
      else
        $config_handler.players[player['steam_id']].merge!(player) # Merge the current data
        player.merge!($config_handler.players[player['steam_id']]) # Merge back the Steam info in case we don't have it
      end
      player
    end

    players_gone.each do |player|
      if @daemon_handle
        is_admin = @daemon_handle.is_sandstorm_admin?(player['steam_id'])
        message_option = is_admin ? 'admin_leave_message' : 'leave_message'
        log "Player left: #{player['name']} (#{player['steam_id']})#{' (admin)' if is_admin}", level: :info
        unless @daemon_handle.config[message_option].empty?
          Thread.new do
            message = @daemon_handle.config[message_option].gsub('${player_name}', player.dig('steam_info', 'name') || player['name']).gsub('${player_id}', player['steam_id'] || 'NULL')
            @rcon_client.send(@ip, @rcon_port, @rcon_pass, "say #{message}")
          end
        end
      end
      saved_player = $config_handler.players[player['steam_id']]
      score = player['score'].to_i
      saved_player['total_score'] = saved_player['total_score'].to_i + score
      saved_player['high_score'] = score if saved_player['high_score'].to_i <= score
      saved_player['last_seen'] = now
      saved_player['last_server'] = @info.dig(:a2s_info, 'name') || (@daemon_handle && @daemon_handle.name)
      begin
        matching_a2s_player = @info[:a2s_player].select { |p| p['name'] == player['name'] }.first
        if matching_a2s_player.nil? && @info[:a2s_player].map { |p| p['name'].empty? }.size == 1
          # Sometimes A2S_PLAYER has one or more blank player names for a while (bug)
          # If there's only one, we can assume that this is the player we're unable to match by name
          matching_a2s_player = @info[:a2s_player].map { |p| p['name'].empty? }.first
        end
        duration_steam = matching_a2s_player['duration'] rescue nil
        raise "Couldn't match by player name (#{player['name']}) to get duration. A2S_PLAYER: #{@info[:a2s_player]}" if duration_steam.nil?
        duration_seconds = steam_duration_to_seconds(duration_steam) + (@interval / 2.0).floor # Assume they left ~halfway between the last check and now
        saved_player['last_duration'] = seconds_to_steam_duration(duration_seconds)
        saved_player['longest_duration'] = seconds_to_steam_duration(duration_seconds) if saved_player['longest_duration'].to_i <= duration_seconds
        saved_player['total_duration'] = saved_player['total_duration'].to_i + duration_seconds
      rescue => e
        log "Failed to calculate duration_seconds for saved player info", e
      end
      saved_player['known_ips'] = saved_player['known_ips'].to_a.push(player['ip']).uniq
    end
  rescue => e
    log "Error occurred during RCON player processing", e
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
    if e.message.include?('Invalid gamestate')
      log "Skipping RCON listplayers parsing (map is changing)"
      return
    end
    log "RCON query failed", e
    @info[:rcon_connection_problem] = true
    rcon_fail_time = Time.now.to_i - @info[:rcon_last_success]
    log "Time since last RCON success: #{rcon_fail_time.to_s << 's'}", level: rcon_fail_time > @rcon_fail_limit ? :error : :warn
    if rcon_fail_time > @rcon_fail_limit
      @info[:server_down] = true
      if @daemon_handle && @daemon_handle.frozen_config['hang_recovery'].to_s.casecmp('true').zero?
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

    prev_map = @info.dig(:a2s_info, 'map')
    if a2s_info['map'] != prev_map
      log "Map changed: #{prev_map} => #{a2s_info['map']}", level: :info
    end

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
    if query_fail_time > @query_fail_limit
      @info[:server_down] = true
      if @daemon_handle && @daemon_handle.frozen_config['query_recovery'].to_s.casecmp('true').zero?
        Thread.new do
          log "Restarting server due to repeated Server Query failure", level: :warn
          response = @daemon_handle.do_restart_server
          log "Daemon response: #{response}"
        end
      end
    end
  end

  def stop
    @stop = true
    @rcon_buffer[:status] = true
    @rcon_buffer[:message] = "#{@host} Monitor stopped"
    @thread.kill if @thread.respond_to?('kill')
  end

  def all_green?
    # RCON and Query successfully reached
    !@info[:a2s_connection_problem] && !@info[:rcon_connection_problem]
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
