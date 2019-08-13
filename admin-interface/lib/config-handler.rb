require 'bcrypt'
require 'erb'
require 'fileutils'
require 'inifile'
require 'oj'
require 'socket'
require 'sysrandom'
require_relative 'logger'

CONFIG_PATH = File.join File.dirname(__FILE__), '..', 'config'
CONFIG_FILE = File.join CONFIG_PATH, 'config.json'
USERS_CONFIG_FILE = File.join CONFIG_PATH, 'users.json'

WRAPPER_ROOT = File.expand_path(File.join(File.dirname(__FILE__), '..', '..')).freeze
WEBAPP_ROOT = File.join WRAPPER_ROOT, 'admin-interface'
SERVER_ROOT = File.join WRAPPER_ROOT, 'sandstorm-server'
STEAMCMD_ROOT = File.join WRAPPER_ROOT, 'steamcmd'
USER_HOME = ENV['HOME']
ENV['HOME'] = STEAMCMD_ROOT # Steam will pollute the user directory otherwise on Linux.

BINARY = File.join SERVER_ROOT, 'Insurgency', 'Binaries', (WINDOWS ? 'Win64\InsurgencyServer-Win64-Shipping.exe' : 'Linux/InsurgencyServer-Linux-Shipping')
RCON_LOG_FILE = File.join SERVER_ROOT, 'Insurgency', 'Saved', 'Logs', 'Insurgency.log'
CONFIG_FILES_DIR = File.join WRAPPER_ROOT, 'server-config'
FileUtils.mkdir_p CONFIG_FILES_DIR
CONFIG_FILES = {
  game_ini: {
    type: :ini,
    actual: File.join(SERVER_ROOT, 'Insurgency', 'Saved', 'Config', (WINDOWS ? 'WindowsServer' : 'LinuxServer'), 'Game.ini'),
    local: File.join(CONFIG_FILES_DIR, 'Game.ini')
  },
  engine_ini: {
    type: :ini,
    actual: File.join(SERVER_ROOT, 'Insurgency', 'Saved', 'Config', (WINDOWS ? 'WindowsServer' : 'LinuxServer'), 'Engine.ini'),
    local: File.join(CONFIG_FILES_DIR, 'Engine.ini')
  },
  admins_txt: {
    type: :txt,
    actual: File.join(SERVER_ROOT, 'Insurgency', 'Config', 'Server', 'Admins.txt'),
    local: File.join(CONFIG_FILES_DIR, 'Admins.txt')
  },
  mapcycle_txt: {
    type: :txt,
    actual: File.join(SERVER_ROOT, 'Insurgency', 'Config', 'Server', 'MapCycle.txt'),
    local: File.join(CONFIG_FILES_DIR, 'MapCycle.txt')
  },
  bans_json: {
    type: :json,
    actual: File.join(SERVER_ROOT, 'Insurgency', 'Config', 'Server', 'Bans.json'),
    local: File.join(CONFIG_FILES_DIR, 'Bans.json')
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
  },
  'server_automatic_updates_enabled' => {
    'default' => 'true',
    'type' => :daemon,
    'validation' => Proc.new { true }
  }
}


