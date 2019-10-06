require 'bcrypt'
require 'erb'
require 'fileutils'
require 'inifile'
require 'oj'
require 'socket'
require 'sysrandom'
require_relative 'logger'

CONFIG_PATH = File.expand_path File.join File.dirname(__FILE__), '..', 'config'
CONFIG_FILE = File.join CONFIG_PATH, 'config.json'
USERS_CONFIG_FILE = File.join CONFIG_PATH, 'users.json'
MONITOR_CONFIGS_FILE = File.join CONFIG_PATH, 'monitor-configs.json'
SERVER_CONFIGS_FILE = File.join CONFIG_PATH, 'server-configs.json'

WRAPPER_ROOT = File.expand_path(File.join(File.dirname(__FILE__), '..', '..')).freeze
WRAPPER_CONFIG = File.join WRAPPER_ROOT, 'config'
WEBAPP_ROOT = File.join WRAPPER_ROOT, 'admin-interface'
WEBAPP_CONFIG = File.join(WRAPPER_CONFIG, 'config.toml')
WEBAPP_CONFIG_SAMPLE = File.join(WRAPPER_CONFIG, 'config.toml.sample')
GENERATED_SSL_CERT = File.join(WRAPPER_CONFIG, 'generated_ssl_cert.pem')
GENERATED_SSL_KEY = File.join(WRAPPER_CONFIG, 'generated_ssl_key.pem')
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
    local_erb: "<%=File.join(CONFIG_FILES_DIR, ConfigHandler.sanitize_directory(config_name), 'Game.ini')%>"
  },
  engine_ini: {
    type: :ini,
    actual: File.join(SERVER_ROOT, 'Insurgency', 'Saved', 'Config', (WINDOWS ? 'WindowsServer' : 'LinuxServer'), 'Engine.ini'),
    local_erb: "<%=File.join(CONFIG_FILES_DIR, ConfigHandler.sanitize_directory(config_name), 'Engine.ini')%>"
  },
  admins_txt: {
    type: :txt,
    actual: File.join(SERVER_ROOT, 'Insurgency', 'Config', 'Server', 'Admins.txt'),
    local_erb: "<%=File.join(CONFIG_FILES_DIR, ConfigHandler.sanitize_directory(config_name), 'Admins.txt')%>"
  },
  mapcycle_txt: {
    type: :txt,
    actual: File.join(SERVER_ROOT, 'Insurgency', 'Config', 'Server', 'MapCycle.txt'),
    local_erb: "<%=File.join(CONFIG_FILES_DIR, ConfigHandler.sanitize_directory(config_name), 'MapCycle.txt')%>"
  },
  bans_json: {
    type: :json,
    actual: File.join(SERVER_ROOT, 'Insurgency', 'Config', 'Server', 'Bans.json'),
    local_erb: "<%=File.join(CONFIG_FILES_DIR, 'Bans.json')%>" # Master Bans.json due to multi-server
  }
}

