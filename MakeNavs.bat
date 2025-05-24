@echo off

set /p tf_map_path="Please enter the path to your tf/maps folder (you can copy-paste it here): "

:: Remove surrounding quotes and trailing spaces
set tf_map_path=%tf_map_path:~0,260%
set tf_map_path=%tf_map_path:~0,-1%
if "%tf_map_path:~0,1%"==\" set tf_map_path=%tf_map_path:~1%
if "%tf_map_path:~-1%"==\" set tf_map_path=%tf_map_path:~0,-1%

if not exist "%tf_map_path%" (
    echo ERROR: The folder "%tf_map_path%" does not exist.
    pause
    exit /b 1
)

move /Y "navmeshes\*" "%tf_map_path%" || (
    echo ERROR: Failed to move files. Check folder path and permissions.
    pause
    exit /b 1
)

echo All navmeshes moved to %tf_map_path%.
pause