#!/usr/bin/env bash

# Install the server if not already installed
if [[ ! -d sandstorm-server/Insurgency ]]
then
  steamcmd/installation/steamcmd.sh +login anonymous +force_install_dir /home/sandstorm/sandstorm-server +app_update 581330 +quit
fi

# Start normally
exec ./linux_start.sh
