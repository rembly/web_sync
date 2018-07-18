require_relative 'salesforce_sync' 
require 'json'
require 'pry'
require 'csv'

class CclChapters
   FILE_LOCATION = File.join(File.dirname(__FILE__), '..', 'data', 'chapter_locations.geojson')
   MISSING_LOCATION_CSV = File.join(File.dirname(__FILE__), '..', 'data', 'missing_locations.csv')
   attr_accessor :sf

   def initialize
      @sf = SalesforceSync.new
   end

   def update_location_file
      File.write(FILE_LOCATION, chapter_location_file.to_json)
   end

   def chapter_location_file
      chapters = sf.ccl_chapter_locations
      valid_chapters = chapters.select(&method(:valid_chapter_loc?))
      features = valid_chapters.collect(&method(:chapter_feature))
      feature_map = {'type': 'FeatureCollection', 'features': features}
   end

   def chapter_feature(chapter)
      {
         'type': 'Feature',
         'geometry': chapter_geometry(chapter),
         'properties': chapter_properties(chapter)
      }
   end

   def chapter_geometry(chapter)
      {
         'type': 'Point',
         'coordinates': [chapter['MALongitude__c'].to_f, chapter['MALatitude__c'].to_f]
      }
   end

   CHAPTER_FIELDS = %w(Name Group_Description__c City__c State__c State_Province__c Country__c Creation_Stage__c
                        Group_Email__c Web_Chapter_Page__c)

   def chapter_properties(chapter)
      {
         'Name': chapter['Name'].to_s,
         'Description': chapter['Group_Description__c'].to_s,
         'City': chapter['City__c'].to_s,
         'State': chapter['State__c'].to_s, 
         'StateProvince': chapter['State_Province__c'].to_s,
         'Country': chapter['Country__c'].to_s, 
         'Stage': chapter['Creation_Stage__c'].to_s,
         'Email': chapter['Group_Email__c'].to_s,
         'Web': chapter['Web_Chapter_Page__c'].to_s
      }
   end 

   def valid_chapter_loc?(chapter)
      if chapter['MALatitude__c'].abs > 90 || chapter['MALongitude__c'].abs > 180
         p "INVALID LAT/LNG: #{chapter}"
         return false
      end
      true
   end

   def save_chapters_with_no_location
      chapters = sf.ccl_chapters
      missing_locations = chapters.select(&method(:us_chapter_missing_location?))
      if missing_locations.any?
         CSV.open(MISSING_LOCATION_CSV, 'w') do |csv|
            csv << %w(ID Name Country State City Zip StreetAddress, URL)
            missing_locations.each do |ch|
               csv << [ch['Id'], ch['Name'], ch['Country__c'], ch['State__c'], 
                        us_chapter_city(ch['City__c']), '', '',
                        "https://na51.salesforce.com/#{ch['Id']}"]
            end
         end
      end
   end

   private

   def us_chapter_city(city)
      city.to_s.split(/,|\//).first
   end

   def us_chapter_missing_location?(chapter)
      chapter['Country__c'] == 'USA' && 
         (chapter['MALatitude__c'].to_f.zero? || chapter['MALongitude__c'].to_f.zero?)
   end

end 