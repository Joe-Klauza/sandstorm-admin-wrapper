# encoding: UTF-8

require 'logger'

Dir.mkdir 'log' unless Dir.exist? 'log'
LOG_FILE = File.join('log', 'sandstorm-admin-wrapper.log')
SEVERITY_JUSTIFY = Logger::Severity.constants.map(&:length).max # [:DEBUG, :INFO, :WARN, :ERROR, :FATAL, :UNKNOWN]
DATETIME_FORMAT = "%Y/%m/%d %H:%M:%S.%L %z"
$caller_justification = 25

class MultiTargetLogger
  attr_reader :level
  attr_reader :loggers

  def initialize(loggers)
    @level = Logger::DEBUG
    loggers.each do |name, logger|
      logger.formatter = proc do |severity, datetime, progname, message|
        "#{datetime} | #{severity.ljust SEVERITY_JUSTIFY}#{" | #{progname}" if progname} | #{message}\n"
      end
      logger.level = @level
    end
    @loggers = loggers
  end

  Logger::Severity.constants.each do |severity|
    severity = severity.downcase
    define_method(severity) do |*args|
      # Suppress SSL error for self-generated certificate
      if args.first.to_s.end_with? ': sslv3 alert certificate unknown'
        severity = :debug
        args[0] = args.first.to_s
      end
      @loggers.each { |_, logger| logger.send(severity, *args) if Logger.const_get(severity.to_s.upcase) >= logger.level }
      if args.first.is_a? Exception
        @loggers.each { |_, logger| logger.send(:error, "Backtrace:#{args.first.backtrace.join("\n  ").prepend("\n  ")}") if Logger.const_get(severity.to_s.upcase) >= logger.level }
      end

      nil
    end
    define_method("#{severity}?") do |*args|
      Logger.const_get(severity.to_s.upcase) >= @level
    end
  end

  def puts(*args)
    log(:debug, *args)
  end


  def log(severity, *args)
    severity = severity.downcase
    @loggers.each { |_, logger| logger.send(severity, *args) if Logger.const_get(severity.to_s.upcase) >= logger.level }
    nil
  end

  def threshold(severity=nil, logger: :stdout)
    return @loggers[:stdout].level if severity.nil?
    level = severity.is_a?(Integer) ? severity : Logger.const_get(severity.to_s.upcase)
    @loggers[:stdout].level = level
    prev_level = @level
    @level = level
    prev_level
  end

  def <<(message, severity: :debug)
    log(severity, message.chomp) # Thanks, WEBrick AccessLog...
    nil
  end
end

LOGGER_FILE = Logger.new(LOG_FILE, 10, 1024 * 5000)
LOGGER_STDOUT = Logger.new($stdout)
LOGGER = MultiTargetLogger.new({stdout: LOGGER_STDOUT, file: LOGGER_FILE})

def datetime # Helper function used elsewhere
  Time.now.strftime(DATETIME_FORMAT)
end

def log(message, exception=nil, level: nil)
  unless exception.nil?
    message = message + " | Exception occurred (#{exception.class}): #{exception.message}\n  #{exception.backtrace.to_a.map { |l| l.sub USER_HOME, '~'}.join("\n  ")}"
    level ||= :error
  end
  level ||= :debug
  LOGGER.log level, message
end

