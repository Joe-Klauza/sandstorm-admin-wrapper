# encoding: UTF-8

require 'unicode/display_width'

# Certain UTF-8 characters display as wider than they report with the standard Ruby length method
# This can cause issues when justifying text containing these characters. Use the methods below instead.
class String
  def length_utf8
    Unicode::DisplayWidth.of(self)
  end

  def ljust_utf8(length, padstr=' ')
    if Unicode::DisplayWidth.of(self) < length
      self + (padstr * (length - Unicode::DisplayWidth.of(self)))
    else
      self
    end
  end

  def rjust_utf8(length, padstr=' ')
    if Unicode::DisplayWidth.of(self) < length
      (padstr * (length - Unicode::DisplayWidth.of(self))) + self
    else
      self
    end
  end

  def center_utf8(length, padstr=' ')
    if Unicode::DisplayWidth.of(self) < length
      prefix = padstr * ((length - Unicode::DisplayWidth.of(self))/2.to_f).floor # Floor here to keep text left of center if uneven
      postfix = padstr * ((length - Unicode::DisplayWidth.of(self))/2.to_f).ceil
      prefix + self + postfix
    else
      self
    end
  end

  def utf8
    s = force_encoding('UTF-8')
    s.strip # Don't strip; test that it can be stripped (else we fall back to encode())
    s
  rescue => e
    log("Failed to encode string as UTF-8: #{self.inspect}", level: :warn)
    encode('UTF-8', invalid: :replace, undef: :replace)
  end
end
