require 'yaml'

module Fitstats
    class Database
        include Singleton

        OPTIONS = YAML.load_file("/etc/fitstats.rc")
        @DB = Sequel.connect("mysql2://#{OPTIONS['db_user']}:#{OPTIONS['db_password']}@#{OPTIONS['db_host']}/#{OPTIONS['db_name']}")

        def self.DB
            @DB
        end
    end
end
