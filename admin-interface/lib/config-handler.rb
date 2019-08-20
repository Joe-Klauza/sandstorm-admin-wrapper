require 'bcrypt'
require 'erb'
require 'fileutils'
require 'inifile'
require 'oj'
require 'shellwords'
require 'socket'
require 'sysrandom'
require_relative 'logger'

CONFIG_PATH = File.expand_path File.join File.dirname(__FILE__), '..', 'config'
CONFIG_FILE = File.join CONFIG_PATH, 'config.json'
USERS_CONFIG_FILE = File.join CONFIG_PATH, 'users.json'
MONITOR_CONFIGS_FILE = File.join CONFIG_PATH, 'monitor-configs.json'
SERVER_CONFIGS_FILE = File.join CONFIG_PATH, 'server-configs.json'

WRAPPER_ROOT = File.expand_path(File.join(File.dirname(__FILE__), '..', '..')).freeze
WEBAPP_ROOT = File.join WRAPPER_ROOT, 'admin-interface'
WEBAPP_CONFIG = File.join(WRAPPER_ROOT, 'config', 'config.toml')
SERVER_ROOT = File.join WRAPPER_ROOT, 'sandstorm-server'
STEAMCMD_ROOT = File.join WRAPPER_ROOT, 'steamcmd'
STEAMCMD_EXE = File.join STEAMCMD_ROOT, 'installation', (WINDOWS ? "steamcmd.exe" : "steamcmd.sh")
STEAM_APPINFO_VDF = File.join STEAMCMD_ROOT, (WINDOWS ? "installation" : 'Steam'), 'appcache', 'appinfo.vdf'
USER_HOME = ENV['HOME']
ENV['HOME'] = STEAMCMD_ROOT # Steam will pollute the user directory otherwise on Linux.

BINARY = File.join SERVER_ROOT, 'Insurgency', 'Binaries', (WINDOWS ? 'Win64\InsurgencyServer-Win64-Shipping.exe' : 'Linux/InsurgencyServer-Linux-Shipping')
SERVER_LOG_DIR = File.join SERVER_ROOT, 'Insurgency', 'Saved', 'Logs'
RCON_LOG_FILE = File.join SERVER_LOG_DIR, 'Insurgency.log'
CONFIG_FILES_DIR = File.join WRAPPER_ROOT, 'server-config'
FileUtils.mkdir_p CONFIG_FILES_DIR
CONFIG_FILES = {
  game_ini: {
    type: :ini,
    actual: File.join(SERVER_ROOT, 'Insurgency', 'Saved', 'Config', (WINDOWS ? 'WindowsServer' : 'LinuxServer'), 'Game.ini'),
    local_erb: "<%=File.join(CONFIG_FILES_DIR, config_name.shellescape, 'Game.ini')%>"
  },
  engine_ini: {
    type: :ini,
    actual: File.join(SERVER_ROOT, 'Insurgency', 'Saved', 'Config', (WINDOWS ? 'WindowsServer' : 'LinuxServer'), 'Engine.ini'),
    local_erb: "<%=File.join(CONFIG_FILES_DIR, config_name.shellescape, 'Engine.ini')%>"
  },
  admins_txt: {
    type: :txt,
    actual: File.join(SERVER_ROOT, 'Insurgency', 'Config', 'Server', 'Admins.txt'),
    local_erb: "<%=File.join(CONFIG_FILES_DIR, config_name.shellescape, 'Admins.txt')%>"
  },
  mapcycle_txt: {
    type: :txt,
    actual: File.join(SERVER_ROOT, 'Insurgency', 'Config', 'Server', 'MapCycle.txt'),
    local_erb: "<%=File.join(CONFIG_FILES_DIR, config_name.shellescape, 'MapCycle.txt')%>"
  },
  bans_json: {
    type: :json,
    actual: File.join(SERVER_ROOT, 'Insurgency', 'Config', 'Server', 'Bans.json'),
    local_erb: "<%=File.join(CONFIG_FILES_DIR, config_name.shellescape, 'Bans.json')%>"
  }
}

