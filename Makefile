##############################################################################
# Makefile for SDDrive by Samuel Devulder
##############################################################################

STRIP=strip
WGET=wget
SED=sed -e
GIT=git
RM=rm
CP=cp
7Z=7z

VERSION:=$(shell git describe --abbrev=0 2>/dev/null || echo v0)
MACHINE:=$(shell uname -m)
DATE:=$(shell date +%FT%T%Z || date)
TMP:=$(shell mktemp)
OS:=$(shell uname -o)
EXE=

BAT=.sh
MKEXE=chmod a+rx

CC=gcc
CFLAGS=-O3 -Wall

ifeq ($(OS),Windows_NT)
	OS:=win
endif

ifeq ($(OS),Cygwin)
	OS:=win
endif

ifeq ($(OS),win)
	CC=i686-w64-mingw32-gcc -m32
	MACHINE=x86
	EXE=.exe

	BAT=.bat
	BAT_1ST=@echo off
	BAT_DIR=%~dsp0
	SETENV=set
endif

DISTRO=MemMap-$(VERSION)-$(OS)-$(MACHINE)

LUA=lua$(EXE)

ALL=$(LUA) memmap.lua memmap$(BAT)

##############################################################################

all: $(ALL)
	ls -l .

clean:
	-$(RM) -rf 2>/dev/null $(DISTRO) $(LUA)*
	-cd LuaJIT/ && make clean


##############################################################################
# Distribution stuff

distro: $(DISTRO)
	zip -u -r "$(DISTRO).zip" "$<"

$(DISTRO): $(ALL) \
	$(DISTRO)/ \
	$(DISTRO)/README.txt \
	$(DISTRO)/memmap.lua \
	$(DISTRO)/$(LUA) \
	$(DISTRO)/memmap$(BAT) \
	$(DISTRO)/example/ \
	$(DISTRO)/example/memmap.html \
	$(DISTRO)/example/memmap.csv \
	
	$(GIT) log >$@/ChangeLog.txt
	
$(DISTRO)/$(LUA): $(LUA)
	$(CP) $(LUA)* $(DISTRO)/
	
ifeq ($(OS),win)
HTML_TO=
else
HTML_TO=-|$(SED) 's%luajit\s+%luajit.exe %g'>
endif
	
$(DISTRO)/%.html: %.md $(DISTRO)/
	@grip -h >/dev/null || pip3 install grip
	grip --wide --export "$<" $(HTML_TO) "$@"
	
$(DISTRO)/%.txt: $(DISTRO)/%.html
	@echo -n Generating $@...
	@lynx -nolist -dump -assume_charset=utf-8 -display_charset=us-ascii $< | \
	sed -e '/\s*Examples/ Q' >$@
	@echo done

$(DISTRO)/memmap.lua: $(DISTRO)/README.txt memmap.lua Makefile README.md
	@echo -n Inserting usage into $@...
	@cat $(DISTRO)/README.txt | \
	sed -e '1,/\s*Usage/ d; s/^\s\s\s/-- /; s/^\s*$$/--/' | \
	sed -e '1 {/^--\s*$$/d}' >.usage
	@echo  >.sed 's%\$$Version\$$%$(VERSION)%g'
	@echo >>.sed 's%\$$Date\$$%$(DATE)%g'
	@echo >>.sed '/\$$Usage\$$/ {'
	@echo >>.sed '  r .usage'
	@echo >>.sed '  d'
	@echo >>.sed '}'
	@sed -f .sed memmap.lua >$@
	@rm .sed .usage 
	@echo done

$(DISTRO)/%: %
	test -d "$<" || cp -v "$<" "$@"

$(DISTRO)/example/%: %
	@mkdir -p $(DISTRO)/example/
	$(CP) "$<" "$@"

tst: example/memmap.html tst_dummy tst_h

tst_h: $(DISTRO)/memmap.lua $(DISTRO)/$(LUA)
	@X="$(DISTRO)/$(LUA) $< -h"; \
	echo -n Testing $$X...;\
	X=`$$X | wc -l`; \
	if test $$X -ne 117; then \
		echo; \
		echo "Error: expected 117, got $$X"; \
		exit 15; \
	else \
		echo ok; \
	fi

tst_dummy: $(DISTRO)/memmap.lua $(DISTRO)/$(LUA)
	@X="$(DISTRO)/$(LUA) $< -dummy"; \
	echo -n Testing $$X...;\
	X=`$$X | wc -l`; \
	if test $$X -ne 15; then \
		echo; \
		echo "Error: expected 15, got $$X"; \
		exit 15; \
	else \
		echo ok; \
	fi

%/memmap.html: %/dcmoto_trace.txt memmap.lua Makefile $(LUA)
	ROOT=$(shell realpath --relative-to=$*/ .); \
	cd $*; time \
	$$ROOT/$(LUA) $$ROOT/memmap.lua \
	-reset -html  -smooth \
	-mach=?? -from=4000 -map -hot -equ -verbose=2
	@cmd /c start $*/memmap.html

%/dcmoto_trace.txt: %/dcmoto_trace.txt.7z
	$(7Z) -so -y x "$<" "$@" > "$@"
	
%/dcmoto_trace.txt.7z: dcmoto_trace.txt
	$(CP) "$<" "$(@:.7z=)"
	$(7Z) -y -stl u "$@" "$(@:.7z=)"
	
$(LUA): LuaJIT $(wildcard LuaJIT/src/*)
	cd $< && export MAKE="make -f Makefile" && $$MAKE BUILDMODE=static CC="$(CC) -static" CFLAGS="$(CFLAGS)"  
	$(CP) $</src/luajit$(EXE) "$@"
	$(CP) $</COPYRIGHT "$@"-COPYRIGHT
	$(STRIP) "$@"

LuaJIT:
	$(GIT) clone https://github.com/LuaJIT/LuaJIT.git

# Create folder	
%/:
	mkdir -p "$@"

# zip
%.7z: %
	$(7Z) -y -u -stl a "$<.7z" "$<"

# unzip