# encoding: UTF-8

require 'json'
require 'net/http'

class SteamApiClient

  def initialize(api_key, timeout: 4)
    @api_key = api_key
    @timeout = timeout
  end

  def call_api(uri, timeout: @timeout)
    uri = URI(uri)
    Net::HTTP.start(uri.host, uri.port, read_timeout: timeout, open_timeout: timeout) do |http|
      request = Net::HTTP::Get.new uri
      http.request request
    end.body
  end

  def get(path, ids)
    if ids.empty?
      log "Skipping Steam check (no IDs provided)"
      return {}
    end
    log "Getting Steam #{path.include?('GetPlayerBans') ? 'bans' : 'info'} for IDs: #{ids.join(', ')}"
    raw_response = call_api "http://api.steampowered.com/#{path}?key=#{@api_key}&steamids=#{ids.join(',')}"
    JSON.parse raw_response
  rescue => e
    if e.is_a?(JSON::ParserError) && raw_response.include?('429 Too Many Requests')
      log "Failed to get ban information; too many Steam requests. (IDs: #{ids})", level: :warn
    else
      log "Failed to get ban information for ID(s) #{ids}: #{raw_response}", e
    end
    {}
  end

  def get_info(ids)
    path = "ISteamUser/GetPlayerSummaries/v0002/"
    get(path, ids).dig('response', 'players') || []
  end

  def get_bans(ids)
    path = "ISteamUser/GetPlayerBans/v1/"
    get(path, ids).dig('players') || []
  end

end
