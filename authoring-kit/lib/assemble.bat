@echo off
setlocal EnableExtensions
copy /Y "%NEXFILE%" "RELEASE\nextdaad.nex" >nul || (
    echo ERROR: could not copy interpreter %NEXFILE%
    exit /b 1
)
echo   interpreter -^> RELEASE\nextdaad.nex
endlocal
exit /b 0
