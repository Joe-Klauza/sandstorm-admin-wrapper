Extract SteamCMD in the installation directory.

On Windows, steamcmd.exe should be there.

On Linux, steamcmd.sh should be there.

If steamcmd is on that PATH, we'll use that if we can't find it here. (TODO)

We set the user's HOME directory to this directory during execution in order to keep steamcmd from polluting the user's home directory with files. As such you may see a .bash_history or other shell-/Steam-related files here.

