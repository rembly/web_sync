require_relative '../salesforce_sync' 
require 'json'
require 'pry'
require 'csv'

class ParseChapterLoc
  ALL_CHAPTERS = File.join(File.dirname(__FILE__), '..', '..', 'data', 'all_ccl_chapters.csv')
  CHAPTER_MAP_LOC = File.join(File.dirname(__FILE__), '..', '..', 'data', 'chapter_map_lo_coded.csv')
  CHAPTER_LOC_WITTH_IDS = File.join(File.dirname(__FILE__), '..', '..', 'data', 'chapter_loc_with_ids.csv')

  attr_accessor :sf
  attr_accessor :state_codes

  def initialize
    # @sf = SalesforceSync.new
  end

  def merge_chapter_loc_data
    all_chapters = CSV.readlines(ALL_CHAPTERS)
    chapters_by_name = all_chapters.group_by{|ch| ch[1].to_s.strip.downcase}

    chapter_locs = CSV.readlines(CHAPTER_MAP_LOC)

    merged = []

    chapter_locs.each do |chapter_row|
      chapter_name = chapter_row[2].to_s.strip.downcase
      sf_chapter = chapters_by_name[chapter_name]&.first

      if sf_chapter
        new_row = get_update_row(sf_chapter, chapter_row)
        merged << new_row if new_row
      end
    end

    CSV.open(CHAPTER_LOC_WITTH_IDS, 'w'){|csv| merged.each{|row| csv << row}}
  end

  # [ID, Lat, Lon, zip ]
  def get_update_row(sf_ch, ch_loc)
    sf_id = sf_ch[0]
    new_state_cd = ch_loc[13].to_s
    new_city = ch_loc[12].to_s
    new_zip = ch_loc[14].to_s
    current_lat = sf_ch[7].to_s
    current_lon = sf_ch[8].to_s
    current_state_cd = sf_ch[4].to_s
    current_state = sf_ch[3].to_s
    current_city = sf_ch[2].to_s
    current_zip = sf_ch[5].to_s

    new_row = [ sf_id, current_lat, current_lon, current_zip ]

    # if no current loc set it
    city_state_same = current_city.strip.downcase == new_city.strip.downcase && current_state_cd.strip.downcase == new_state_cd.strip.downcase
    
    if (current_lat.empty? && current_lon.empty?) || city_state_same
      new_row[1] = ch_loc[1]
      new_row[2] = ch_loc[0]

      if city_state_same && (new_zip != current_zip)
        new_row[3] = new_zip
      end

      return new_row
    end

    return nil
  end
end
