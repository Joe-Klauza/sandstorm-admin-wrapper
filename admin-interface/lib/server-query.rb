#!/usr/bin/env ruby

require 'socket'

# https://developer.valvesoftware.com/wiki/Server_queries
# https://apidock.com/ruby/Array/pack
# https://apidock.com/ruby/String/unpack

class NoUDPResponseError < StandardError
  def initialize(host=nil)
    super "Could not read a UDP response from server#{host ? " #{host}" : '!'}"
  end
end

class ServerQuery
  def self.send_recv_udp(packet, server_ip, server_port, socket_opts: 0, timeout: 2, retries: 1)
    s = UDPSocket.new
    s.send(packet, socket_opts, server_ip, server_port)
    resp, from = if IO.select([s], nil, nil, timeout)
      s.recvfrom(60000)
    end
    if resp.nil?
      if retries > 0
        s.close
        return send_recv_udp(packet, server_ip, server_port, socket_opts: socket_opts, timeout: timeout, retries: retries - 1)
      else
        raise NoUDPResponseError.new "#{server_ip}:#{server_port}"
      end
    end
    return resp, from
  ensure
    s.close
  end

  def self.a2s_info(server_ip, server_port = 27015)
    # https://developer.valvesoftware.com/wiki/Server_queries#A2S_INFO
    a2s_info_header = 0x54
    content = "Source Engine Query\0"
    packet = [0xFF, 0xFF, 0xFF, 0xFF, a2s_info_header, content].pack('c5Z*')

    resp, _ = send_recv_udp(packet, server_ip, server_port)
    data = resp.unpack('xxxxccZ*Z*Z*Z*s_cccZZccZ*xxxxxxxxxxxZ*')
    insurgency_info = data[15].split(',')

    {
      'header' => data[0],
      'protocol' => data[1],
      'name' => data[2],
      'map' => data[3],
      'folder' => data[4],
      'game' => data[5],
      'id' => data[6],
      'players' => data[7],
      'max_players' => data[8],
      'bots' => data[9],
      'type' => data[10],
      'environment' => data[11] == 'w' ? 'Windows' : (data[11] == 'l' ? 'Linux' : 'macOS'),
      'visibility' => data[12],
      'vac' => data[13],
      'insurgency_version' => data[14],
      'insurgency_netcl_version' => insurgency_info[0].split(':').last
    }
  rescue NoUDPResponseError => e
    log "[#{server_ip}:#{server_port}] Couldn't get UDP response (#{e.class} raised)", level: :warn
    raise
  rescue => e
    log "[#{server_ip}:#{server_port}] Rescued error while querying info", e, level: :warn
    raise
  end

  def self.a2s_player(server_ip, server_port = 27015)
    # https://developer.valvesoftware.com/wiki/Server_queries#A2S_PLAYER
    players = []
      packet = [0xFF, 0xFF, 0xFF, 0xFF, 0x55, -1].pack('cccccl_')
      resp, _ = send_recv_udp(packet, server_ip, server_port)
      if resp.unpack('xxxxcl').first == 65 # Challenge detected ('A' response); request again with given long
        packet = [0xFF, 0xFF, 0xFF, 0xFF, 0x55, resp.unpack('xxxxcl').last].pack('cccccl')
        resp, _ = send_recv_udp(packet, server_ip, server_port)
      end
      resp = resp[6..] # Remove padding, header, player count
      until resp.empty?
        begin
          pack_string = 'xZ*lf'
          player_data = resp.unpack(pack_string)
          resp = resp[player_data.pack(pack_string).length..] # Remove the read player info so we can iterate through the response (arbitrary length)
          player_info = {
            'name' => player_data[0].to_s.utf8.strip, # Can be empty
            'score' => player_data[1],
            'duration' => Time.at(player_data[2]).utc.strftime("%H:%M:%S"),
          }
          players << player_info
        rescue StandardError => e
          log "[#{server_ip}:#{server_port}] Rescued error while iterating players", e
          break
        end
      end
      players
  rescue NoUDPResponseError => e
    log "[#{server_ip}:#{server_port}] Couldn't get UDP response (#{e.class} raised)", level: :warn
    raise
  rescue => e
    log "[#{server_ip}:#{server_port}] Rescued error while querying players", e, level: :warn
    raise
  end

  def self.a2s_rules(server_ip, server_port = 27015)
    # https://developer.valvesoftware.com/wiki/Server_queries#A2S_RULES
    packet = [0xFF, 0xFF, 0xFF, 0xFF, 0x56, -1].pack('cccccl_')
    resp, _ = send_recv_udp(packet, server_ip, server_port)
    if resp.unpack('xxxxcl').first == 65 # Challenge detected ('A' response); request again with given long
      packet = [0xFF, 0xFF, 0xFF, 0xFF, 0x56, resp.unpack('xxxxcl').last].pack('cccccl')
      resp, _ = send_recv_udp(packet, server_ip, server_port)
    end
    data = resp.unpack('xxxxxxxZ*Z*Z*Z*Z*Z*Z*Z*Z*Z*Z*Z*Z*Z*Z*Z*Z*Z*Z*Z*')
    rules = data.each_slice(2).to_h
    raise "Unable to parse rules from response: #{resp.inspect}" unless rules.length == 10
    # {
    #   "Arcade_b"=>"false", # For frenzy this incorrectly reports as false until a player joins
    #   "Coop_b"=>"true", # For Frenzy this incorrectly reports as false after a player joins
    #   "GameMode_s"=>"HardcoreCheckpoint", # For Frenzy this incorrectly reports as Checkpoint until a player joins
    #   "MatchServer_b"=>"false",
    #   "OfficialRuleset_b"=>"false",
    #   "PlrC_i"=>"0",
    #   "PlrM_i"=>"8",
    #   "Pwd_b"=>"false",
    #   "S"=>"523",
    #   "Versus_b"=>"false"
    # }
    rules
  rescue NoUDPResponseError => e
    log "[#{server_ip}:#{server_port}] Couldn't get UDP response (#{e.class} raised)", level: :warn
    raise
  rescue => e
    log "[#{server_ip}:#{server_port}] Rescued error while querying rules: #{resp.inspect}", e, level: :warn
    raise
  end
end
