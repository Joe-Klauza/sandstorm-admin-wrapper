require 'bcrypt'
require 'sysrandom'

class User
  attr_accessor :name
  attr_reader :role
  attr_reader :id
  attr_reader :initial_password

  ROLES = {
    host: 3,
    admin: 2,
    user: 1
  }

  def initialize(name, role, password: nil, initial_password: nil, id: nil)
    @name = name # Name will also be our GUID, since having duplicate user names is confusing without emails
    @role = role
    @initial_password = initial_password
    @id = id || Sysrandom.uuid
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
    @initial_password = ConfigHandler.generate_password
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
end
