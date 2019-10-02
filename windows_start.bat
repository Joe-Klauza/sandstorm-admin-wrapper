@echo off
cd %~dp0\admin-interface

:bundle
echo Bundling
call bundle
if ERRORLEVEL 1 goto bundle_error
echo Starting webapp

:run_webapp
call bundle exec ruby lib/webapp.rb %*
echo Error level: %errorlevel%
if errorlevel 2 goto :bundle
if errorlevel 1 goto exit_error
if errorlevel 0 goto exit_success

:webapp_error
echo Failed to run Sandstorm Admin Wrapper. Ensure Ruby is version 2.6.3+. Logs are located in admin-interface/log.
goto exit_error

:bundle_error
echo Failed to run Ruby Bundler. Ensure Ruby is installed with the bundler gem. https://rubyinstaller.org/downloads/
goto exit_error

:exit_error
pause
exit 1

:exit_success
echo Sandstorm Admin Wrapper exited successfully.
pause
exit 0
