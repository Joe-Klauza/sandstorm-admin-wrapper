# PTY doesn't work on windows, but on Linux it gets us concurrent progress output from steamcmd since steamcmd detects shell interactivity for this
# https://github.com/ValveSoftware/Source-1-Games/issues/1684
PTY_AVAILABLE = WINDOWS ? false : (require 'pty')
require_relative 'logger'

class SubprocessRunner
  def self.run_via_pty(command)
    read, write, pid = PTY.spawn(*command)
    return [pid, read, nil, write]
  end

  def self.run_via_process(command, out, err, input=nil)
    opts = {
      out: out,
      err: err,
      in: input
    }.reject { |_, v| v.nil? }
    pid = Process.spawn(*command, opts)
  end

  def self.run(command, buffer: nil, ignore_status: false, ignore_message: false, out: IO.pipe, err: IO.pipe, input: nil, shell: [], pty: PTY_AVAILABLE, no_prefix: false, formatter: nil)
    origin = File.basename command.first
    origin = "#{File.basename shell.first}(#{origin})" unless shell.empty?
    command = command.split(' ') unless command.is_a? Array

    log "Running subprocess via (#{pty ? 'PTY' : 'Process'}): #{command}"
    command = shell.concat command

    pid, stdout, stderr, stdin = if pty
      [out, err, input].each { |pipe| pipe.close if pipe.respond_to?('close') }
      run_via_pty(command)
    else
      pid = run_via_process(command, out.last, err.last, input)
      [pid, out.first, err.first]
    end
    yield(pid) if block_given?
    captured_output = []
    [stdout, stderr].reject(&:nil?).each do |stream|
      Thread.new do
        loop do
          output = stream.gets
          break if output.nil?
          formatted_output = if formatter
              formatter.call(output, origin)
            else
              no_prefix ? output.chomp : "#{datetime} | #{origin} | #{output.chomp}"
            end
          if buffer.nil?
            captured_output.push output
          else
            buffer[:filters].each { |filter| filter.call(formatted_output) }
            buffer[:mutex].synchronize do # Synchronize with the reading thread to avoid mismatched indices when truncating, etc.
              buffer.push formatted_output
            end
          end
          log formatted_output # Ensure this is after filters to avoid NWI's lack of color code resets
        rescue Errno::EIO, IOError, EOFError => e
          break
        end
      end
    end
    pid, process_status = Process.wait2(pid)

    log "Checking exit status"
    status, message = if process_status.exitstatus
      [process_status.exitstatus.zero? ? true : false, "PID (#{pid}) #{process_status.exitstatus.zero? ? 'completed successfully' : 'exited unsuccessfully'} (#{process_status.exitstatus})."]
    else
      if process_status.signaled?
        signal = process_status.termsig || process_status.stopsig
        [true, "PID (#{pid}) stopped with signal #{Signal.list.key signal} (#{signal})."]
      else
        [false, "PID (#{pid}) stopped for an unknown reason."]
      end
    end

    log "Exit status/message: #{status} - #{message}"

    if buffer.nil?
      captured_output.join("\n")
    else
      buffer.synchronize do
        buffer[:status] = status unless ignore_status
        buffer[:message] = message unless ignore_message
      end
    end
  rescue => e
    log "Error running subprocess: #{command}", e
    raise e
  ensure
    [out.first, out.last, err.first, err.last, input, stdout, stderr, stdin].each { |pipe| pipe.close if pipe.respond_to?('close') }
  end
end
