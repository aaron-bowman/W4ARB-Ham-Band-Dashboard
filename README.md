# W4ARB-Ham-Band-Dashboard
Simple ruby script that outputs HTML files for current ham radio band stats based on spots from PSKReporter

This script should work on any Mac or Linux-type OS.

To install, simply ensure the following gems are installed:
- yaml
- logger
- sqlite3
- active_support
- fileutils

Then just run the script, example usage: `ruby refresh_spot_data.rb >> logs/refresh_spot_data.log`

The script can be set to run periodically through a scheduler such as *cron*

After the script runs, the html files can be accessed using a web browser. The files will be located in the *./web* folder

If using locally, the files can be opened directly. If using a web server, the web server config should point to the various grid files in the *./web* folder. Note that there is not an index.html file.
