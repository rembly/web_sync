require 'active_support/all'
require 'awesome_print'
require 'pry'
require 'json'

# Read and write intro call occurrence data from data file
class IntroCallData
    FILE_PATH = File.join(File.dirname(__FILE__), '../../data/intro_call_data.json')

    # find the latest occurrence
    def self.get_latest_intro_call
        if(data = self.get_data)
            last_call = data.keys.find{|date| date.to_date < Date.today && date.to_date > (Date.today - 1.week)}
            last_call.present? ? data[last_call] : ''
        end
    end
    
    def self.set_intro_call_occurrence(date:, occurrence_id:)
        data = self.get_data
        data[date.to_s] = occurrence_id
        # only store 2 months of data
        data.delete_if{|date, id| date.to_date < (Date.today - 2.months)}
        File.open(FILE_PATH, 'w+') do |f|
            f.puts(data.to_json)
        end
    end

    def self.get_data
        return {} unless File.exists?(FILE_PATH)
        begin
            return JSON.parse(File.read(FILE_PATH))
        rescue JSON::ParserError
            return {}
        end
    end

end
