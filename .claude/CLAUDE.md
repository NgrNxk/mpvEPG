# CLAUDE

## General

You are developing scripts for [mpv](mpv.io), a versatile media player. The
scripts are written in LUA. Always try to use the local functions first, i.e.
mpv internal functions or LUA functions before resorting to external tools
usage. You can find the documentation for its LUA scripting capabilities in
[lua documentation](./lua.rst) and [input](./input.rst).

## Notable functionality in mpv

- Listen on variable changes
- call of internal functions via mp.command_native(...table)
