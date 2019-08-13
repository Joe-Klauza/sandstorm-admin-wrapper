require 'bcrypt'
require 'sysrandom'

class User
  attr_reader :name
  attr_reader :role

  ROLES = {
    host: 3,
    admin: 2,
    user: 1
  }

  def initialize(name, role, password: nil, initial_password: nil)
    @name = name # Name will also be our GUID, since having duplicate user names is confusing without emails
    @role = role
    @initial_password = initial_password
    if password
      # User info is being read from file
      @password = BCrypt::Password.new(password).to_s
    else
      generate_initial_password
    end
  end

  def first_login?
    return false if @initial_password.nil?
    password_matches?(@initial_password)
  end

  def generate_initial_password
    @initial_password = Sysrandom.base64(32 + Sysrandom.random_number(32))
    @password = BCrypt::Password.create(@initial_password).to_s
  end

  def password # So we can user.password == 'password'
    BCrypt::Password.new(@password)
  end

  def password=(new_password)
    @initial_password = nil
    @password = BCrypt::Password.create(new_password).to_s
  end

  def password_matches?(password)
    BCrypt::Password.new(@password) == password
  end

  def role=(new_role)
    new_role = new_role.to_sym
    if ROLES.include? new_role
      @role = new_role
    else
      raise "Failed to assign role: #{new_role} is not a valid role!"
    end
  end

  def to_h
    to_hash
  end

  def to_hash # For Oj serialization
    {
      user: @name,
      role: @role,
      initial_password: @initial_password,
      password: @password.to_s # The hashed, salted password
    }
  end
end
