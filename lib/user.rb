require 'sequel'

require_relative 'database.rb'
require_relative 'fitgem.rb'

PI_FREQUENCY = 360

module Fitstats
    class User

        attr_accessor :fitbit_uid
        attr_accessor :id

        @@DB = Fitstats::Database.DB

        def self.for_obfuscator(obfuscator)
            db_user = @@DB[:user][:obfuscator => obfuscator]
            return nil if db_user.nil?

            User.new(
                db_user[:id],
                db_user[:fitbit_uid],
                db_user[:obfuscator],
                db_user[:fitbit_oauth_token],
                db_user[:fitbit_oauth_secret]
            )
        end
        
        def self.for_id(id)
            db_user = @@DB[:user][:id => id]
            return nil if db_user.nil?

            User.new(
                db_user[:id],
                db_user[:fitbit_uid],
                db_user[:obfuscator],
                db_user[:fitbit_oauth_token],
                db_user[:fitbit_oauth_secret]
            )
        end

        def self.create_new(fitbit_uid, obfuscator, user_token, user_secret)
            # TODO : implement the create user function
        end

        def initialize(id, fitbit_uid, obfuscator, user_token, user_secret)
            @id = id
            @fitbit_uid = fitbit_uid
            @user_token = user_token
            @user_secret = user_secret
            @obfuscator = obfuscator

        end

        def update_auth(token, secret)
            @user_token = token
            @user_secret = secret

            @@DB[:user].where(:id => @id).update(
                { :fitbit_oauth_token => token, :fitbit_oauth_secret => secret }
            )
        end

        def fitbit
            Fitgem::Client.new ({
                :consumer_key => CONSUMER_KEY,
                :consumer_secret => CONSUMER_SECRET,
                :token => @user_token,
                :secret => @user_secret,
                :unit_system => Fitgem::ApiUnitSystem.METRIC,
                :raise_on_error => true
            })
        end

        def refresh_personal_info
            if @personal_info.nil? or @pi_timestamp.nil? or (Time.now - @pi_timestamp).to_i > PI_FREQUENCY
                puts "Refreshing personal info for #{@fitbit_uid}."
                @pi_timestamp = Time.now
                begin
                    @personal_info = fitbit.user_info["user"]
                rescue => e
                    puts e
                end
            end
        end

        def name
            refresh_personal_info
            @personal_info["displayName"]
        end

        def height
            refresh_personal_info
            @personal_info["height"]
        end

        def weight
            refresh_personal_info
            @personal_info["weight"]
        end

        def birth_date
            refresh_personal_info
            @personal_info["dateOfBirth"]
        end

        def sex
            refresh_personal_info
            @personal_info["gender"]
        end

        def bmr
            age = ((Date.today - Date.parse(birth_date)).to_i / 365.25).to_f

            if sex == 'MALE'
                # 88.362 + (13.397 * @user[:weight]) + (4.799 * @user[:height]) - (5.677 * age)
                (9.99 * weight.to_f) + (6.25 * height.to_f) - (4.92 * age) + 5
            else
                # 447.593 + (9.247 * @user[:weight]) + (3.098 * @user[:height]) - (4.330 * age)
                (9.99 * weight.to_f) + (6.25 * height.to_i) - (4.92 * age) - 161
            end
        end
    end
end

