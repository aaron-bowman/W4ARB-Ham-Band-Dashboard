#!/usr/bin/ruby
require 'yaml'
require 'logger'
require 'sqlite3'
require 'active_support/all'
require 'fileutils'

# Initiation
@config  = YAML.load_file('config.yml')
@log     = Logger.new(STDOUT)
@time    = Time.now
tmp_dir  = FileUtils.mkdir_p 'tmp'
log_dir  = FileUtils.mkdir_p 'logs'
web_dir  = FileUtils.mkdir_p 'web'
css_dir  = FileUtils.mkdir_p 'web/css'

if @config['log_debug']
  @log.level = Logger::DEBUG
else
  @log.level = Logger::INFO
end

# Since SQLite is file driven, we can just delete the db file rather than worry about purging all the data
File.delete @config['db'] if File.exists? @config['db']
# Create the database file and open it
@db = SQLite3::Database.open @config['db']
# Run the DDL to set up the tables
@config['sql_create'].each do |name, query|
  @log.debug("#{name}: #{query}")
  @db.execute(query)
end

# Defining the Method to Run Queries
def run_query(action, table, params)
  query = @config["#{action}"]["#{table}"]
  
  unless params.nil?
    params.each do |key, value|
      query = query.gsub("<#{key}>","#{value}")
    end
  end

  @log.debug "Running Query: #{query}"
  begin
    result = @db.execute(query)
  rescue => error
    @log.error "Query Failed with the Following Error: #{error}"
    @log.error "Exiting..."
    exit 1
  end

  return result
end

######################################################################
##### Step 1: Get spots from PSKReporter and save them in the DB #####
######################################################################
@log.info "Getting PSKReporter Spots From URL: #{@config['pskreporter_url']}"

# Use "curl" to call URL and output the XML into a temporary file
system("curl #{@config['pskreporter_url']} > tmp/spots.tmp")

# Exit if the "curl" command was not successful
unless $?.success?
  @log.error "Error Getting PSKREporter Spots. Exited with exit code: #{$?.exitstatus}"
  exit 1
end

# Read the XML file into a hash and filter down to an array of reception reports only
spots = Hash.from_xml File.open("tmp/spots.tmp").read
spots = spots['receptionReports']['receptionReport']
@log.info "Spot Count: #{spots.count}"

# Make sure each "master" 2 character grid has one record in the table
@config['master_grids'].each do |grid_name, grid_code|
  # Get a count by grid code
  count = run_query('sql_count', 'spot_masters', {'master_grid_code': grid_code})

  if count.join.to_i < 1
    # If count < 1, insert a new row
    run_query('sql_insert', 'spot_masters', {'master_grid_code': grid_code,
                                             'master_grid_name': grid_name,
                                             'update_time':      @time
                                            })
  elsif count.join.to_i == 1
    # If count = 1, update the existing row
    run_query('sql_update', 'spot_masters', {'update_time': @time})
  else
    # If there are duplicates, fail the job
    @log.error "Duplicate master grids in spot_masters. Verify config. Exiting..."
    exit 1
  end
end

# Create an array of grids configured to check against later
valid_grids = []
@config['master_grids'].each do |grid_name, grid_code|
  valid_grids << grid_code
end

# Load the spot data
loaded_spot_count = 0

spots.each do |spot|
  @log.debug spot

  # Skip if either of the key fields are nil
  next if spot['senderLocator'].nil?
  next if spot['receiverLocator'].nil?
  # Skip if neither the sender or receiver are located in one of the configured grids
  next unless ([spot['senderLocator'][0,2],spot['receiverLocator'][0,2]] & valid_grids).any?

  # Inject a band key to the spot hash as nil
  spot['band'] = nil

  # Populate the band based on the frequency compared to band ranges in config
  @config['bands'].each do |band_name, band_range|
    if band_range.include? spot['frequency'].to_i
      spot['band'] = band_name.to_i
      @log.debug "Spot Band Set to #{spot['band']}"
      break
    end
  end

  # If the band is still nil afterwards, skip the spot
  next if spot['band'].nil?

  # Insert the spot into the database
  run_query('sql_insert', 'spot_details', {'sender_master_grid_code':   spot['senderLocator'][0,2],
                                           'receiver_master_grid_code': spot['receiverLocator'][0,2],
                                           'band':                      spot['band'],
                                           'snr':                       spot['sNR'].to_i,
                                           'spot_time':                 Time.at(spot['flowStartSeconds'].to_i).to_datetime
                                          })

  loaded_spot_count += 1
end

@log.info "Spots Successfully Loaded from PSKReporter Loaded: #{loaded_spot_count} Spots"
##### End of Step 1

##################################################################
##### Step 2: Process the spots to determine band statistics #####
##################################################################
@log.info "Process Started to Process Band Stats"

# Create a hash of stats per band, which will added to a hash of grids, and the stats filled in later
band_hash = @config['bands'].keys.each_with_object({}) { |b,h| h[b] = {:spots_as_sender   => nil,
                                                                       :spots_as_receiver => nil,
                                                                       :dx_count          => nil,
                                                                       :dx_percentage     => nil,
                                                                       :avg_snr           => nil,
                                                                       :band_score        => nil}}

# Create a hash with the grids as keys, and the band hash as the values
stats = @config['master_grids'].values.each_with_object({}) { |g,h| h[g] = band_hash }

