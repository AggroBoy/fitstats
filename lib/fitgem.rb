require 'fitgem'

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
            raise result.value() if @raise_on_error and !result.is_a?(Net::HTTPSuccess)
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
