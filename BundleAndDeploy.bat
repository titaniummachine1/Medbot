@echo off

node bundle.js
move /Y "MedBot.lua" "%localappdata%"
exit