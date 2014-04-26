require 'yaml'

module Fitstats
    class Database
        include Singleton

        OPTIONS = YAML.load_file("/etc/fitstats.rc")
        @DB = Sequel.connect("mysql2://#{OPTIONS['db_user']}:#{OPTIONS['db_password']}@#{OPTIONS['db_host']}/#{OPTIONS['db_name']}")

        def initialize
            @users = Array.new
        end

        def self.DB
            @DB
        end

        def user_for_db_user(db_user)
            User.new(
                db_user[:id],
                db_user[:fitbit_uid],
                db_user[:obfuscator],
                db_user[:fitbit_oauth_token],
                db_user[:fitbit_oauth_secret]
            )
        end

        def user_for_obfuscator(obfuscator)
            i = @users.index { |u| u.obfuscator == obfuscator }
            return @users[i] if not i.nil?

            db_user = DB[:user][:obfuscator => obfuscator]
            return nil if db_user.nil?

            user = user_for_db_user(db_user)
            @users.push user
            return user
        end
        
        def user_for_fitbit_uid(fitbit_uid)
            i = @users.index { |u| u.fitbit_uid == fitbit_uid }
            return @users[i] if not i.nil?

            db_user = DB[:user][:fitbit_uid => fitbit_uid]
            return nil if db_user.nil?

            user = user_for_db_user(db_user)
            @users.push user
            return user
        end

        def user_for_id(id)
            i = @users.index {|u| u.id == id }
            return @users[i] if not i.nil?

            db_user = DB[:user][:id => id]
            return nil if db_user.nil?

            user = user_for_db_user(db_user)
            @users.push user
            return user
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
