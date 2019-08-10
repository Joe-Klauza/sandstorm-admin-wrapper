@echo off
cd admin-interface
echo Bundling
call bundle
IF ERRORLEVEL 1 GOTO error
echo Starting webapp
call bundle exec ruby lib/webapp.rb
exit 0

:error
echo Failed to run Ruby Bundler. Ensure Ruby is installed with the bundler gem. https://rubyinstaller.org/downloads/
exit 1