class ConfigHandler
  attr_reader :config
  attr_reader :users

  def initialize
    @config = load_server_config
    @users = load_user_config
  end

  def get_default_config
    defaults = {}
    CONFIG_VARIABLES.each { |k, v| defaults[k] = v['default'] }
    defaults
  end

  def load_user_config
    users = Oj.load File.read(USERS_CONFIG_FILE)
    users.each do |name, data|
      users[name] = User.new(name, data['role'], data[])
    end
  rescue
    log "Failed to load user config from #{USERS_CONFIG_FILE}. Using default user config. This is expected on first start.", level: :warn
    {
      # Set an initial password that will need to be changed on first login
      'admin' => User.new('admin', :host, password: BCrypt::Password.create('password').to_s, initial_password: 'password')
    }
  end

  def load_server_config(file_path=CONFIG_FILE)
    @config = Oj.load File.read(file_path)
    @config.merge! get_default_config.reject { |k, _| @config.keys.include? k }
    @config
  rescue
    log "Failed to load config from #{file_path}. Using default config. This is expected on first start.", level: :warn
    get_default_config
  end

  def write_config(config=@config, file_path=CONFIG_FILE)
    log "Writing config"
    File.write(file_path + '.tmp', Oj.dump(config))
    FileUtils.mv(file_path, file_path + '.bak') if File.exist? file_path
    FileUtils.mv(file_path + '.tmp', file_path)
    true
  rescue => e
    log 'Failed to write config', e
    false
  end

  def init_server_config_files
    [
      CONFIG_FILES[:game_ini],
      CONFIG_FILES[:engine_ini],
      CONFIG_FILES[:admins_txt],
      CONFIG_FILES[:mapcycle_txt],
      CONFIG_FILES[:bans_json]
    ].each do |it|
      [it[:actual], it[:local]].each do |file|
        FileUtils.mkdir_p File.dirname(file)
        FileUtils.touch file
      end
    end
  end

  def apply_server_config_files
    # Apply values in case any in memory aren't in the file
    apply_game_ini_local
    apply_engine_ini_local

    # Then apply all values in our ini to the server's default
    CONFIG_FILES.select { |_, data| data['type'] == :ini }.each do |it|
      log "Applying #{it[:local]} -> #{it[:actual]}"
      update_ini(it[:local], it[:actual])
    end
    # Copy over non-ini local files to server files in case the server edits them
    CONFIG_FILES.select { |_, data| data['type'] != :ini }.each do |_, it|
      log "Applying #{it[:local]} -> #{it[:actual]}"
      FileUtils.cp it[:actual], it[:actual] + '.bak'
      FileUtils.cp it[:local], it[:actual]
    end
  end

  def set(variable, value)
    return [false, "Variable not in config: #{variable}"] unless CONFIG_VARIABLES.keys.include? variable
    return [false, "Variable has no validation: #{variable}"] unless CONFIG_VARIABLES[variable]['validation'].respond_to?('call')
    return [false, "Variable #{variable} is already set to #{CONFIG_VARIABLES[variable]['sensitive'] ? '[REDACTED]' : value}."] if value.to_s == @config[variable].to_s
    status = false
    msg = "Failed to set #{variable.inspect} to #{CONFIG_VARIABLES[variable]['sensitive'] ? '[REDACTED]' : value.inspect}"
    old_value = @config[variable] || CONFIG_VARIABLES[variable]['default'] || 'Unknown'

    if CONFIG_VARIABLES[variable]['validation'].call(value)
      log "Value passed validation: #{CONFIG_VARIABLES[variable]['sensitive'] ? '[REDACTED]' : value.inspect}"
      @config[variable] = value
      write_config
      apply_game_ini_local if CONFIG_VARIABLES[variable]['type'] == :game_ini
      apply_engine_ini_local if CONFIG_VARIABLES[variable]['type'] == :engine_ini
      status = true
    else
      msg = "Value failed validation for variable #{variable.inspect}: #{CONFIG_VARIABLES[variable]['sensitive'] ? '[REDACTED]' : value.inspect}"
      log msg, level: :warn
    end

    return [status, msg, CONFIG_VARIABLES[variable]['sensitive'] ? '[REDACTED]' : @config[variable], CONFIG_VARIABLES[variable]['sensitive'] ? '[REDACTED]' : old_value]
  end

  def get(variable)
    @config[variable]
  end

  def get_scenario(map, mode, side)
    filtered_map = MAPMAP[map]
    "Scenario_#{filtered_map}_#{mode}_#{side}"
  end

  def get_query_string(map: nil, side:nil, game_mode: nil, scenario_mode: nil, max_players: @config['server_max_players'], password: @config['server_password'])
    map = @config['server_default_map'] == 'Random' ? MAPMAP.keys.sample : @config['server_default_map'] if map.nil?
    side = @config['server_default_side'] == 'Random' ? SIDES.sample : @config['server_default_side'] if side.nil?
    game_mode = @config['server_game_mode'] == 'Random' ? GAME_MODES.sample : @config['server_game_mode'] if game_mode.nil?
    scenario_mode = @config['server_scenario_mode'] == 'Random' ? SCENARIO_MODES.sample : @config['server_scenario_mode'] if scenario_mode.nil?
    scenario = get_scenario(map, scenario_mode, side)
    query = "#{map}?Scenario=#{scenario}?MaxPlayers=#{max_players}?Game=#{game_mode}"
    query << "?Password=#{password}" unless password.empty?
    query
  end

  def get_server_arguments
    arguments = []
    arguments.push(
      get_query_string,
      "-Hostname=#{@config['server_hostname']}",
      "-MaxPlayers=#{@config['server_max_players']}",
      "-Port=#{@config['server_game_port']}",
      "-QueryPort=#{@config['server_query_port']}",
      "-log",
      "-AdminList=Admins",
      "-MapCycle=MapCycle"
    )
    arguments.push("-ruleset=#{@config['server_rule_set']}") unless @config['server_rule_set'] == 'None'
    if @config['server_gslt'].to_s.empty?
      arguments.push("-EnableCheats") if @config['server_cheats'].to_s.casecmp('true').zero?
    else
      arguments.push("-GameStats", "-GSLTToken=#{@config['server_gslt']}")
    end
    arguments
  end

  def apply_game_ini_local
    apply_ini(CONFIG_FILES[:game_ini][:local])
  end

  def apply_engine_ini_local
    apply_ini(CONFIG_FILES[:engine_ini][:local])
  end

  def update_ini(source, dest)
    log "Updating ini #{source} -> #{dest}"
    source_ini = IniFile.load(source)
    dest_ini = IniFile.load(dest)
    source_ini.each_section do |section|
      source_ini[section].each do |variable, value|
        log "Setting [#{section}][#{variable}] = #{value}"
        dest_ini[section][variable] = value
      end
    end
  rescue => e
    log "Error while updating ini", e
    raise
  end

  def apply_ini(path)
    type = File.basename(path).downcase.sub('.', '_').to_sym
    log "Applying #{type} values to #{path}"
    ini = IniFile.load(path)
    changed = false
    CONFIG_VARIABLES.select { |_, metadata| metadata['type'] == type }.each do |option, metadata|
      next if metadata['getter'].call(ini).to_s == @config[option].to_s
      changed = true
      log "Applying #{option}"
      metadata['setter'].call(ini, @config[option])
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
