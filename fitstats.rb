require 'sinatra'
require 'omniauth-fitbit'
require 'fitgem'
require 'dalli'
require 'securerandom'
require 'sequel'
require 'yaml'
require 'celluloid/autostart'
require 'securerandom'
require 'erubis'

INTENSITIES = {
    "EASY" => 250,
    "MEDIUM" => 500,
    "KINDAHARD" => 750,
    "HARDER" => 1000
}

ALLOWED_SPANS = [ "1d", "1w", "1m", "3m", "6m", "1y" ]
# Other potentials: 7d, 30d

OPTIONS = YAML.load_file("/etc/fitstats.rc")
DB = Sequel.connect("mysql2://#{OPTIONS['db_user']}:#{OPTIONS['db_password']}@#{OPTIONS['db_host']}/#{OPTIONS['db_name']}")

def config(key)
    DB[:config][:key => key][:value]
end

CONSUMER_KEY = config("fitbit_consumer_key")
CONSUMER_SECRET = config("fitbit_consumer_secret")

set :bind => config("bind_address")

use Rack::Session::Cookie, :secret => config("session_secret"), :expire_after => 2592000
use OmniAuth::Builder do
    provider :fitbit, CONSUMER_KEY, CONSUMER_SECRET
end


CACHE = Dalli::Client.new('127.0.0.1:11211', {:namespace => "fitstats_v0.1", :compress => "true", :expires_in => 1200})


# Monkey-patch some useful stuff into fitgem
module Fitgem
    class Client
        def initialize(opts)
            missing = [:consumer_key, :consumer_secret] - opts.keys
            if missing.size > 0
                raise Fitgem::InvalidArgumentError, "Missing required options: #{missing.join(',')}"
            end
            @consumer_key = opts[:consumer_key]
            @consumer_secret = opts[:consumer_secret]

            @ssl = opts[:ssl]

            @token = opts[:token]
            @secret = opts[:secret]

            @proxy = opts[:proxy] if opts[:proxy]
            @user_id = opts[:user_id] || '-'

            @raise_on_error = opts[:raise_on_error] if opts[:raise_on_error]

            @api_unit_system = opts[:unit_system] || Fitgem::ApiUnitSystem.US
            @api_version = API_VERSION
        end

        def get(path, headers={})
            result = raw_get(path, headers)
            raise result if @raise_on_error and !result.is_a?(Net::HTTPSuccess)
            extract_response_body result
        end

        # Get details about the daily food (calorie) goal
        #
        # @return [Hash] Food goal information.
        def daily_food_goal
            get("/user/#{@user_id}/foods/log/goal.json")
        end
    end
end

get "/" do
    @user = DB[:user][:fitbit_uid => session[:uid]]
    if @user then
        erb :index
    else
        erb :login
    end

end


def fitbit_client()
    Fitgem::Client.new ({
        :consumer_key => CONSUMER_KEY,
        :consumer_secret => CONSUMER_SECRET,
        :token => @user[:fitbit_oauth_token],
        :secret => @user[:fitbit_oauth_secret],
        :unit_system => Fitgem::ApiUnitSystem.METRIC,
        :raise_on_error => true
    })
end


before '/stats/:obfuscator/*' do
    @user = DB[:user][:obfuscator => params[:obfuscator]]
    halt 404 if !@user
end

before '/stats/:obfuscator/*/:span' do
    halt 404 if !ALLOWED_SPANS.include?(params[:span])
end

before "/stats/:obfuscator/:chart/:span" do
    @cache_key = "user#{@user[:id]}_#{params[:chart]}_#{params[:span]}"
end
before "/stats/:obfuscator/:chart" do
    @cache_key = "user#{@user[:id]}_#{params[:chart]}"
end

get "/stats/:obfuscator/weight" do
    weight_chart("1y")
end
get "/stats/:obfuscator/weight/:span" do
    weight_chart(params[:span])
end

def format_time(time, time_span)
    ["1d", "7d", "1w"].include?(time_span) ? Time.parse(time).strftime("%a") : time
end

def invalidate_request_cache(user_id, chart)
    cache_key = "user#{user_id}_#{chart}"
    CACHE.delete(cache_key)
    for span in ALLOWED_SPANS do
        CACHE.delete(cache_key + "_" + span)
    end
end

def simple_sequence_chart(resource, title, time_span)
    fitbit = fitbit_client()

    CACHE.fetch(@cache_key) {
        steps = resiliant_request { fitbit.data_by_time_range(resource, {:base_date => "today", :period => time_span}).values[0] }

        datapoints = Array.new
        steps.each { |item|
            datapoints.push( {
                "title" => format_time(item["dateTime"], time_span),
                "value" => item["value"]
            } )
        }

        create_graph(title, {"fitbit" => datapoints}, 60)
    }
end

