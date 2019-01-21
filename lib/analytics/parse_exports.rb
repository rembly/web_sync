require_relative '../salesforce_sync' 
require 'json'
require 'pry'
require 'csv'

class ParseExports
  FILE_LOCATION = File.join(File.dirname(__FILE__), '..', '..', 'data', 'state_data.json')
  MISSING_LOCATION_CSV = File.join(File.dirname(__FILE__), '..', '..', 'data', 'missing_locations.csv')
  CONSERVATIVES_PER_STATE_CSV = File.join(File.dirname(__FILE__), '..', '..', 'data', 'conservatives.csv')
  STATE_POPULATION = File.join(File.dirname(__FILE__), '..', '..', 'data', 'state_population.csv')
  STATE_CODES = File.join(File.dirname(__FILE__), '..', '..', 'data', 'state_codes.json')
  STATE_LOBBY_ATTENDEES = File.join(File.dirname(__FILE__), '..', '..', 'data', 'lobby_attendees_state.json')
  STATE_REGION_VOLUNTEERS = File.join(File.dirname(__FILE__), '..', '..', 'data', 'supporters_by_region_and_state.csv')
  attr_accessor :sf
  attr_accessor :state_codes

  def initialize
    @sf = SalesforceSync.new
    @state_codes = state_codes
  end

  def build_state_file
    pop = population_per_state
    conservatives = conservatives_per_state
    lobby = lobby_attendees
    volunteers = state_region_volunteers
    summarized = pop.each_with_object({}) do |(state, pop), map|
      cons = conservatives[state] || {}
      vol = volunteers[state] || {}
      map[state] = cons.merge({pop: pop.to_i, lobby: lobby[state].to_i, 
        volunteer_count: vol[:volunteer_count].to_i, region: vol[:region].to_s})
      map
    end

    File.open(FILE_LOCATION, 'w'){|f| f.write(summarized.to_json)}
    # summarized
  end

  def state_region_volunteers
    file = CSV.read(STATE_REGION_VOLUNTEERS)
    by_state = file.group_by{|r| r[2]}
    summary = by_state.each_with_object({}) do |(state, data), map|
      if state_codes.values.include?(state)
        map[state] = {}
        map[state][:volunteer_count] = data.size
        map[state][:region] = data.first[1]
        map
      end
    end
    summary
  end

  def state_codes
    JSON.parse(File.read(STATE_CODES))
  end

  def population_per_state
    state_population = CSV.read(STATE_POPULATION)
    state_population.each_with_object({}){|row, map| map[state_codes[row[0]]] = row[1]; map}
  end

  def lobby_attendees
    JSON.parse(File.read(STATE_LOBBY_ATTENDEES)).each_with_object({}){|(state, count), map| map[state_codes[state]] = count; map}
  end

  def conservatives_per_state
    ccl_score = 2
    state_code = 3
    summarized = {}
    data = CSV.read(CONSERVATIVES_PER_STATE_CSV)
    data.group_by{|row| row[3]}.each_with_object(summarized) do |(state, rows), map|
      count = rows.size
      average_score = (rows.reduce(0.0){|sum, row| sum + row[2].to_s.to_d}) / count.to_d
      map[state] = {conservative_count: count, conservative_acivity_average: average_score.to_d.round(4)} if state
      map
    end

    # File.open(FILE_LOCATION, 'w'){|f| f.write(summarized.to_json)}
  end



end
