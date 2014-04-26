require 'sequel'
require 'celluloid'

require_relative 'database.rb'
require_relative 'fitgem.rb'

INFO_FREQUENCY = 3600
SERIES_FREQUENCY = 1800
GOAL_FREQUENCY = 86400

INTENSITIES = {
    "EASY" => 250,
    "MEDIUM" => 500,
    "KINDAHARD" => 750,
    "HARDER" => 1000
}

module Fitstats
    class User

        attr_reader :fitbit_uid
        attr_reader :id
        attr_reader :obfuscator

        attr_reader :steps_series
        attr_reader :floors_series
        attr_reader :weight_series
        attr_reader :calories_in_series
        attr_reader :calories_out_series
        attr_reader :body_weight_goal
        attr_reader :calorie_deficit_goal

        attr_accessor :user_token
        attr_accessor :user_secret

        def initialize(id, fitbit_uid, obfuscator, user_token, user_secret)
            @id = id
            @fitbit_uid = fitbit_uid
            @user_token = user_token
            @user_secret = user_secret
            @obfuscator = obfuscator

            refresh_fitbit_data
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

        def invalidate_pi_cache
            @pi_timestamp = nil
        end

        def name
            @personal_info["displayName"]
        end

        def height
            @personal_info["height"]
        end

        def weight
            @personal_info["weight"]
        end

        def birth_date
            @personal_info["dateOfBirth"]
        end

        def sex
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


        def invalidate_ws_cache
            @ws_timestamp = nil
        end

        def invalidate_ss_cache
            @ss_timestamp = nil
        end

        def invalidate_fs_cache
            @fs_timestamp = nil
        end

        def invalidate_cis_cache
            @cis_timestamp = nil
        end

        def invalidate_cos_cache
            @cos_timestamp = nil
        end

        def invalidate_cdg_cache
            @cdg_timestamp = nil
        end

        def invalidate_bwg_cache
            @bwg_timestamp = nil
        end

        def refresh_fitbit_data
            futures = []

            if @personal_info.nil? or @pi_timestamp.nil? or (Time.now - @pi_timestamp).to_i > INFO_FREQUENCY
                puts "Refreshing personal info for #{@fitbit_uid}."
                futures.push Celluloid::Future.new {
                    @personal_info = CACHE.fetch("bwaaa-pi") { fitbit.user_info["user"] }
                    @pi_timestamp = Time.now
                }
            end

            if (@calories_out_series.nil? or @cos_timestamp.nil? or (Time.now - @cos_timestamp).to_i > SERIES_FREQUENCY)
                puts "Refreshing calories out for #{@fitbit_uid}."
                futures.push Celluloid::Future.new {
                    @calories_out_series = CACHE.fetch("bwaaa-cos") { parse_series(
                        fitbit.data_by_time_range("/activities/tracker/calories", {:base_date => "today", :period => "1y"}).values[0]
                    )}
                    @cos_timestamp = Time.now
                }
            end

            if (@steps_series.nil? or @ss_timestamp.nil? or (Time.now - @ss_timestamp).to_i > SERIES_FREQUENCY)
                puts "Refreshing calories out for #{@fitbit_uid}."
                futures.push Celluloid::Future.new {
                    @steps_series = CACHE.fetch("bwaaa-ss") { parse_series(
                        fitbit.data_by_time_range("/activities/tracker/steps", {:base_date => "today", :period => "1y"}).values[0]
                    )}
                    @ss_timestamp = Time.now
                }
            end

            if (@floors_series.nil? or @fs_timestamp.nil? or (Time.now - @fs_timestamp).to_i > SERIES_FREQUENCY)
                puts "Refreshing calories out for #{@fitbit_uid}."
                futures.push Celluloid::Future.new {
                    @floors_series = CACHE.fetch("bwaaa-fs") { parse_series(
                        fitbit.data_by_time_range("/activities/tracker/floors", {:base_date => "today", :period => "1y"}).values[0]
                    )}
                    @fs_timestamp = Time.now
                }
            end

            if (@calories_in_series.nil? or @cis_timestamp.nil? or (Time.now - @cis_timestamp).to_i > SERIES_FREQUENCY)
                puts "Refreshing calories in for #{@fitbit_uid}."
                futures.push Celluloid::Future.new {
                    @calories_in_series = CACHE.fetch("bwaaa-cis") { parse_series(
                        fitbit.data_by_time_range("/foods/log/caloriesIn", {:base_date => "today", :period => "1y"}).values[0]
                    )}
                    @cis_timestamp = Time.now
                }
            end

            if (@weight_series.nil? or @ws_timestamp.nil? or (Time.now - @ws_timestamp).to_i > SERIES_FREQUENCY)
                puts "Refreshing weight for #{@fitbit_uid}."
                futures.push Celluloid::Future.new {
                    @weight_series = CACHE.fetch("bwaaa-ws") { parse_series(
                        fitbit.data_by_time_range("/body/weight", {:base_date => "today", :period => "1y"}).values[0]
                    )}
                    @ws_timestamp = Time.now
                }
            end

            if @body_weight_goal.nil? or @bwg_timestamp.nil? or (Time.now - @bwg_timestamp).to_i < GOAL_FREQUENCY
                puts "Refreshing weight goal for #{@fitbit_uid}."
                futures.push Celluloid::Future.new {
                    @body_weight_goal = CACHE.fetch("bwaaa-bwg") { fitbit.body_weight_goal["goal"]["weight"] }
                    @bwg_timestamp = Time.now
                }
            end

            if @calorie_deficit_goal.nil? or @cdg_timestamp.nil? or (Time.now - @cdg_timestamp).to_i < GOAL_FREQUENCY
                puts "Refreshing calorie deficit goal for #{@fitbit_uid}."
                futures.push Celluloid::Future.new {
                    @calorie_deficit_goal = CACHE.fetch("bwaaa-cdg") { INTENSITIES[fitbit.daily_food_goal.values[0]["intensity"]] }
                    @cdg_timestamp = Time.now
                }
            end

            #Wait for the futures to complete; we don't care about the value
            for future in futures
                future.value
            end
        end

        def parse_series(series)
            series
        end
    end
end

