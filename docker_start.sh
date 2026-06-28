#!/usr/bin/env bash

# Install the server if not already installed 
if [[ ALWAYS_UPDATE_SERVER ]] || [[ ! -d sandstorm-server/Insurgency ]] 
then
  echo Updating server
  steamcmd/installation/steamcmd.sh +force_install_dir /home/sandstorm/sandstorm-server +login anonymous +app_update 581330 +quit
else
  echo Leaving server as is
fi

# Start normally
exec ./linux_start.sh
