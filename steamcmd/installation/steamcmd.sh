#!/usr/bin/env bash

STEAMROOT="$(cd "${0%/*}" && echo $PWD)"
STEAMCMD=`basename "$0" .sh`

UNAME=`uname`

  
if [ "$UNAME" == "Linux" ]; then
  STEAMEXE=`type -p steamcmd`
  if [ $? -eq 0 ]; then 
     >&2 echo steamcmd is on PATH as $STEAMEXE
  else 
    STEAMEXE="${STEAMROOT}/linux32/${STEAMCMD}"
    export LD_LIBRARY_PATH="$STEAMROOT/$PLATFORM:$LD_LIBRARY_PATH"
  fi
  PLATFORM="linux32"
else # if [ "$UNAME" == "Darwin" ]; then
  STEAMEXE="${STEAMROOT}/${STEAMCMD}"
  if [ ! -x ${STEAMEXE} ]; then
    STEAMEXE="${STEAMROOT}/Steam.AppBundle/Steam/Contents/MacOS/${STEAMCMD}"
  fi
  export DYLD_LIBRARY_PATH="$STEAMROOT:$DYLD_LIBRARY_PATH"
  export DYLD_FRAMEWORK_PATH="$STEAMROOT:$DYLD_FRAMEWORK_PATH"
fi

ulimit -n 2048

MAGIC_RESTART_EXITCODE=42

if [[ -z "$DEBUGGER" ]]; then
  >&2 echo DEBUGGER not set. Starting steamcmd directly
  "$STEAMEXE" "$@"
elif [ "$DEBUGGER" == "gdb" ] || [ "$DEBUGGER" == "cgdb" ]; then
  ARGSFILE=$(mktemp $USER.steam.gdb.XXXX)

  # Set the LD_PRELOAD varname in the debugger, and unset the global version.
  if [ "$LD_PRELOAD" ]; then
    echo set env LD_PRELOAD=$LD_PRELOAD >> "$ARGSFILE"
    echo show env LD_PRELOAD >> "$ARGSFILE"
    unset LD_PRELOAD
  fi

  $DEBUGGER -x "$ARGSFILE" "$STEAMEXE" "$@"
  rm "$ARGSFILE"
else
  $DEBUGGER "$STEAMEXE" "$@"
fi

STATUS=$?

if [ $STATUS -eq $MAGIC_RESTART_EXITCODE ]; then
    exec "$0" "$@"
fi
exit $STATUS
