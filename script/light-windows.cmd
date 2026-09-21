@echo off
setlocal enabledelayedexpansion

rem Launch the packaged Light Table on Windows with a Java 8 runtime first on
rem PATH, so the Clojure plugin's nREPL runner works.
rem
rem Why: lein-light-standalone.jar embeds Leiningen 2.5.2, whose dynapath
rem references sun.misc.Launcher$ExtClassLoader - a class removed in Java 9.
rem It fails on JDK 11, 17 and 21 alike. Nothing else in Light Table cares, so
rem this only prepends Java 8 for the launched process; the system default is
rem untouched. See UBUNTU-START.md and UPGRADE-RETROSPECTIVE-NOTES.md.
rem
rem Double-click this file, or run it from a terminal. Overrides:
rem   set LT_JAVA8_HOME=C:\path\to\jdk8      (skip auto-detection)
rem   set LT_BUILD_DIR=C:\path\to\build      (skip build auto-detection)

set "ROOT=%~dp0.."

rem ---------------------------------------------------------------- build dir
if defined LT_BUILD_DIR (
  set "BUILD=%LT_BUILD_DIR%"
) else (
  set "BUILD="
  for /d %%d in ("%ROOT%\builds\lighttable-*-windows") do set "BUILD=%%d"
)

if not defined BUILD goto :nobuild
if not exist "%BUILD%\LightTable.exe" goto :nobuild

rem --------------------------------------------------------------- find java 8
set "JAVA8="

if defined LT_JAVA8_HOME (
  if exist "%LT_JAVA8_HOME%\bin\java.exe" set "JAVA8=%LT_JAVA8_HOME%\bin"
)

if not defined JAVA8 call :scan "C:\JavaPrograms\jdk8*"
if not defined JAVA8 call :scan "C:\JavaPrograms\zulu8*"
if not defined JAVA8 call :scan "%ProgramFiles%\Eclipse Adoptium\jdk-8*"
if not defined JAVA8 call :scan "%ProgramFiles%\Java\jdk1.8*"
if not defined JAVA8 call :scan "%ProgramFiles%\Java\jre1.8*"
if not defined JAVA8 call :scan "%ProgramFiles%\Zulu\zulu-8*"
if not defined JAVA8 call :scan "%USERPROFILE%\scoop\apps\temurin8-jdk\current"

if defined JAVA8 (
  echo Using Java 8: %JAVA8%
  set "PATH=%JAVA8%;%PATH%"
) else (
  echo.
  echo   WARNING: no Java 8 found. Light Table will start, but the Clojure
  echo   plugin will fail to connect ^(the bundled nREPL runner cannot run on
  echo   Java 9 or newer^). Install a JDK 8, or point this script at one:
  echo.
  echo       set LT_JAVA8_HOME=C:\path\to\jdk8
  echo.
)

echo Starting %BUILD%\LightTable.exe
start "" "%BUILD%\LightTable.exe" %*
exit /b 0

rem ---------------------------------------------------------------- subroutine
rem Set JAVA8 to the bin dir of the first match of %~1 that really is a Java 8.
:scan
for /d %%d in ("%~1") do (
  if not defined JAVA8 (
    if exist "%%d\bin\java.exe" (
      rem Confirm it is actually 8 - directory names lie. Java prints its
      rem version banner on stderr, hence the 2^>^&1.
      "%%d\bin\java.exe" -version 2>&1 | findstr /c:"1.8." >nul
      if not errorlevel 1 set "JAVA8=%%d\bin"
    )
  )
)
exit /b 0

:nobuild
echo.
echo   No packaged build found under "%ROOT%\builds".
echo   Build one first:
echo.
echo       script/build.sh
echo.
echo   or set LT_BUILD_DIR to an existing build directory.
echo.
pause
exit /b 1
