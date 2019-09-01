
# Threads which terminate unexpectedly are not logged
# so we monkey-patch a rescue in for StandardErrors in order
# to log and raise the exception.

Thread.report_on_exception = false

module ThreadExtensions
  def initialize
    begin
      super do
        begin
          yield
        rescue => e
          level = :error
          level = :debug if e.is_a?(IOError) && e.message == 'stream closed in another thread'
          log "(#{self.inspect}#{' ' << self[:name] if self[:name]}) StandardError in thread", e, level: level
          raise e
        end
      end
    end
  end
end

class Thread
  prepend ThreadExtensions
end
