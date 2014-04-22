require 'singleton'

require_relative 'database.rb'

module Fitstats
    class Config
        include Singleton

        def [](key)
            Fitstats::Database.DB[:config][:key => key][:value]
        end
    end
end
