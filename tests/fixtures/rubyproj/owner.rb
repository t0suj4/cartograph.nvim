require_relative 'visits'

class Owner
  def full_name
    build_name(first_part)
  end

  def self.find_by_city(city)
    lookup(city)
  end

  def build_name(x)
    x
  end

  def first_part
    "a"
  end
end

def helper
  Owner.new
end
