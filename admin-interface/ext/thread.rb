
# Threads which terminate unexpectedly are not logged
# so we monkey-patch a rescue in for StandardErrors in order
# to log and raise the exception.

module ThreadExtensions
  def initialize
    begin
      super do
        begin
          yield
        rescue => e
          log "(#{self.inspect}#{' ' << self[:name] if self[:name]}) StandardError in thread", e
          raise e
        end
      end
    end
  end
end

class Thread
  prepend ThreadExtensions
end