MAPMAP = {
  'Canyon'    => 'Crossing',
  'Compound'  => 'Outskirts',
  'Farmhouse' => 'Farmhouse',
  'Ministry'  => 'Ministry',
  'Mountain'  => 'Summit',
  'Oilfield'  => 'Refinery',
  'Precinct'  => 'Precinct',
  'Town'      => 'Hideout'
}
MAPMAP_INVERTED = MAPMAP.invert
SIDES = [
  'Insurgents',
  'Security'
]
SCENARIO_MODES = [
  'Checkpoint',
  'Firefight',
  'Push',
  'Skirmish',
  'Team_Deathmatch'
]
GAME_MODES = [
  'Firefight',
  'Frontline',
  'Occupy',
  'Skirmish',
  'CaptureTheBase',
  'TeamDeathmatch',
  'Filming',
  'Mission',
  'Checkpoint',
  'CheckpointHardcore',
  'CheckpointTutorial',
  'Operations',
  'Outpost'
]
RULE_SETS = [
  'CheckpointFrenzy',
  'CompetitiveFirefight',
  'CompetitiveTheater',
  'MatchmakingCasual',
  'OfficialRules'
]

def self.valid_port?(port)
  port = port.to_i
  port >= 1 && port <= 65535
rescue
  false
end

CONFIG_VARIABLES = {
  'server-config-name' => {
    'default' => 'Default',
    'validation' => Proc.new { true }
  },
  'server_executable' => {
    'default' => BINARY,
    'validation' => Proc.new { |f| File.exist?(f) }
  },
  'server_default_map' => {
    'default' => MAPMAP.keys.sample,
    'random' => false,
    'validation' => Proc.new { |map| MAPMAP.keys.include?(map) || map == 'Random' },
    'type' => :map
  },
  'server_default_side' => {
    'default' => SIDES.sample,
    'random' => false,
    'validation' => Proc.new { |side| SIDES.include?(side) || side == 'Random' }
  },
  'server_max_players' => {
    'default' => '8',
    'type' => :argument,
    'validation' => Proc.new do |num|
        num.to_s =~ /\A\d+\Z/
      rescue
        false
      end
  },
  'server_max_players_override' => {
    'default' => '10',
    'type' => :engine_ini,
    'validation' => Proc.new do |num|
        num.to_s =~ /\A\d+\Z/
      rescue
        false
      end,
    'getter' => Proc.new { |engine_ini| engine_ini['SystemSettings']['net.MaxPlayersOverride'] },
    'setter' => Proc.new { |engine_ini, players| engine_ini['SystemSettings']['net.MaxPlayersOverride'] = players }
  },
  'server_game_mode' => {
    'default' => 'Checkpoint',
    'validation' => Proc.new { |mode| GAME_MODES.include? mode }
  },
  'server_scenario_mode' => {
    'default' => 'Checkpoint',
    'validation' => Proc.new { |mode| SCENARIO_MODES.include? mode }
  },
  'server_rule_set' => {
    'default' => 'None',
    'validation' => Proc.new { |rule_set| RULE_SETS.include?(rule_set) || rule_set = 'None' }
  },
  'server_cheats' => {
    'default' => 'false',
    'validation' => Proc.new { |cheats| ['true', 'false'].include? cheats }
  },
  'server_hostname' => {
    'default' => 'Sandstorm Admin Wrapper',
    'type' => :argument,
    'template' => '-hostname=<%= it %>',
    'validation' => Proc.new { true },
  },
  'server_password' => {
    'default' => '',
    'type' => :argument,
    'template' => '-password=<%= it %>',
    'validation' => Proc.new { true },
    'sensitive' => true
  },
  'server_game_port' => {
    'default' => '7777',
    'type' => :argument,
    'template' => '-Port=<%= it %>',
    'validation' => method('valid_port?'),
  },
  'server_query_port' => {
    'default' => '27131',
    'type' => :argument,
    'template' => '-QueryPort=<%= it %>',
    'validation' => method('valid_port?'),
  },
  'server_rcon_enabled' => {
    'default' => 'true',
    'type' => :game_ini,
    'getter' => Proc.new { |game_ini| game_ini['Rcon']['bEnabled'] },
    'setter' => Proc.new { |game_ini, bool| game_ini['Rcon']['bEnabled'] = bool.to_s.casecmp('true').zero? ? 'True' : 'False' },
    'validation' => Proc.new { true }
  },
  'server_rcon_allow_console_commands' => {
    'default' => 'true',
    'type' => :game_ini,
    'getter' => Proc.new { |game_ini| game_ini['Rcon']['bAllowConsoleCommands'] },
    'setter' => Proc.new { |game_ini, bool| game_ini['Rcon']['bAllowConsoleCommands'] = bool.to_s.casecmp('true').zero? ? 'True' : 'False' },
    'validation' => Proc.new { true },
  },
  'server_rcon_port' => {
    'default' => '27015',
    'type' => :game_ini,
    'getter' => Proc.new { |game_ini| game_ini['Rcon']['ListenPort'] },
    'setter' => Proc.new { |game_ini, port| game_ini['Rcon']['ListenPort'] = port },
    'validation' => method('valid_port?'),
  },
  'server_rcon_password' => {
    'default' => Sysrandom.base64(32),
    'type' => :game_ini,
    'getter' => Proc.new { |game_ini| game_ini['Rcon']['Password'] },
    'setter' => Proc.new { |game_ini, password| game_ini['Rcon']['Password'] = password },
    'validation' => Proc.new { true },
    'sensitive' => true
  },
  'server_gslt' => {
    'default' => '',
    'type' => :argument,
    'validation' => Proc.new { |token| token =~ /\A[ABCDEF0-9]+\Z/ || token.empty? },
    'sensitive' => true
  }
}


