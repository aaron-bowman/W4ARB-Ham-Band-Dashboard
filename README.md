# W4ARB-Ham-Band-Dashboard
Simple ruby script that outputs HTML files for current ham radio band stats based on spots from PSKReporter.

Super useful dashboard to keep open while operating HF to know which bands are active and most likely for contacts and DX! Automatically refreshes the web page, and the script can be set up to auto-run to refresh the data.

# Usage
This script should work on any Mac or Linux-type OS

To use, simply ensure the following Ruby gems are installed:
- yaml
- logger
- sqlite3
- active_support
- fileutils

Then run the script. Example usage: `ruby refresh_spot_data.rb >> logs/refresh_spot_data.log`

The script can be set to run periodically through a scheduler such as *cron*

After the script runs, the html files can be accessed using a web browser. The files will be located in the *./web* folder

If using locally, the HTML files can be opened directly in a web browser. If using a web server, the web server config should point to the various grid files in the *./web* folder. *Note that there is not an index.html file*

It's currently configured for 2-character grids in the US. To use in a different region, the config.yml file could be updated with different values in "master_grids". The grid links above the table in the HTML would also need to be updated in the "html_template" in the config.yml file.