MAPMAP = {
  'Canyon'    => 'Crossing',
  'Compound'  => 'Outskirts',
  'Farmhouse' => 'Farmhouse',
  'Sinjar'    => 'Hillside',
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
  'Firefight_A', # Ministry... https://newworldinteractive.com/isl/uploads/2019/09/Sandstorm-Server-Admin-Guide-1.4.pdf
  'Firefight_East',
  'Firefight_West',
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
MUTATORS = {
  'AllYouCanEat' => { 'name' => 'All You Can Eat', 'description' => 'Start with 100 supply points.' },
  'AntiMaterielRiflesOnly' => { 'name' => 'Anti-Materiel Only', 'description' => 'Only anti-materiel rifles are available along with normal equipment and explosives.' },
  'BoltActionsOnly' => { 'name' => 'Bolt-Actions Only', 'description' =>'Only bolt-action rifles are available along with normal equipment and explosives.' },
  'Broke' => { 'name' => 'Broke', 'description' => 'Start with 0 supply points.' },
  'BulletSponge' => { 'name' => 'Bullet Sponge', 'description' => 'Health is increased.' },
  'Competitive' => { 'name' => 'Competitive', 'description' => 'Equipment is more expensive, rounds are shorter, and capturing objectives is faster.' },
  'CompetitiveLoadouts' => { 'name' => 'Competitive Loadouts', 'description' => 'Player classes are replaced with those from Competitive.' },
  'FastMovement' => { 'name' => 'Fast Movement', 'description' => 'Move faster.' },
  'Frenzy' => { 'name' => 'Frenzy', 'description' => 'Fight against AI enemies who only use melee attacks. Watch out for special enemies.' },
  'Guerrillas' => { 'name' => 'Guerrillas', 'description' => 'Start with 5 supply points.' },
  'Hardcore' => { 'name' => 'Hardcore', 'description' => 'Mutator featuring slower movement speeds and longer capture times.' },
  'HeadshotOnly' => { 'name' => 'Headshots Only', 'description' => 'Players only take damage when shot in the head.' },
  'HotPotato' => { 'name' => 'Hot Potato', 'description' => 'A live fragmentation grenade is dropped on death.' },
  'LockedAim' => { 'name' => 'Locked Aim', 'description' => 'Weapons always point to the center of the screen.' },
  'NoAim' => { 'name' => 'No Aim Down Sights', 'description' => 'Aiming down sights is disabled.' },
  'PistolsOnly' => { 'name' => 'Pistols Only', 'description' => 'Only pistols are available along with normal equipment and explosives.' },
  'ShotgunsOnly' => { 'name' => 'Shotguns Only', 'description' => 'Only Shotguns are available along with normal equipment and explosives.' },
  'SlowCaptureTimes' => { 'name' => 'Slow Capture Times', 'description' => 'Objectives will take longer to capture.' },
  'SlowMovement' => { 'name' => 'Slow Movement', 'description' => 'Move slower.' },
  'SoldierOfFortune' => { 'name' => 'Soldier of Fortune', 'description' => 'Gain supply points as your score increases.' },
  'SpecialOperations' => { 'name' => 'Special Operations', 'description' => 'Start with 30 supply points.' },
  'Strapped' => { 'name' => 'Strapped', 'description' => 'Start with 1 supply point.' },
  'Ultralethal' => { 'name' => 'Ultralethal', 'description' => 'Everyone dies with one shot.' },
  'Vampirism' => { 'name' => 'Vampirism', 'description' => 'Receive health when dealing damage to enemies equal to the amount of damage dealt.' },
  'Warlords' => { 'name' => 'Warlords', 'description' => 'Start with 10 supply points.' }
}


class ConfigHandler
  attr_reader :monitor_configs
  attr_reader :server_configs
  attr_reader :users

  def self.generate_password
    Sysrandom.base64(32 + Sysrandom.random_number(32)).gsub("\n", '')
  end

  CONFIG_VARIABLES = {
    'server-config-name' => {
      'default' => 'Default',
      'validation' => Proc.new { true }
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
      'default' => 'None',
      'validation' => Proc.new { |mode| ['None'].concat(GAME_MODES).include? mode }
    },
    'server_scenario_mode' => {
      'default' => 'Checkpoint',
      'validation' => Proc.new { |mode| SCENARIO_MODES.include? mode }
    },
    'server_rule_set' => {
      'default' => 'None',
      'validation' => Proc.new { |rule_set| RULE_SETS.include?(rule_set) || rule_set = 'None' }
    },
    'server_mutators' => {
      'default' => [],
      'validation' => Proc.new { |mutators| mutators.all? { |mutator| MUTATORS.keys.include?(mutator) } }
    },
    'server_cheats' => {
      'default' => 'false',
      'validation' => Proc.new { |val| ['true', 'false'].include? val }
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
      'validation' => Proc.new { |port| ConfigHandler.valid_port? port }
    },
    'server_query_port' => {
      'default' => '27131',
      'type' => :argument,
      'template' => '-QueryPort=<%= it %>',
      'validation' => Proc.new { |port| ConfigHandler.valid_port? port }
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
      'validation' => Proc.new { |port| ConfigHandler.valid_port? port }
    },
    'server_rcon_password' => {
      'default' => ConfigHandler.generate_password,
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
    'hang_recovery' => {
      'default' => 'true',
      'validation' => Proc.new { |val| ['true', 'false'].include? val }
    }
  }

  def initialize
    @users = load_user_config
    @monitor_configs = load_monitor_configs
    @server_configs = load_server_configs
    @bans_mutex = Mutex.new
  end

  def self.valid_port?(port)
    port = port.to_i
    port >= 1 && port <= 65535
  rescue
    false
  end

  def self.sanitize_directory(directory_name)
    directory_name.gsub(/[^ 0-9A-Za-z.\-]/, '')
  end

  def get_default_config
    defaults = {}
    CONFIG_VARIABLES.each { |k, v| defaults[k] = v['default'] }
    defaults
  end

  def get_default_user_config
    default_admin_user = User.new('admin', :host, password: BCrypt::Password.create('password').to_s, initial_password: 'password')
    {
      default_admin_user.id => default_admin_user
    }
  end

  def load_user_config
    @users = Oj.load(File.read(USERS_CONFIG_FILE))
    @users = get_default_user_config if @users.to_s.strip.empty?
    @users
  rescue Errno::ENOENT
    get_default_user_config
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
    init_server_config_files
    @server_configs.each do |config_name, config|
      server_configs[config_name] = get_default_config.merge(config)
    end
    @server_configs
  rescue Errno::ENOENT
    {'Default' => get_default_config}
  rescue => e
    log "Failed to load server configs from #{SERVER_CONFIGS_FILE}. Using empty config.", e
    raise
  end

  def write_user_config
    log "Writing user config"
    File.write(USERS_CONFIG_FILE, Oj.dump(@users, indent: 2))
  end

  def write_monitor_configs
    log "Writing monitor configs"
    File.write(MONITOR_CONFIGS_FILE, Oj.dump(@monitor_configs, indent: 2))
  end

  def create_server_config(config_name, settings)
    log "Creating server config: #{config_name}"
    server_configs[config_name] = get_default_config.
        merge(server_configs[config_name] || {}).
        merge(settings).
        merge({'server-config-name' => config_name})
    write_server_configs
    init_server_config_files(config_name)
    nil
  end

  def delete_server_config(config_name)
    log "Deleting server config: #{config_name}"
    server_configs.delete config_name
    CONFIG_FILES.values.each do |it|
      local = ERB.new(it[:local_erb]).result(binding)
      FileUtils.rm local rescue nil
    end
    FileUtils.rmdir File.join(CONFIG_FILES_DIR, config_name) rescue nil
    write_server_configs
    nil
  end

  def write_server_configs
    log "Writing server configs"
    File.write(SERVER_CONFIGS_FILE, Oj.dump(@server_configs, indent: 2))
    nil
  end

  def write_config
    write_user_config
    write_monitor_configs
    write_server_configs
    true
  rescue => e
    log 'Failed to write config', e
    false
  end

  def init_server_config_files(config_name=nil)
    configs = config_name.nil? ? @server_configs.keys : [config_name]
    configs.map {|name| ConfigHandler.sanitize_directory name }.each do |config_name|
      CONFIG_FILES.values.each do |it|
        [ERB.new(it[:local_erb]).result(binding), it[:actual]].each do |path|
          FileUtils.mkdir_p File.dirname path
          FileUtils.touch path
        end
      end
    end
    nil
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

  def apply_server_bans
    @bans_mutex.synchronize do
      server_bans = Oj.load(File.read CONFIG_FILES[:bans_json][:actual]) || []
      master_bans = Oj.load(File.read ERB.new(CONFIG_FILES[:bans_json][:local_erb]).result(binding)) || []
      return if server_bans == master_bans
      log "Applying new player bans"
      master_bans.concat(server_bans).uniq! { |ban| ban['playerId'] }
      master_bans.sort_by! { |ban| ban['banTime'] }
      File.write(ERB.new(CONFIG_FILES[:bans_json][:local_erb]).result(binding), Oj.dump(master_bans, indent: 2))
    end
    nil
  end

  def set(config_name, variable, value)
    return [false, "Variable not in config: #{variable}"] unless CONFIG_VARIABLES.keys.include? variable
    return [false, "Variable has no validation: #{variable}"] unless CONFIG_VARIABLES[variable]['validation'].respond_to?('call')
    config = (@server_configs[config_name] = get_default_config.merge(@server_configs[config_name] || {}))
    old_value = config[variable]
    return [false, "Variable #{variable} is already set to #{CONFIG_VARIABLES[variable]['sensitive'] ? '[REDACTED]' : value}."] if value.to_s == old_value.to_s
    status = false
    msg = "Failed to set #{variable.inspect} to #{CONFIG_VARIABLES[variable]['sensitive'] ? '[REDACTED]' : value.inspect}"
    old_value = old_value || CONFIG_VARIABLES[variable]['default'] || 'Unknown'

    if CONFIG_VARIABLES[variable]['validation'].call(value)
      log "Value passed validation: #{CONFIG_VARIABLES[variable]['sensitive'] ? '[REDACTED]' : value.inspect}"
      config[variable] = value
      write_server_configs
      apply_game_ini_local(@server_configs[config_name], config_name) if CONFIG_VARIABLES[variable]['type'] == :game_ini
      apply_engine_ini_local(@server_configs[config_name], config_name) if CONFIG_VARIABLES[variable]['type'] == :engine_ini
      status = true
    else
      msg = "Value failed validation for variable #{variable.inspect}: #{CONFIG_VARIABLES[variable]['sensitive'] ? '[REDACTED]' : value.inspect}"
      log msg, level: :warn
    end

    return [status, msg, CONFIG_VARIABLES[variable]['sensitive'] ? '[REDACTED]' : config[variable], CONFIG_VARIABLES[variable]['sensitive'] ? '[REDACTED]' : old_value]
  end

  def get(config_name, variable)
    @server_configs[config_name][variable]
  end

  def get_log_file(config_name)
    log_file = File.join(SERVER_LOG_DIR, "#{config_name}.log")
    FileUtils.mkdir_p File.dirname log_file
    begin
      FileUtils.touch log_file
    rescue Errno::EACCES
      log "Unable to access log file: #{log_file}"
    end
    log_file
  end

  def get_scenario(map, mode, side)
    filtered_map = MAPMAP[map] || map
    "Scenario_#{filtered_map}_#{mode}#{'_' << side if ['Checkpoint', 'Push'].include?(mode)}"
  end

  def get_query_string(config, map: nil, side:nil, game_mode: nil, scenario_mode: nil, max_players: nil, password: nil)
    map = config['server_default_map'] == 'Random' ? MAPMAP.keys.sample : config['server_default_map'] if map.nil?
    side = config['server_default_side'] == 'Random' ? SIDES.sample : config['server_default_side'] if side.nil?
    game_mode = config['server_game_mode'] == 'Random' ? GAME_MODES.sample : config['server_game_mode'] if game_mode.nil?
    scenario_mode = config['server_scenario_mode'] == 'Random' ? SCENARIO_MODES.sample : config['server_scenario_mode'] if scenario_mode.nil?
    max_players ||= config['server_max_players']
    password ||= config['server_password']
    scenario = get_scenario(map, scenario_mode, side)
    query = "#{map}?Scenario=#{scenario}?MaxPlayers=#{max_players}"
    query << "?Game=#{game_mode}" unless game_mode == 'None'
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
      "-log=#{config['server-config-name']}.log",
      "-LogCmds=LogGameplayEvents Log",
      "-AdminList=Admins",
      "-MapCycle=MapCycle"
    )
    arguments.push("-ruleset=#{config['server_rule_set']}") unless config['server_rule_set'] == 'None'
    arguments.push("-mutators=#{config['server_mutators'].join(',')}") unless config['server_mutators'].empty?
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
