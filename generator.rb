require "json"
require "securerandom"
require "yaml"

require_relative "lib/scenario"
require_relative "lib/source_ingestion_scenario"

# TODO:
# * [ ] Generate one scenario per source that writes to S3
# * [ ] One scenario read from S3 and publish to API, Telegram, HTML page, etc

raise "Need to provide a source file" if ARGV.length == 0

ARGV.each do |source_file|
  # raise "output all to same directory, easier to spot what changed and needs to be applied"
  source = YAML.load(File.read(source_file))
  json = JSON.pretty_generate(SourceIngestionScenario.build(source).as_json)
  output_file = source_file.gsub("yml", "json").gsub("/", "-").gsub(/^sources-/, "")
  output_path = "./output/#{output_file}"

  puts "Writing to #{output_path}"
  File.write(output_path, json)
end
