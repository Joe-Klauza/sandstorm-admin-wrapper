#!/usr/bin/env bash

# Install the server if not already installed 
if [[ ! -d sandstorm-server/Insurgency ]]
then
  steamcmd/installation/steamcmd.sh +force_install_dir /home/sandstorm/sandstorm-server +login anonymous +app_update 581330 +quit
fi

# Start normally
exec ./linux_start.sh
