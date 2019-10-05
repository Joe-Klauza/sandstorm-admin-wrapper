#!/usr/bin/env ruby

require 'fileutils'
require 'open3'
require_relative 'subprocess'

class ServerUpdater
  attr_reader :update_available
  attr_reader :thread

  def initialize(server_root_dir, steamcmd_path, steam_appinfovdf_path)
    @server_root_dir = server_root_dir
    @app_manifest = File.join server_root_dir, 'steamapps', 'appmanifest_581330.acf'
    # raise Errno::ENOENT, @app_manifest unless File.exist? @app_manifest
    @steamcmd_path = steamcmd_path
    # raise Errno::ENOENT, @steamcmd_path unless File.exist? @steamcmd_path
    @steam_appinfovdf_path = steam_appinfovdf_path

    @update_available = false
    @installed_build_id = nil
    @available_build_id = nil
    Thread.new { update_available? } # Populate update availability (still pretty slow sometimes)
  end

  def back_up_app_cache
    FileUtils.mv(@steam_appinfovdf_path, @steam_appinfovdf_path + '.bak') if File.exist?(@steam_appinfovdf_path)
  rescue => e
    log "Error backing up app cache", e
  end

  def restore_app_cache
    FileUtils.cp(@steam_appinfovdf_path + '.bak', @steam_appinfovdf_path) if File.exist?(@steam_appinfovdf_path + '.bak') && !File.exist?(@steam_appinfovdf_path)
  rescue => e
    log "Error restoring app cache", e
  end

  def get_update_info
    return [@update_available, @installed_build_id, @available_build_id]
  end

  def get_latest_build_id
    back_up_app_cache
    stdout, stderr, status = Open3.capture3(@steamcmd_path,
      '+login anonymous',
      '+app_info_print 581330',
      '+exit'
    )
    found_text = stdout[/branches(.*\n){5}/]
    return nil if found_text.nil?
    build_id = found_text.split("\n").last[/\d+/] # public buildid is several lines after "branches"; seems to always be at the top of branches.
    log "Got latest build ID: #{build_id}"
    @available_build_id = build_id
  rescue => e
    log "Rescued error while getting latest build ID", e
    log "SteamCMD STDOUT: #{stdout}\nSteamCMD STDERR: #{stderr}", level: :error
    nil
  ensure
    restore_app_cache
  end

  def get_installed_build_id
    open(@app_manifest) do |file|
      build_id = file.grep(/buildid/).first
      build_id = build_id[/\d+/] unless build_id.nil?
      log "Got installed build ID: #{build_id}"
      @installed_build_id = build_id
    end
  rescue => e
    log "Rescued error while getting installed build ID", e
    nil
  end

  # Returns true if update is required, false otherwise (including when checks failed)
  def update_available?(installed_build_id=get_installed_build_id, latest_build_id=get_latest_build_id)
    if installed_build_id.nil? || latest_build_id.nil?
      available = false
    else
      available = installed_build_id == latest_build_id ? false : true
    end
    log (available ? 'Update is available!' : 'Server is up-to-date!')
    @update_available = available
  end

  def run_steamcmd(command, buffer: nil, ignore_status: false, ignore_message: false)
    command.unshift @steamcmd_path
    thread = Thread.new do
      # Start a thread so we can change the environment...
      log "Running SteamCMD command: #{command}", level: :info
      SubprocessRunner.run(
        command,
        buffer: buffer,
        ignore_status: ignore_status,
        ignore_message: ignore_message
      )
    end
    thread.join
    output = if buffer.nil?
        thread.value
      else
        buffer[:data].join("\n")
      end
    update_text = nil
    updated = ['fully installed.', 'already up to date.'].any? do |it|
      if output.include? it
        update_text = it
        update_text.prepend 'update ' if update_text.include? 'fully'
        true
      else
        false
      end
    end
    response = "Server #{updated ? update_text : 'failed to update!' }"
    log response, level: updated ? :info : :error
    if buffer
      buffer.synchronize do
        buffer[:status] = updated
        buffer[:message] = response
      end
    end
    [updated, response]
  end

  # Returns true if an update was performed, false if already up-to-date
  def update_server(buffer=nil, validate: nil, ignore_status: true, ignore_message: true)
    log 'Updating server', level: :info
    command = [
      '+login anonymous',
      "+force_install_dir \"#{@server_root_dir}\"",
      "+app_update 581330#{' validate' if validate}",
      '+exit'
    ]
    updated, response = run_steamcmd(command, buffer: buffer, ignore_status: ignore_status, ignore_message: ignore_message)
    update_available?
    [updated, response]
  end

  def monitor_update(minutes_between_checks: 3)
    while true
      begin
        if update_available?
          log 'A new server update is available!', level: :info
          yield if block_given?
        end
      rescue => e
        log "Rescued error during update check", e
      end
      sleep 60 * minutes_between_checks
    end
  end
end
