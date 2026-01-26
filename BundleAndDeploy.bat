@echo off

set /p LUATITLE=<title.txt

node bundle.js
copy /Y "%LUATITLE%" "%localappdata%\lua\%LUATITLE%"
exit