class ConfigHandler
  attr_accessor :config
  attr_reader :monitor_configs
  attr_reader :server_configs
  attr_reader :users

  def initialize
    @config = load_server_config
    @users = load_user_config
    @monitor_configs = load_monitor_configs
    @server_configs = load_server_configs
  end

  def get_default_config
    defaults = {}
    CONFIG_VARIABLES.each { |k, v| defaults[k] = v['default'] }
    defaults
  end

  def load_user_config
    @users = Oj.load(File.read(USERS_CONFIG_FILE))
    @users = {} if @users.to_s.empty?
    @users
  rescue Errno::ENOENT
    default_admin_user = User.new('admin', :host, password: BCrypt::Password.create('password').to_s, initial_password: 'password')
    {
      default_admin_user.id => default_admin_user
    }
  rescue => e
    log "Failed to load user config from #{USERS_CONFIG_FILE}. Using default user config.", e
    raise
  end

  def load_monitor_configs
    @monitor_configs = Oj.load(File.read(MONITOR_CONFIGS_FILE))
    @monitor_configs = {} if @monitor_configs.to_s.empty?
    @monitor_configs
  rescue Errno::ENOENT
    {}
  rescue => e
    log "Failed to load monitor configs from #{MONITOR_CONFIGS_FILE}. Using empty config.", e
    raise
  end

  def load_server_configs
    @server_configs = Oj.load(File.read(SERVER_CONFIGS_FILE))
    @server_configs = {'Default' => get_default_config} if @server_configs.nil? || @server_configs.empty?
    @server_configs
  rescue Errno::ENOENT
    {}
  rescue => e
    log "Failed to load server configs from #{SERVER_CONFIGS_FILE}. Using empty config.", e
    raise

  end

  def load_server_config(file_path=CONFIG_FILE)
    @config = Oj.load File.read(file_path)
    @config.merge! get_default_config.reject { |k, _| @config.keys.include? k }
    @config
  rescue Errno::ENOENT
    get_default_config
  rescue => e
    log "Failed to load config from #{file_path}. Using default config.", e
    raise
  end

  def write_user_config
    log "Writing user config"
    File.write(USERS_CONFIG_FILE, Oj.dump(@users))
  end

  def write_monitor_configs
    log "Writing monitor configs"
    File.write(MONITOR_CONFIGS_FILE, Oj.dump(@monitor_configs))
  end

  def write_server_configs(config_name=nil)
    if config_name
      log "Writing #{config_name} server config"
      FileUtils.mkdir_p(File.join(CONFIG_FILES_DIR, config_name.shellescape))
    end
    log "Writing server configs"
    File.write(SERVER_CONFIGS_FILE, Oj.dump(@server_configs))
  end

  def write_current_config(config=@config, file_path=CONFIG_FILE)
    log "Writing current config"
    File.write(file_path + '.tmp', Oj.dump(config))
    FileUtils.mv(file_path, file_path + '.bak') if File.exist? file_path
    FileUtils.mv(file_path + '.tmp', file_path)
  end

  def write_config
    write_user_config
    write_monitor_configs
    write_server_configs
    write_current_config
    true
  rescue => e
    log 'Failed to write config', e
    false
  end

  def init_server_config_files(config_name=nil)
    CONFIG_FILES.values.each do |it|
      FileUtils.mkdir_p File.dirname(it[:actual])
      FileUtils.touch it[:actual]
      if config_name.nil?
        @server_configs.each do |config_name, _|
          path = ERB.new(it[:local_erb]).result(binding)
          FileUtils.mkdir_p File.dirname path
          FileUtils.touch path
        end
      else
        path = ERB.new(it[:local_erb]).result(binding)
        FileUtils.mkdir_p File.dirname path
        FileUtils.touch path
      end
    end
  end

  def apply_server_config_files(config, config_name)
    # Apply values in case any in memory aren't in the file
    apply_game_ini_local config, config_name
    apply_engine_ini_local config, config_name

    CONFIG_FILES.values.each do |it|
      local = ERB.new(it[:local_erb]).result(binding) # relies on config_name
      log "Applying #{local} -> #{it[:actual]}"
      FileUtils.cp local, it[:actual]
    end
    nil
  end

  def apply_server_bans(config_name)
    server_bans = Oj.load(File.read CONFIG_FILES[:bans_json][:actual]) || []
    previous_bans = Oj.load(File.read ERB.new(CONFIG_FILES[:bans_json][:local_erb]).result(binding)) || [] # ERB relies on config_name
    return if server_bans == previous_bans
    log "Applying new player bans"
    server_bans.concat(previous_bans).uniq! { |ban| ban['playerId'] }
    File.write(ERB.new(CONFIG_FILES[:bans_json][:local_erb]).result(binding), Oj.dump(server_bans))
  end

  def set(config_name, variable, value)
    return [false, "Variable not in config: #{variable}"] unless CONFIG_VARIABLES.keys.include? variable
    return [false, "Variable has no validation: #{variable}"] unless CONFIG_VARIABLES[variable]['validation'].respond_to?('call')
    @config = (@server_configs[config_name] = get_default_config.merge(@server_configs[config_name] || {}))
    old_value = @server_configs[config_name][variable] rescue @config[variable]
    return [false, "Variable #{variable} is already set to #{CONFIG_VARIABLES[variable]['sensitive'] ? '[REDACTED]' : value}."] if value.to_s == old_value.to_s
    status = false
    msg = "Failed to set #{variable.inspect} to #{CONFIG_VARIABLES[variable]['sensitive'] ? '[REDACTED]' : value.inspect}"
    old_value = old_value || CONFIG_VARIABLES[variable]['default'] || 'Unknown'

    if CONFIG_VARIABLES[variable]['validation'].call(value)
      log "Value passed validation: #{CONFIG_VARIABLES[variable]['sensitive'] ? '[REDACTED]' : value.inspect}"
      @config[variable] = value
      write_current_config
      write_server_configs(config_name)
      apply_game_ini_local(@server_configs[config_name], config_name) if CONFIG_VARIABLES[variable]['type'] == :game_ini
      apply_engine_ini_local(@server_configs[config_name], config_name) if CONFIG_VARIABLES[variable]['type'] == :engine_ini
      status = true
    else
      msg = "Value failed validation for variable #{variable.inspect}: #{CONFIG_VARIABLES[variable]['sensitive'] ? '[REDACTED]' : value.inspect}"
      log msg, level: :warn
    end

    return [status, msg, CONFIG_VARIABLES[variable]['sensitive'] ? '[REDACTED]' : @config[variable], CONFIG_VARIABLES[variable]['sensitive'] ? '[REDACTED]' : old_value]
  end

  def get(config_name, variable)
    if config_name
      @server_configs[config_name][variable]
    else
      @config[variable]
    end
  end

  def get_scenario(map, mode, side)
    filtered_map = MAPMAP[map]
    "Scenario_#{filtered_map}_#{mode}_#{side}"
  end

  def get_query_string(config, map: nil, side:nil, game_mode: nil, scenario_mode: nil, max_players: nil, password: nil)
    map = config['server_default_map'] == 'Random' ? MAPMAP.keys.sample : config['server_default_map'] if map.nil?
    side = config['server_default_side'] == 'Random' ? SIDES.sample : config['server_default_side'] if side.nil?
    game_mode = config['server_game_mode'] == 'Random' ? GAME_MODES.sample : config['server_game_mode'] if game_mode.nil?
    scenario_mode = config['server_scenario_mode'] == 'Random' ? SCENARIO_MODES.sample : config['server_scenario_mode'] if scenario_mode.nil?
    max_players ||= config['server_max_players']
    password ||= config['server_password']
    scenario = get_scenario(map, scenario_mode, side)
    query = "#{map}?Scenario=#{scenario}?MaxPlayers=#{max_players}?Game=#{game_mode}"
    query << "?Password=#{password}" unless password.empty?
    query
  end

  def get_server_arguments(config)
    arguments = []
    arguments.push(
      get_query_string(config),
      "-Hostname=#{config['server_hostname']}",
      "-MaxPlayers=#{config['server_max_players']}",
      "-Port=#{config['server_game_port']}",
      "-QueryPort=#{config['server_query_port']}",
      "-log",
      "-AdminList=Admins",
      "-MapCycle=MapCycle"
    )
    arguments.push("-ruleset=#{config['server_rule_set']}") unless config['server_rule_set'] == 'None'
    if config['server_gslt'].to_s.empty?
      arguments.push("-EnableCheats") if config['server_cheats'].to_s.casecmp('true').zero?
    else
      arguments.push("-GameStats", "-GSLTToken=#{config['server_gslt']}")
    end
    arguments
  end

  def apply_game_ini_local(config, config_name)
    apply_ini(config, ERB.new(CONFIG_FILES[:game_ini][:local_erb]).result(binding))
  end

  def apply_engine_ini_local(config, config_name)
    apply_ini(config, ERB.new(CONFIG_FILES[:engine_ini][:local_erb]).result(binding))
  end

  # def update_ini(source, dest)
  #   log "Updating ini #{source} -> #{dest}"
  #   source_ini = IniFile.load(source)
  #   dest_ini = IniFile.load(dest)
  #   source_ini.each_section do |section|
  #     source_ini[section].each do |variable, value|
  #       log "Setting [#{section}][#{variable}] = #{value}"
  #       dest_ini[section][variable] = value
  #     end
  #   end
  # rescue => e
  #   log "Error while updating ini", e
  #   raise
  # end

  def apply_ini(config, path)
    type = File.basename(path).downcase.sub('.', '_').to_sym
    log "Applying #{type} values to #{path}"
    ini = IniFile.load(path)
    changed = false
    CONFIG_VARIABLES.select { |_, metadata| metadata['type'] == type }.each do |option, metadata|
      next if (metadata['getter'].call(ini).to_s) == config[option].to_s
      changed = true
      log "Applying #{option}"
      metadata['setter'].call(ini, config[option])
    end
    if changed
      log "Saving #{type}"
      ini.save
    else
      log "No #{type} changes"
    end
  rescue => e
    log "Error while applying #{type} settings", e
    raise
  end
end
