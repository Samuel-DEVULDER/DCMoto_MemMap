#!/usr/bin/env sh

PWD=`pwd`
cd "`dirname '$0'`"
DIR=`pwd`
cd $PWD

case $1 in
	*/dcmoto_trace.txt) cd "`dirname '$1'`" ;;
	*) ;;
esac

$DIR/lua $DIR/memmap.lua -loop -html -hot -map -equ -mach=?? 

sensible-browser memmap.html || less memmap.csv
