require 'mysql2'
require 'json'
require 'yaml'
require 'active_support/all'

# return mysql connection
class MysqlConnection
   DATABASE_CONFIG = YAML.load_file(File.join(File.dirname(__FILE__), '..', '..', 'config', 'database.yml'))

   def self.get_connection
      Mysql2::Client.new(DATABASE_CONFIG[ENV['ENVIRONMENT'].to_s])
   end
end