# Iterate through each grid and band to determine stats
stats.each do |grid, band|
  band.each do |band, stats|
    # Assign count of spots as sender for the band
    stats[:spots_as_sender]   = run_query('sql_count', 'spot_details_sender',   {'band': band,
                                                                                 'sender_master_grid_code': grid}).join.to_i
    # Assign count of spots as receiver for the band
    stats[:spots_as_receiver] = run_query('sql_count', 'spot_details_receiver', {'band': band,
                                                                                 'receiver_master_grid_code': grid}).join.to_i
    # Assign the count of spots that are outside of the configured master grids (which are the US grids, hence DX if it's not in there)
    stats[:dx_count] = run_query('sql_count', 'spot_details_dx', {'band': band,
                                                                  'sender_master_grid_code': grid,
                                                                  'receiver_master_grid_code': grid,
                                                                  'non_dx_grids': @config['master_grids'].values.join("','")}).join.to_i
    # If there aren't any spots for the band, then there's nothing to calculate for the average SNR and DX percentage
    unless stats[:spots_as_sender] + stats[:spots_as_receiver] < 1
      stats[:avg_snr] = run_query('sql_avg', 'spot_details_snr', {'band': band,
                                                                  'sender_master_grid_code': grid,
                                                                  'receiver_master_grid_code': grid}).join.to_i
      stats[:dx_percentage] = (stats[:dx_count] * 100) / (stats[:spots_as_sender] + stats[:spots_as_receiver])
    else
      stats[:avg_snr]       = nil
      stats[:dx_percentage] = 0
      stats[:band_score]    = 1
    end
    # Now determine a "score" for the band based on the configured parameters for each score 1-5
    @config['band_score_parameters'].each do |score, params|
      if stats[:spots_as_sender] + stats[:spots_as_receiver] >= params['spot_count'] && stats[:avg_snr] >= params['avg_snr'] && stats[:dx_percentage] >= params['dx_percentage']
        stats[:band_score] = score
        break
      end
    end
    # Insert the data for the grid/band/stats into the band_stats table
    run_query('sql_insert', 'band_stats', {'master_grid_code':  grid,
                                           'band':              band,
                                           'spots_as_sender':   stats[:spots_as_sender],
                                           'spots_as_receiver': stats[:spots_as_receiver],
                                           'dx_count':          stats[:dx_count],
                                           'dx_percentage':     stats[:dx_percentage],
                                           'avg_snr':           stats[:avg_snr],
                                           'band_score':        stats[:band_score]})

    @log.info "Grid #{grid} - #{band} Meter Band Stats: #{stats}"

  end
end

@log.info "Band Stats Process Completed Successfully"
##### End of Step 2

############################################################
##### Step 3: Output the data into separate html files #####
############################################################
@log.info "Process Started to Output HTML Tables"

# Get the data for each of the grids from the database
@config['master_grids'].each do |grid_name, grid_code|
  data        = run_query('sql_select', 'band_stats',        {'master_grid_code': grid_code})
  update_time = run_query('sql_select', 'spot_masters_time', {'master_grid_code': grid_code}).join

# Start building the table by injecting the header
  table = []
  table << '<table class="table" style="border:5px solid white">'
  table << '<thead>'
  table << '<tr class="table-black text-white fs-4">'
  table << '<th scope="col">Grid</th>'
  table << '<th scope="col">Band</th>'
  table << '<th scope="col">Sender</th>'
  table << '<th scope="col">Receiver</th>'
  table << '<th scope="col">DX</th>'
  table << '<th scope="col">DX %</th>'
  table << '<th scope="col">Avg. SNR</th>'
  table << '<th scope="col">Score</th>'
  table << '</tr>'
  table << '</thead>'
  table << '<tbody>'

# Go through each row
  data.each do |row|
    @log.debug "Adding Row: #{row}"
# Inject a table row class: green for band scores 5 and 4, yellow for 3 and 2, otherwise red
    case row[7]
      when 5
        table << '<tr class="table-success fs-4">'
      when 4
        table << '<tr class="table-success fs-4">'
      when 3
        table << '<tr class="table-warning fs-4">'
      when 2
        table << '<tr class="table-warning fs-4">'
    else
      table << '<tr class="table-danger fs-4">'
    end
# Inject the row data itself
    table << "<th scope=\"row\">#{row[0]}</th>"
    table << "<th scope=\"row\">#{row[1]}m</th>"
    table << "<td>#{row[2]}</td>"
    table << "<td>#{row[3]}</td>"
    table << "<td>#{row[4]}</td>"
    table << "<td>#{row[5]}%</td>"
    table << "<td>#{row[6]}</td>"
    table << "<td>#{row[7]}</td>"
    table << '</tr>'
  end
# Inject the closing tags
  table << '</tbody>'
  table << '</table>'
# Inject the last updated time
  table << "<a class=\"text-white\">Last Updated At: #{update_time}</a>"

# Write out the CSS file from the config css_template
  IO.write("web/css/mdb.min.css",   @config['css_template'])
# Write out the html file for the grid from the config html_template
  IO.write("web/#{grid_code}.html", @config['html_template'].gsub('<table></table>',table.join))
end

@log.info "HTML Table Output Process Completed Successfully"
##### End of Step 3

exit 0
