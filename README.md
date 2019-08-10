## Sandstorm Admin Wrapper

### About

Sandstorm Admin Wrapper is a set of tools designed to ease the burden of hosting a server for the `New World Interactive` video game [Insurgency: Sandstorm](https://store.steampowered.com/app/581320/Insurgency_Sandstorm/). It is comprised of a Ruby webserver (Sinatra) and associated tools which provide an easy-to-use browser front-end for configuring and managing a server on either Linux or Windows.

### Demo

<img src="https://user-images.githubusercontent.com/13367199/62821937-a7e09c80-bb4a-11e9-95f7-b181fa1129c4.gif" width="800">

### Features

- An easy-to-use webserver with configurable parameters via TOML file:
  - Bind IP/Port
  - SSL Enabled
  - Verify SSL Enabled
  - Cert/Key Paths
  - Session secret
- Pop-out sidebar navigation
- Server Setup page
  - Guides you through installing SteamCMD manually
  - Detects SteamCMD installation and server installation
  - Shows available server update
  - Provides a simple interface to install and manually update/verify the server files
  - SteamCMD log (see known issue below for Windows)
- Server Config page
  - Easy-to-use configuration options for your server
  - Blurring/redaction of sensitive information
  - Dropdowns for enumerated settings
  - Editable config files (Paste your current settings here! Matching settings above will override what was entered.)
    - `Game.ini`
    - `Engine.ini`
    - `Admins.txt`
    - `MapCycle.txt`
    - `Bans.json`
    - Local copies of these files are stored in `sandstorm-admin-wrapper/server-config`. Before launching the server, the manual config is applied to the `server-config` files, then those files are copied into the appropriate places in order for the server to use them. This prevents the server from overwriting our changes.
- Server Control page
  - Server status
  - Start/Restart/Stop buttons
  - Detailed PID and process exit toasts
  - Thread, player, and bot count
  - Player list
  - Server log
  - RCON console
  - RCON log
- RCON Tool
  - This tool currently allows remote RCON commands (with the given IP, port, and password). In the future this will probably be more like a remote administration tool (with remote server monitoring, player list, etc.).
- SteamCMD Tool
  - This tool allows passthrough to the SteamCMD installation. This could be useful for installing/updating other games, etc.

### Prerequisites

- Windows (10 tested) or Linux (Debian 9 tested)
- A Ruby `2.6.3` installation with the Bundler gem (`gem install bundler`). I recommend [rbenv](https://github.com/rbenv/rbenv) to manage Ruby installations on Linux and [RubyInstaller for Windows](https://rubyinstaller.org/downloads/) to install Ruby on Windows.
- [SteamCMD](https://developer.valvesoftware.com/wiki/SteamCMD#Cross-Platform_Installation) (extract/intall to `sandstorm-admin-wrapper/steamcmd/installation`)

### Installation

- Download and extract (or clone) the repository
- [Install SteamCMD](https://developer.valvesoftware.com/wiki/SteamCMD#Cross-Platform_Installation) manually to `sandstorm-admin-wrapper/steamcmd/installation`. `steamcmd.exe`/`steamcmd.sh` should be in the `installation` directory.
  - During runtime, we change the wrapper's `HOME` environment variable to `sandstorm-admin-wrapper/steamcmd` in order to contain SteamCMD's home directory pollution (on Linux) within the wrapper. You may see shell or Steam-related files in this directory as a result.

### Starting the Admin Wrapper

- Run the start script for your OS (`windows_start.bat` for Windows, `linux_start.sh` for Linux (BASH))
- Navigate to the web interface in your browser (e.g. https://localhost:51422/)
- Follow the instructions to install (or locate) the Sandstorm server you'd like to administrate
- Configure the server via the `Server -> Config` page
- Run the server via the `Server -> Control` page

### Useful information

- How the live server/RCON/SteamCMD logs work:
  - When starting the server process, SteamCMD, or executing RCON, we create a buffer object to hold data, bookmarks, and a status/message upon completion. The browser requests the appropriate buffer to obtain data to fill the log. The webserver provides a set amount of the buffer's data (to not overload the client) and provides a bookmark (UUID) which internally points to a specific index in the buffer's data. Once all the data is read and a status is available, the status and message are sent to the client and tailing is complete.
  - When reloading a page containing a server log, you may see the server log scroll again. This is because we are loading the buffered data from the beginning of the buffer's data array again and receiving it in chunks. Ideally we will cache that information in the future or change the tailing implementation.
- Used protocols:
  - [RCON](https://developer.valvesoftware.com/wiki/Source_RCON_Protocol) (TCP)
    - The RCON server used by Insurgency: Sandstorm has some unresolved [issues](https://forums.focus-home.com/topic/40331). As such, the RCON client found in this repository is customized to best work with Insurgency: Sandstorm and will likely not work well with other RCON-enabled servers (just like other RCON clients don't work well with Insurgency: Sandstorm).
  - [Server Query](https://developer.valvesoftware.com/wiki/Server_queries) (UDP)
    - We use the A2S_INFO, A2S_PLAYER, and A2S_RULES server queries.

### Known issues

These are the currently known issues. If you can fix any of these or know what to do, please send a pull request or [create a detailed GitHub issue](https://github.com/Joe-Klauza/sandstorm-admin-wrapper/issues/new). Thanks!

- SteamCMD output on Windows takes forever!
  - SteamCMD buffers progress output when it doesn't detect an interactive session (i.e. when it's being run by sandstorm-admin-wrapper). This output doesn't become available until the update/validation completes. There is a workaround we're using for Linux (PTY) to emulate an interactive session, but such a workaround does not appear to be feasible on Windows at this time. [(more info here)](https://github.com/ValveSoftware/Source-1-Games/issues/1684)
- Sometimes RCON output only appears in the RCON-specific log (not the server log)!
  - The server process sometimes only writes the RCON-related log messages to `Insurgency.log` (while writing all its other logging to `Insurgency_[0-9].log`). When this happens, the RCON-related log messages aren't even sent to STDOUT, which is what we use to populate the server log. As such, we also tail `Insurgency.log` for any RCON messages to add to the RCON-specific log to ensure they're still visible when this server bug occurs.

### Donate

If you'd like to show your appreciation of `Sandstorm Admin Wrapper` (or buy me some beer), please [donate via PayPal](https://www.paypal.com/cgi-bin/webscr?cmd=_donations&business=QZDY3PPUMH5TU&item_name=Sandstorm%20Admin%20Wrapper&currency_code=USD) (or suggest other methods).  
[![](https://www.paypalobjects.com/en_US/i/btn/btn_donateCC_LG.gif)](https://www.paypal.com/cgi-bin/webscr?cmd=_donations&business=QZDY3PPUMH5TU&item_name=Sandstorm%20Admin%20Wrapper&currency_code=USD)

### Contact

Join the unofficial [Insurgency: Sandstorm Community Server Hosts Discord](https://discord.gg/DSwnmyA)! We'd love to help you with any server hosting questions/issues you may have.
