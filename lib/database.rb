require 'yaml'

module Fitstats
    class Database
        include Singleton

        OPTIONS = YAML.load_file("/etc/fitstats.rc")
        @DB = Sequel.connect("mysql2://#{OPTIONS['db_user']}:#{OPTIONS['db_password']}@#{OPTIONS['db_host']}/#{OPTIONS['db_name']}")

        def self.DB
            @DB
        end

        def user_for_obfuscator(obfuscator)
            db_user = DB[:user][:obfuscator => obfuscator]
            return nil if db_user.nil?

            User.new(
                db_user[:id],
                db_user[:fitbit_uid],
                db_user[:obfuscator],
                db_user[:fitbit_oauth_token],
                db_user[:fitbit_oauth_secret]
            )
        end
        
        def user_for_id(id)
            db_user = DB[:user][:id => id]
            return nil if db_user.nil?

            User.new(
                db_user[:id],
                db_user[:fitbit_uid],
                db_user[:obfuscator],
                db_user[:fitbit_oauth_token],
                db_user[:fitbit_oauth_secret]
            )
        end

        def create_new_user(fitbit_uid, obfuscator, user_token, user_secret)
            # TODO : implement the create user function
        end

        def update_user_auth(user)
            DB[:user].where(:id => @id).update(
                { :fitbit_oauth_token => user.fitbit_oauth_token, :fitbit_oauth_secret => user.fitbit_oauth_secret }
            )
        end

    end
end
