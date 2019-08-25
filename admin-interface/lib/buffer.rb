require_relative 'logger'

class Buffer < Hash
  def initialize(uuid)
    self.merge!({
      uuid: uuid,
      data: [],
      bookmarks: {},
      status: nil,
      message: nil,
      mutex: Mutex.new,
      limit: 500,
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
      self[:data].clear
      self[:bookmarks].clear
    end
    self[:status] = nil
    self[:message] = nil
  end
end
