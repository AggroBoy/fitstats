require 'yaml'

module Fitstats
    class Database
        include Singleton

        OPTIONS = YAML.load_file("/etc/fitstats.rc")

        def initialize
            @DB = Sequel.connect("mysql2://#{OPTIONS['db_user']}:#{OPTIONS['db_password']}@#{OPTIONS['db_host']}/#{OPTIONS['db_name']}")
            @users = Array.new
        end

        def db
            @DB
        end

        def user_for_db_user(db_user)
            User.new(
                db_user[:id].to_s,
                db_user[:fitbit_uid],
                db_user[:obfuscator],
                db_user[:fitbit_oauth_token],
                db_user[:fitbit_oauth_secret]
            )
        end

        def user_for_obfuscator(obfuscator)
            i = @users.index { |u| u.obfuscator == obfuscator }
            return @users[i] if not i.nil?

            db_user = @DB[:user][:obfuscator => obfuscator]
            return nil if db_user.nil?

            user = user_for_db_user(db_user)
            @users.push user
            return user
        end
        
        def user_for_fitbit_uid(fitbit_uid)
            i = @users.index { |u| u.fitbit_uid == fitbit_uid }
            return @users[i] if not i.nil?

            db_user = @DB[:user][:fitbit_uid => fitbit_uid]
            return nil if db_user.nil?

            user = user_for_db_user(db_user)
            @users.push user
            return user
        end

        def user_for_id(id)
            i = @users.index {|u| u.db_id == id }
            return @users[i] if not i.nil?

            db_user = @DB[:user][:id => id]
            return nil if db_user.nil?

            user = user_for_db_user(db_user)
            @users.push user
            return user
        end

        def create_new_user(fitbit_uid, obfuscator, user_token, user_secret)
            @DB[:user].insert({:fitbit_uid => fitbit_uid, :obfuscator => obfuscator, :fitbit_oauth_token => user_token, :fitbit_oauth_secret => user_secret })
        end

        def update_user_auth(fitbit_uid, token, secret)
            @DB[:user].where(:fitbit_uid => fitbit_uid).update(
                { :fitbit_oauth_token => token, :fitbit_oauth_secret => secret }
            )
        end

        def user_exists?(fitbit_uid)
            @DB[:user].where(:fitbit_uid => fitbit_uid).count > 0
        end

        def purge_cache(fitbit_uid)
            @users.delete_if { |user| user.fitbit_uid == fitbit_uid }
        end
    end
end
