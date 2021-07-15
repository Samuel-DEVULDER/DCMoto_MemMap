@echo off
setlocal

if "%~n1%~x1"=="dcmoto_trace.txt" ( cd /d %~dsp1 )

if "%~1"=="-FIXED_CTRL_C" (
   SHIFT
) ELSE (
   CALL <NUL %0 -FIXED_CTRL_C %~dsp0 %*
   GOTO :EOF
)

echo Press ctrl-c to break
%~dsp1\lua.exe %~dsp1\memmap.lua -loop -html -hot -map -equ -mach=?? -verbose=2
if exist memmap.html (
	echo Showing result in HTML...
	start memmap.html
) else (
	if exist memmap.csv (
		echo Showing result in CSV...
		start memmap.csv 
	) else (
		echo No result to display.
	)
)

