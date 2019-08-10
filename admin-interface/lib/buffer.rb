require_relative 'logger'

class Buffer < Hash
  def initialize
    self.merge!({
      data: [],
      bookmarks: {},
      status: nil,
      message: nil,
      mutex: Mutex.new,
      limit: 1000,
      filters: [],
      persistent: false
    })
  end

  def synchronize
    self[:mutex].synchronize { yield }
  end

  def truncate(limit: self[:limit])
    size = self[:data].size
    return 0 unless size > limit
    over_limit = size - limit
    self[:data].shift over_limit # Remove the first (oldest) n elements
    self[:bookmarks].each do |uuid, value|
      next if value == -1
      self[:bookmarks][uuid] = (value - over_limit).floor 0
    end
    over_limit
  end

  def reset
    unless self[:persistent]
      self[:data] = []
      self[:bookmarks] = {}
    end
    self[:status] = nil
    self[:message] = nil
  end
end