def calorie_chart(time_span)
    CACHE.fetch(@cache_key) {

        # Use futures to parallelize http requests
        cals_in_future = Celluloid::Future.new {
            resiliant_request("in") { fitbit_client().data_by_time_range("/foods/log/caloriesIn", {:base_date => "today", :period => time_span}).values[0] }
        }
        cals_out_future = Celluloid::Future.new {
            resiliant_request("out") { fitbit_client().data_by_time_range("/activities/tracker/calories", {:base_date => "today", :period => time_span}).values[0] }
        }
        deficit_future = Celluloid::Future.new {
            resiliant_request("deficit") { INTENSITIES[fitbit_client().daily_food_goal.values[0]["intensity"]] }
        }

        cals_in = cals_in_future.value
        cals_out = cals_out_future.value
        deficit = deficit_future.value

        datapoints = Array.new
        for i in 0 .. (cals_in.size - 1)
            date = cals_in[i]["dateTime"]

            target = (Date.parse(date) == Date.today ? bmr() : cals_out[i]["value"]).to_i - deficit

            datapoints.push({
                "title" => format_time(date, time_span),
                "value" => cals_in[i]["value"].to_i - target
            })
        end

        create_graph("calories", {"food" => datapoints}, 60)
    }
end

def weight_chart(time_span)
    CACHE.fetch(@cache_key, 10800) {

        weight_future = Celluloid::Future.new {
           resiliant_request("weight") { fitbit_client().data_by_time_range("/body/weight", {:base_date => "today", :period => time_span}).values[0] }
        }
        weight_goal_future = Celluloid::Future.new {
            resiliant_request("goal") { fitbit_client().body_weight_goal["goal"]["weight"] }
        }

        weight = weight_future.value
        weight_goal = weight_goal_future.value

        datapoints = Array.new
        weight.each { |item|
            datapoints.push( { "title" => item["dateTime"], "value" => item["value"] } )
        }

        create_graph("Weight", {"weight" => datapoints}, 60, (weight_goal.to_f * 0.9).to_s, nil, "kg")
    }
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

def resiliant_request(request_name = nil)
    begin
        key = @cache_key + (request_name ? "_" + request_name : "") + "_request"
        new = yield
        CACHE.set(key, new, 86400)
        new
    rescue => e
        e.backtrace
        CACHE.get(key) or raise
    end
end

get "/stats/:obfuscator/steps" do
    simple_sequence_chart("/activities/tracker/steps", "steps", "7d")
end
get "/stats/:obfuscator/steps/:span" do
    simple_sequence_chart("/activities/tracker/steps", "steps", params[:span])
end

get "/stats/:obfuscator/floors" do
    simple_sequence_chart("/activities/tracker/floors", "floors", "7d")
end
get "/stats/:obfuscator/floors/:span" do
    simple_sequence_chart("/activities/tracker/floors", "floors", params[:span])
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
            invalidate_request_cache(update["subscriptionId"], "steps")
            invalidate_request_cache(update["subscriptionId"], "floors")
            invalidate_request_cache(update["subscriptionId"], "calories")
        when "foods"
            invalidate_request_cache(update["subscriptionId"], "calories")
        when "body"
            invalidate_request_cache(update["subscriptionId"], "weight")
        end
    end
end

get "/auth/fitbit/callback" do
    auth = request.env['omniauth.auth']
    name = auth["info"]["display_name"]
    fitbit_id = auth["uid"]
    token = auth["credentials"]["token"]
    secret = auth["credentials"]["secret"]


    users = DB[:user]
    @user = users[:fitbit_uid => fitbit_id]

    if @user
        @user.update( { :fitbit_oauth_token => token, :fitbit_oauth_secret => secret } )
    else
        users.insert({ :name => name, :fitbit_uid => fitbit_id, :fitbit_oauth_token => token, :fitbit_oauth_secret => secret, :obfuscator => SecureRandom.urlsafe_base64(64) })
    end
    session[:uid] = fitbit_id
    #TODO: store personal data for later BMR calc.
    
    refresh_subscription

    redirect to('/')
end

# handle auath failure
get '/auth/failure' do
    params[:message]
end


def refresh_personal_info
    if (Date.today - @user[:personal_data_last_updated]).to_i > 28
        #TODO: update personal data in DB
    end
end

def bmr
    refresh_personal_info()

    weight = 140
    age = (Date.today - @user[:birth_date]).to_i / 365.25

    if @user[:sex] == 'M'
        1.2 * (88.362 + (13.397 * weight) + (4.799 * @user[:height]) - (5.677 * age))
    else
        1.2 * (447.593 + (9.247 * weight) + (3.098 * @user[:height]) - (4.330 * age))
    end
end

get '/stats/:obfuscator/subscription' do
    fitbit_client().subscriptions({:type => :all})
end

def add_subscription
    fitbit.create_subscription({:type => :all, :subscription_id => @user[:id]})
end

def delete_subscription
    fitbit = fitbit_client()
    for subscription in fitbit.subscriptions({:type => :all}).values[0] do
        fitbit.remove_subscription({:type => :all, :subscription_id => subscription["subscriptionId"]})
    end
end

def refresh_subscription
    delete_subscription
    add_subscription
end

get '/stats/:obfuscator/refresh-subscription' do
    refresh_subscriptions

    redirect to ("stats/#{@user[:obfuscator]}/subscription")
end

