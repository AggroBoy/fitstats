require 'sinatra'
require 'omniauth-fitbit'
require 'dalli'
require 'securerandom'
require 'sequel'
require 'yaml'
require 'celluloid/autostart'
require 'securerandom'
require 'erubis'

require_relative 'lib/user.rb'
require_relative 'lib/database.rb'
require_relative 'lib/config.rb'
require_relative 'lib/fitgem.rb'

# TODO: LOCALIZATION
# Specifically timezones:
#   - time calculations need to work based on user's local time rather than UTC
#   - date ranges need to be based on user's local date, not the date in Grenwich

INTENSITIES = {
    "EASY" => 250,
    "MEDIUM" => 500,
    "KINDAHARD" => 750,
    "HARDER" => 1000
}

ALLOWED_SPANS = [ "1d", "1w", "1m", "3m", "6m", "1y" ]
# Other potentials: 7d, 30d

DB = Fitstats::Database.DB
CONFIG = Fitstats::Config.instance

CONSUMER_KEY = CONFIG["fitbit_consumer_key"]
CONSUMER_SECRET = CONFIG["fitbit_consumer_secret"]

set :bind => CONFIG["bind_address"]

use Rack::Session::Cookie, :secret => CONFIG["session_secret"], :expire_after => 2592000
use OmniAuth::Builder do
    provider :fitbit, CONSUMER_KEY, CONSUMER_SECRET
end


CACHE = Dalli::Client.new('127.0.0.1:11211', {:namespace => "fitstats_v0.1", :compress => "true", :expires_in => 1200})

get "/" do
    @user = Fitstats::Database.instance.user_for_fitbit_uid(session[:uid])
    if @user then
        erb :index
    else
        erb :login
    end

end


before '/stats/:obfuscator/*' do
    @user = Fitstats::Database.instance.user_for_obfuscator(params[:obfuscator])
    halt 404 if !@user
end

before '/stats/:obfuscator/*/:span' do
    halt 404 if !ALLOWED_SPANS.include?(params[:span])
end

get "/stats/:obfuscator/weight" do
    weight_chart("1y")
end
get "/stats/:obfuscator/weight/:span" do
    weight_chart(params[:span])
end

def format_time(time, time_span)
    ["1d", "7d", "1w"].include?(time_span) ? Time.parse(time).strftime("%a") : time_span
end

def invalidate_request_cache(user_id, chart)
    cache_key = "user#{user_id}_#{chart}"
    CACHE.delete(cache_key)
    for span in ALLOWED_SPANS do
        CACHE.delete(cache_key + "_" + span)
    end
end

def simple_sequence_chart(title, series, time_span)
    create_graph(title, {"fitbit" => prepare_series(series, time_span)}, 60)
end

def extrapolate_todays_calories(current)
    now = Time.now
    mins_elapsed = now.min + (now.hour * 60)

    bmr_per_min = @user.bmr.to_f / 1440.0
    mins_remaining = 1440 - mins_elapsed

    (current + (mins_remaining * bmr_per_min)).to_i
end

def calorie_chart(time_span)

        cals_in = @user.calories_in_series.select { |item| Date.parse(item["dateTime"]) > cutoff_date_for_span(time_span)}
        cals_out = @user.calories_out_series.select { |item| Date.parse(item["dateTime"]) > cutoff_date_for_span(time_span)}
        deficit = @user.calorie_deficit_goal

        datapoints = Array.new
        for i in 0 .. (cals_in.size - 1)
            date = cals_in[i]["dateTime"]

            daily_out = cals_out[i]["value"].to_i
            target = (Date.parse(date) == Date.today ? extrapolate_todays_calories(daily_out) : daily_out) - deficit

            datapoints.push({
                "title" => format_time(date, time_span),
                "value" => cals_in[i]["value"].to_i - target
            })
        end

        create_graph("calories", {"food" => datapoints}, 60)
end

