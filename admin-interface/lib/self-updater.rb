require 'fileutils'
require 'json'
require 'net/http'
require 'open-uri'
require 'pathname'
require 'zip'

class SelfUpdater
  UPDATE_ZIP = File.join WRAPPER_ROOT, 'update.zip'
  IGNORE_FILES = [
    'config/config.toml'
  ]

  def self.download(url, path)
    case io = open(url)
    when StringIO
      File.open(path, 'w') { |f| f.write(io) }
    when Tempfile
      io.close
      FileUtils.mv(io.path, path)
    else
      log "Unhandled IO type: #{io}", :warn
    end
  end

  def self.update_to_latest
    log "Determining latest release"
    releases = JSON.parse Net::HTTP.get(URI('https://api.github.com/repos/Joe-Klauza/sandstorm-admin-wrapper/releases'))
    latest = releases.first
    version = latest['name']
    zip_download_url = latest['zipball_url']
    log "Downloading #{version}: #{zip_download_url}"

    Dir.chdir WRAPPER_ROOT do
      SelfUpdater.download(zip_download_url, UPDATE_ZIP)
      log "Downloaded #{version} to update.zip"
      log "Extracting update.zip"
      Zip::File.open(UPDATE_ZIP) do |zip_file|
        zip_file.each do |f|
          filename = File.join Pathname(f.name).each_filename.to_a[1..] # Ignore project dir
          filepath = File.join(WRAPPER_ROOT, filename)
          next if IGNORE_FILES.include?(filename)
          zip_file.extract(f, filepath) { true } # Overwrite
        end
      end
    end
    log "Extracted update.zip"
    log "Deleting update.zip"
    FileUtils.rm(UPDATE_ZIP)
    log "Deleted update.zip"
    version
  rescue => e
    log "Failed to update to latest", e
    raise "Failed to update. (#{e.class}): #{e.message}"
  end
end
