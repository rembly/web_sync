require 'json'
require 'active_support/all'
require 'pry'
require 'csv'

class BgovMerge
  LOG = Logger.new(File.join(File.dirname(__FILE__), '..', '..', 'log', 'bgov_merge.log'))
  BGOV_SHEET = File.join(File.dirname(__FILE__), '..', '..', 'data', 'BGOV_CitizensClimateLobby_2019Q1.csv').to_s
  SF_SHEET = File.join(File.dirname(__FILE__), '..', '..', 'data', 'legislators_with_ids.csv').to_s
  MERGE_SHEET = File.join(File.dirname(__FILE__), '..', '..', 'data', 'bgov_with_ids.csv').to_s
  
  def initialize

  end

  def merge_ids
    csv_settings = { encoding: "UTF-8", headers: true, header_converters: :symbol, converters: :all}
    with_ids = CSV.read(SF_SHEET, csv_settings)
    merged = []
    CSV.foreach(BGOV_SHEET) do |row|
      # write header
      merged << row && next if $. == 1
      # find id
      first, last, full, dist = row[1], row[2], row[0], row[5]
      senator = row[4] == 'US Senator'
      id_row = with_ids.find do |r| 
        (r[:first_name] == first && r[:last_name] == last) ||
          r[:full_name] == full || (r[:ccl_district] == dist) || (r[:last_name] == last && r[:ccl_district][0, 2] == dist[0, 2])
      end

      if(id_row)
        row[12] = '' unless senator
        row << id_row[:contact_id]
        merged << row
      else
        LOG.error("No rep found #{row}")
      end
    end

    CSV.open(MERGE_SHEET, 'w'){|csv| merged.each{|row| csv << row}}
  end

end