def weight_chart(time_span)
    weight_series = prepare_series(@user.weight_series,  time_span)
    weight_goal = @user.body_weight_goal

    create_graph("Weight", {"weight" => weight_series}, 60, (weight_goal.to_f * 0.9).to_s, nil, "kg")
end

def create_graph(title, sequences, refresh_interval, y_min = nil, y_max = nil, y_unit = nil)
    graph = {
        "graph" => {
            "title" => title,
            "refreshEveryNSeconds" => refresh_interval,
            "datasequences" => sequences.keys.map {|sequence_title|
                {
                    "title" => sequence_title,
                    "datapoints" => sequences[sequence_title]
                }
            }
        }
    }
    
    if (y_min || y_max || y_unit) then
        y = {}
        y["minValue"] = y_min if y_min
        y["maxValue"] = y_max if y_max
        y["units"] = {"suffix" => y_unit} if y_unit

        graph["graph"]["yAxis"] = y
    end

    MultiJson.encode( graph )
end

def cutoff_date_for_span(time_span)
    case time_span
    when "1d"
        return Date.today - 1
    when "1w"
        return Date.today - 7
    when "1m"
        return Date.today << 1
    when "3m"
        return Date.today << 3
    when "6m"
        return Date.today << 6
    when "1y"
        return Date.today << 12
    end

    Date.today - 7
end

def prepare_series(series, time_span)
    datapoints = Array.new
    series.select{ |item|
        Date.parse(item["dateTime"]) > cutoff_date_for_span(time_span)
    }.each { |item|
        datapoints.push( {
            "title" => format_time(item["dateTime"], time_span),
            "value" => item["value"]
        } )
    }
    datapoints
end

get "/stats/:obfuscator/steps" do
    simple_sequence_chart("Steps", @user.steps_series, "7d")
end
get "/stats/:obfuscator/steps/:span" do
    simple_sequence_chart("Steps", @user.steps_series, params[:span])
end

get "/stats/:obfuscator/floors" do
    simple_sequence_chart("Floors", @user.floors_series, "7d")
end
get "/stats/:obfuscator/floors/:span" do
    simple_sequence_chart("Floors", @user.floors_series, "7d")
end

get "/stats/:obfuscator/calories" do
    calorie_chart("7d")
end
get "/stats/:obfuscator/calories/:span" do
    calorie_chart(params[:span])
end

post "/api/subscriber-endpoint" do
    status 204
    for update in MultiJson.load(params['updates'][:tempfile].read) do
        case update["collectionType"]
        when "activities" 
            #invalidate_request_cache(update["subscriptionId"], "steps")
            #invalidate_request_cache(update["subscriptionId"], "floors")
            #invalidate_request_cache(update["subscriptionId"], "calories")
        when "foods"
            #invalidate_request_cache(update["subscriptionId"], "calories")
        when "body"
            #invalidate_request_cache(update["subscriptionId"], "weight")
        end
    end
end

get "/auth/fitbit/callback" do

    auth = request.env['omniauth.auth']
    fitbit_id = auth["uid"]
    token = auth["credentials"]["token"]
    secret = auth["credentials"]["secret"]
        
    @user = Database.user_for_fitbit_uid(fitbit_id) or 

    if (user.nil?)
        @user = Database.create_new_user(fitbit_id, SecureRandom.urlsafe_base64(64), token, secret)
    else
        Database.update_user_auth(@user)
    end

    session[:uid] = fitbit_id
    refresh_subscriptions

    redirect to('/')
end

# handle oauth failure
get '/auth/failure' do
    params[:message]
end

get '/stats/:obfuscator/subscription' do
    @user.subscriptions
end

def create_subscription
    @user.create_subscription
end

def delete_subscription
    @user.delete_subscription
end

def refresh_subscription
    delete_subscription
    add_subscription
end

get '/stats/:obfuscator/refresh-subscription' do
    refresh_subscriptions

    redirect to ("stats/#{@user.obfuscator}/subscription")
end

get '/stats/:obfuscator/test' do
    halt 500
end

