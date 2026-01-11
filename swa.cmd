::
::     script: swa.cmd
::    purpose: AWS context switcher for Command-Prompt and PowerShell
::    version: 1.0.0
::    license: MIT
::     author: Hamed Davodi <retrogaming457 [at] gmail [dot] com>
:: repository: https://github.com/bruckware/swa
::


@echo off
setlocal EnableDelayedExpansion

set "_ARG="
set "_ARG=%1"
set "_VERSION=1.0.0"
set "_REPO=https://github.com/bruckware/swa"

set "ESC="
set "RESET=%ESC%[0m"
set "GRAY=%ESC%[90m"
set "BLUE=%ESC%[34m"
set "GREEN=%ESC%[32m"
set "YELLOW=%ESC%[33m"
set "BRIGHT_WHITE=%ESC%[97m"
set "ORANGE=%ESC%[38;2;255;165;0m"
set "MSG_PREFIX=%ORANGE%[swa]%RESET%"
set "GUM_FILTER_MATCH_FOREGROUND=#FFA500"
set "GUM_CHOOSE_CURSOR_FOREGROUND=#FFA500"
set "GUM_CONFIRM_PROMPT_FOREGROUND=#C0C0C0"
set "GUM_CHOOSE_SELECTED_FOREGROUND=#FFA500"
set "GUM_CONFIRM_SELECTED_BACKGROUND=#FFA500"
set "GUM_FILTER_INDICATOR_FOREGROUND=#FFA500"
set "GUM_FILTER_CURSOR_TEXT_FOREGROUND=#FFA500"
set "GUM_FILTER_SELECTED_PREFIX_FOREGROUND=#FFA500"

call :set_options || goto :eof
call :requirement || goto :eof
call :set_profile || goto :eof
call :get_configs || goto :eof
call :export_init || goto :eof

endlocal & call "%SWA_INIT%"
goto :eof





:show_help
echo.
echo  swa - an interactive AWS context switcher for Windows Command-Prompt and PowerShell
echo  This tool uses environment variables to switch profile and avoids editing of config
echo  file for this purpose.
echo.
echo  swa exports variables of the global settings ^& service-specific settings, including 
echo  all 380 AWS services. Note environment variables are only exported in current shell
echo  session and, this tool does not modify system-wide or user-wide variables table.
echo.
echo  swa is optimized to work with large config files, containing numerous profiles from 
echo  all AWS profile types ^(IAM User, SSO, Assume Role, Web Identity, External Process^).
echo  it can parse values of profiles with services header as those values cannot be read
echo  by aws cli itself and,supports Amazon s3 and any s3-compatible implementation which
echo  which is using AWS s3 API.
echo. 
echo  In addition, it faciliates working with self-hosted s3 services in case s3 endpoint
echo  is using self-signed certificate and, it exports the config file of other s3 client
echo  tools on their default paths.
echo.
echo  Usage: swa [options]
echo.
echo        -h, --help      Show help
echo        -v, --version   Show version
echo        -l, --list      List all profiles
echo        -m, --mfa       Prompt for MFA-Login if profile has mfa_serial option
echo        -f              Force cache update for both profiles and services list
echo        -c              Export AWS credentials as environment variables
echo        -u              Verify endpoint_url access and download CA bundle
echo        -i              Update MinIO client ^(mc^) config file ^f^o^r s3 alias
echo        -3              Update config file of s3cmd
echo        -5              Export s3 endpoint_url environment variable for s5cmd
echo.
goto :eof



:: ---------------------------------------------------------------------------
:: This script is intentionally heavily commented.
:: While this may differ from the 'minimal comments' guideline as mentioned in
:: Clean Code, this approach is deliberate in order to:
::
:: - Serve as both source code and documentation
:: - Avoid relying on a separate file for documentation
:: - Capture workflow, intent, and decision rationale
:: ---------------------------------------------------------------------------


:: set default options and updates one if an argument is passed.
:: at most one command-line argument is allowed per invocation.
:set_options
set "FLAG_CREDENTIALS=0"
set "FLAG_VERIFY_URL=0"
set "FLAG_LISTING=0"
set "FLAG_MFA=0"
set "FLAG_CACHE=0"
set "FLAG_MINIO=0"
set "FLAG_S3CMD=0"
set "FLAG_S5CMD=0"

if not defined _ARG exit /b 0

set "VALID_FLAGS=-h --help -v --version -l --list -m --mfa -f -c -u -i -3 -5"
set "FOUND_FLAG="

for %%F in (%VALID_FLAGS%) do if "%_ARG%"=="%%~F" set "FOUND_FLAG=1"

if not defined FOUND_FLAG ( call :error_1 & exit /b 1 )

if "%_ARG%"=="-h"        ( call :show_help & exit /b 1 )
if "%_ARG%"=="--help"    ( call :show_help & exit /b 1 )
if "%_ARG%"=="-v"        ( echo v%_VERSION% & echo %_REPO% & exit /b 1 )
if "%_ARG%"=="--version" ( echo v%_VERSION% & echo %_REPO% & exit /b 1 )
if "%_ARG%"=="-l"        ( set "FLAG_LISTING=1" & exit /b 0 )
if "%_ARG%"=="--list"    ( set "FLAG_LISTING=1" & exit /b 0 )
if "%_ARG%"=="-m"        ( set "FLAG_MFA=1" & exit /b 0 )
if "%_ARG%"=="--mfa"     ( set "FLAG_MFA=1" & exit /b 0 )
if "%_ARG%"=="-f"        ( set "FLAG_CACHE=1" & exit /b 0 )
if "%_ARG%"=="-c"        ( set "FLAG_CREDENTIALS=1" & exit /b 0 )
if "%_ARG%"=="-u"        ( set "FLAG_VERIFY_URL=1" & exit /b 0 )
if "%_ARG%"=="-i"        ( set "FLAG_MINIO=1" & exit /b 0 )
if "%_ARG%"=="-3"        ( set "FLAG_S3CMD=1" & exit /b 0 )
if "%_ARG%"=="-5"        ( set "FLAG_S5CMD=1" & exit /b 0 )
goto :eof





:requirement
:: Variable leakage can happen in batch because sometimes, setlocal/endlocal fails on abnormal exits.
:: Therefore, SWA_ prefix is used on multiple variable names to create a prefix-based namespace emulation.
:: This way, at the start, to avoid incorrect results, we ensure they are all undefined (if any).
for /f "usebackq tokens=1* delims==" %%A in (`set SWA_ 2^>nul`) do set "%%A="

:: Define default locations for AWS config and credentials files.
:: These defaults are overridden if user-defined paths are provided via environment variables. 
:: CONF_FILE and CRED_FILE variables are used when parsing files.
::
:: credentials file is treated as optional throughout the script, as some
:: users may not use it or may combine credentials into config file.
set "CONF_FILE=%USERPROFILE%\.aws\config"
set "CRED_FILE=%USERPROFILE%\.aws\credentials"

:: Preserve existing AWS_CONFIG_FILE and AWS_SHARED_CREDENTIALS_FILE values (if any)
:: so they can be restored after clearing AWS-related environment variables.
:: This is necessary to avoid conflicts or incorrect behavior when AWS CLI
:: commands are executed later, particularly when user relies 
:: on non-default file locations outside %USERPROFILE%\.aws\
if defined AWS_CONFIG_FILE (
    if exist "%AWS_CONFIG_FILE%" (
        set "CONF_FILE=%AWS_CONFIG_FILE%"
        set "SWA_CONF_ENV=%AWS_CONFIG_FILE%"
    )
)
if defined AWS_SHARED_CREDENTIALS_FILE (
    if exist "%AWS_SHARED_CREDENTIALS_FILE%" (
        set "CRED_FILE=%AWS_SHARED_CREDENTIALS_FILE%"
        set "SWA_CRED_ENV=%AWS_SHARED_CREDENTIALS_FILE%"
    )
)

:: After resolving CONF_FILE and CRED_FILE paths, verify if config file exist and is readable.
:: credentials file is optional; however, if it exists, read permission is verified.
if not exist "%CONF_FILE%" ( call :error_2 & exit /b 1 )
type "%CONF_FILE%" >nul 2>&1 || ( call :error_3 & exit /b 1 )

if exist "%CRED_FILE%" (
   type "%CRED_FILE%" >nul 2>&1 || ( call :error_4 & exit /b 1 )
)

:: Clear all AWS-related environment variables to ensure a clean execution context.
:: This prevents stale or conflicting values from influencing aws cli queries.
:: Credential-related variables are preserved to support workflows
:: of AssumeRole profile with Environment option.
for /f "usebackq tokens=1* delims==" %%A in (`set AWS_ 2^>nul`) do (
    if "%%A"=="AWS_ACCESS_KEY_ID"     set "SWA_ACCESS_KEY=%%B"
    if "%%A"=="AWS_SECRET_ACCESS_KEY" set "SWA_SECRET_KEY=%%B"
    if "%%A"=="AWS_SESSION_TOKEN"     set "SWA_SESSION_TOKEN=%%B"
    set "%%A="
)

:: Restore AWS_CONFIG_FILE and AWS_SHARED_CREDENTIALS_FILE if they were previously set
if defined SWA_CONF_ENV set "AWS_CONFIG_FILE=%SWA_CONF_ENV%"
if defined SWA_CRED_ENV set "AWS_SHARED_CREDENTIALS_FILE=%SWA_CRED_ENV%"

:: Define absolute paths to required native Windows tools and verify they exist.
:: curl is included by default on Windows 10 (build 17063 and later).
:: If it is missing, install it using a package manager such as Chocolatey and update CURL_EXE value.
set "WHERE_EXE=%SystemRoot%\System32\where.exe"
set "FINDSTR_EXE=%SystemRoot%\System32\findstr.exe"
set "CURL_EXE=%SystemRoot%\System32\curl.exe"

if not exist "%WHERE_EXE%" ( call :error_5 & exit /b 1 )
if not exist "%FINDSTR_EXE%" ( call :error_6 & exit /b 1 )
if not exist "%CURL_EXE%" ( call :error_7 & exit /b 1 )

:: Verify external dependencies are in PATH.
:: Their absolute paths are not defined as variables because installation path may vary for each user.
"%WHERE_EXE%" /q aws.exe || ( call :error_8 & exit /b 1 )
"%WHERE_EXE%" /q gum.exe || ( call :error_9 & exit /b 1 )

:: Initialize default values for internal control flags.
set "CA_REQUIRED=0"
set "URL_REQUIRED=0"
set "HTTP=0"

:: Ensure the following variables are unset by default.
:: They may be evaluted later when -i (minio) or -5 (s5cmd) options are used.
set "MC_HOST_S3="
set "S3_ENDPOINT_URL="

:: Derive the config file directory and file name.
:: CONF_DIR and CONF_FILENAME are reused in multiple parts of the script,
:: including this step where they are needed to retrieve config file timestamp.
for %%I in ("%CONF_FILE%") do (
    set "CONF_DIR=%%~dpI"
    set "CONF_FILENAME=%%~nxI"
)

:: Define path to swa working directory under config file directory
:: and create it if not exist.
::
:: swa directory in Windows is used to store:
::  - Cache files (profiles data and aws services list)
::  - AWS services-list HTML page
::  - Runtime-generated helper scripts (batch or PowerShell) that are sourced
::    at the end of execution to export environment variables.
::
:: Also define the paths for the main cache files. 
:: Both are required here at verify_cache step and later in workflow.
set "SWA_DIR=%CONF_DIR%swa"
set "PROFILES_CACHE=%SWA_DIR%\aws_profiles_data"
set "SERVICES_CACHE=%SWA_DIR%\aws_services_list"

if not exist "%SWA_DIR%" (
    mkdir "%SWA_DIR%" >nul 2>&1 || (
        call :error_10
        exit /b 1
    )
)

:: Retrieve config file timestamp and validate cache.
:: Workflow:
::  - Extract last-modified timestamp of config file.
::  - Verify the existing cache against this timestamp.
::  - If cache is missing or outdated or -f option is used, rebuild it.
call :get_config_ts || exit /b 1
call :verify_cache  || ( call :build_cache || ( call :error_11 & exit /b 1 ) )
goto :eof





:: Retrieves the last-modified timestamp of the AWS config file.
::
:: Timestamp is required everytime when swa is executed as part of pre-check phase,
:: and during cache buidling process.
::
:: Workflow:
::  - `where /T` is used instead of `%~t` modifier because `where /T`
::    includes seconds in the timestamp, whereas `%~t` truncates it.
::  - Executes `where` command from within the config directory
::    because the config file is not expected to be in PATH.
::  - Re-validates absolute path before extracting timestamp to ensure 
::    it is the intended file.
:get_config_ts
pushd "%CONF_DIR%" 2>&1 || ( call :error_12 & exit /b 1 )

set "current_timestamp="
for /f "usebackq tokens=2,3,4" %%a in (`call "%WHERE_EXE%" /T "%CONF_FILENAME%" 2^>nul`) do (
    if "%%c"=="%CONF_FILE%" set "current_timestamp=%%a %%b"
)

popd

if not defined current_timestamp ( call :error_13 & exit /b 1 )
goto :eof




:: verify_cache subroutine must be called at the start to ensure cache integrity.
:: cache is considered valid only if:
::   - Both profiles and services cache files exist
::   - Timestamp stored in profiles cache matches current timestamp of config file
:: otherwise or if -f option is used, exits with code 1 to invoke build_cache subroutine
::
:: Note that if swa is invoked with -f option, if profile cache and services list exist,
:: they are overwritten and a new cache is built.
:verify_cache
if "%FLAG_CACHE%"=="1" exit /b 1

if not exist "%SERVICES_CACHE%" exit /b 1
if not exist "%PROFILES_CACHE%" exit /b 1

set "cached_timestamp="
set /p cached_timestamp=<"%PROFILES_CACHE%"
if not defined cached_timestamp exit /b 1

:: using case insensitive if timestamp includes am/pm
if /i "%cached_timestamp%" neq "[%current_timestamp%]" exit /b 1
goto :eof





:: Main dispatcher to build cache to help with a faster and simpler access to config data.
:: Workflow:
::  - Read AWS service list from cache. if not available, download, validate and finally write to the 'services cache'.
::  - List profile headers, validate character sets, determine profile types and corresponding line numbers in config file.
::  - Count service id per profile (if any).
::  - Index all collected data.
::  - Write indexed data to the 'profile cache'.
:build_cache
setlocal
call :info_1
call :get_services_list || exit /b 1
call :get_config_profiles || exit /b 1
call :cache_profiles_data || exit /b 1
endlocal
goto :eof





:: Build a list of all AWS service IDs for validating and counting services per profile, then cache the result for reuse.
:: The service list is downloaded if no local cache exists and, if the existing cache fails validation, 
:: user is instructed to use -f option to trigger a new download of services list.
::
:: Services are stored in a single variable because batch scripting has no native arrays and, 
:: to avoid repeatedly invoking redirection (380 times) if each service_id is defined separately using dynamic variable name.
:: Current service list length is approximately 5072 characters, leaving sufficient buffer space before reaching variable size limit of 8KB.
:get_services_list
set "aws_services_list="
set "used_service_cache="

if "%FLAG_CACHE%"=="1" (
   call :download_services_list || exit /b 1
   exit /b 0
) 

if not exist "%SERVICES_CACHE%" (
   call :download_services_list || exit /b 1
   exit /b 0
) 

for /f "usebackq tokens=*" %%s in ("%SERVICES_CACHE%") do set "aws_services_list=%%s"

set "used_service_cache=1"

call :verify_services_list || exit /b 1
goto :eof




:: Retrieve the complete list of AWS service identifiers required to build
:: the profiles cache. This list is downloaded once and cached locally.
:: A new download is triggered only if -f option is used or cache is missing.
::
:: Workflow:
::  - AWS documentation page contains a table with three columns (rows in raw html):
::      1. Service name
::      2. Service identifier key
::      3. AWS_ENDPOINT_URL_<SERVICE> environment variable
::
::  - Filtering HTML page for values with this tag → " <code class="code">accessanalyzer</code>"
::  - Only 'Service identifier key' in the 2nd row is extracted → accessanalyzer
::
:: Note:
::   Not all three values from the AWS services table are required.
::   Service identifier key alone is sufficient for all current use cases:
::     - Validating service identifiers in config file
::     - Displaying options in the user selection menu
::     - Defining service-specific endpoint URLs
::       (service identifier is converted to uppercase and appended to
::        AWS_ENDPOINT_URL_<UPPERCASE_SERVICE_ID>)
:download_services_list
set "AWS_SS_URL=https://docs.aws.amazon.com/sdkref/latest/guide/ss-endpoints-table.html"

set "AWS_SS_TABLE=%SWA_DIR%\aws_ss_table.html"
copy nul "%AWS_SS_TABLE%" >nul 2>&1 || (
    call :error_67
    exit /b 1
)

:: Intentionally extracting service_ids from HTML page in two steps (instead of piping) for better error handling
"%CURL_EXE%" -q -s "%AWS_SS_URL%" > "%AWS_SS_TABLE%" || ( call :error_14 & exit /b 1 )

set "count=0"
set "srv_id="
:: In this and other similar cases, using indirect invocation to use of primary batch parser since paths are quoted
for /f "usebackq tokens=1* delims=>" %%A in (`call "%FINDSTR_EXE%" /C:" <code class=" "%AWS_SS_TABLE%"`) do (
    set "srv_id=%%~B"
    set "srv_id=!srv_id:</code>=!"
    set "srv_id=!srv_id: =!"
    
    :: Take the value of 2nd row for each group of 3 rows
    set /a count+=1
    if "!count!"=="2" set "aws_services_list=!aws_services_list! !srv_id!"
    if "!count!"=="3" set "count=0"

)

call :verify_services_list || exit /b 1
call :cache_services_list || exit /b 1
call :info_5
goto :eof



:: Verify the integrity of the AWS services list, whether it was downloaded
:: or loaded from the cached file.
::
:: Workflow:
::  - A few widely used AWS services is selected.
::  - If all of these services are present in the list, the list is assumed
::    to be complete and valid.
::  - If any are missing, cache is considered corrupted or incomplete.
::    Execution terminates with a fatal error. If the cached list was used, 
::    user is instructed to invoke swa with -f option to download a new list.
:verify_services_list
if not defined aws_services_list (
    call :error_15
    exit /b 1
)

set "random_services=s3 cloud9 dynamodb ec2 eks lambda sagemaker"
for %%a in (%random_services%) do (
    for %%b in (%aws_services_list%) do if "%%a"=="%%b" set "SWA_SRV_%%a=1"
)
for %%a in (%random_services%) do (
    if not defined SWA_SRV_%%a (
        call :error_16
        if defined used_service_cache call :info_2
        exit /b 1
    )
)
goto :eof



:: Cache AWS services list locally for reuse.
::
:: Workflow:
::  - Create services cache as a zero-byte file.
::  - Write services list as a single line which consists of space-separated values.
::  - Use `set /p` to avoid appending a newline or extra characters.
::
:: Notes:
::  - Explicitly exit with code 0 instead of `goto :eof` because 
::    `set /p` sets ERRORLEVEL to 1 even on success.
:cache_services_list
copy nul "%SERVICES_CACHE%" >nul 2>&1 || (
    call :error_17
    exit /b 1
)

:: Redirecting service list with set to avoid newline
set "aws_services_list=%aws_services_list:~1%"
<nul set /p="%aws_services_list%" > "%SERVICES_CACHE%"

for %%I in ("%SERVICES_CACHE%") do if %%~zI lss 1024 (
    call :error_18
    exit /b 1
)
exit /b 0





:: Writes the fully collected and validated profile data into the cache file.
:: This subroutine is called only after all prerequisite steps have completed
:: successfully and the in-memory profile data is considered valid.
::
:: Workflow:
::  1. Create the cache file as a zero-byte file.
::  2. Retrieve the config file timestamp and writes it as the first line of the cache file
::  3. Expand and write all dynamically indexed profile data variables
::     (generated in index_profile_data step), one profile per line.
::  4. Validate that cache file is non-empty to confirm a successful write.
::
:: Notes:
::  - Due to the lack of native array support in Batch, profile data is stored
::    in dynamically named variables (SWA_PDATA_<index>).
::  - Each expanded variable corresponds to a single cache entry.
:cache_profiles_data
copy nul "%PROFILES_CACHE%" >nul 2>&1 || (
    call :error_19
    exit /b 1
)

call :get_config_ts || exit /b 1
> "%PROFILES_CACHE%" echo [%current_timestamp%]

for /L %%i in (1,1,!IDX!) do (
    >> "%PROFILES_CACHE%" echo !SWA_PDATA_%%i!
    set "SWA_PDATA_%%i="
)

for %%A in ("%PROFILES_CACHE%") do if %%~zA lss 1 (
    call :error_20
    exit /b 1
)

call :info_6
goto :eof



:: This subroutine is invoked by get_config_profile for each profile in config file. 
::
:: Workflow:
::  1. Detect duplicate profile names within the config file.
::  2. Since Batch does not provide native arrays, data is defined using dynamically variables names SWA_PDATA_<index>
::
:: Data layout per profile (single cache line):
::  - profile_name
::  - profile_type
::  - profile_line_nr
::  - service_1:count service_2:count ... service_N:count (if any)
:index_profile_data
if defined SWA_CONF_DUP_!profile_name! (
    call :error_21
    exit /b 1
) else (
    set "SWA_CONF_DUP_!profile_name!=1"
)

set /a IDX+=1
if defined profile_services (
    set "SWA_PDATA_!IDX!=!profile_name! !profile_type! !profile_line_nr! !profile_services:~1!"
) else (
    set "SWA_PDATA_!IDX!=!profile_name! !profile_type! !profile_line_nr!"
)
goto :eof




:: Profile data from the config file is validated, collected, and cached.
::
:: Workflow:
::   - If a credentials file exists, invoke get_credentials_profiles to collect
::     all available profiles into the profile_list_cred variable
::     (see comments above get_credentials_profiles for details).
::
::   - Validate config file headers to ensure only the allowed character set
::     is used (step 1: regex-based validation).
::
::   - Parse the config file and identify one of the supported header types:
::       * [default]
::       * [profile ...]
::       * [services ...]
::       * [sso-session ...]
::     Anything else → hard error.
::
::   - For all supported header types, perform the second step of character
::     set validation.
::
::   - For profile headers:
::       * Determine the profile type → set_profile_type subroutine
::       * Collect any indented services and their count → get_profile_services subroutine
::       * Index the collected profile data into a single variable
::         to be written later to the profiles cache → index_profile_data subroutine
:get_config_profiles
set "profile_list_cred="
if exist "%CRED_FILE%" ( call :get_credentials_profiles || exit /b 1 )

:: for error message
set "header_source=config file"
set "target_file=%CONF_FILE%"
call :validate_header_step1 || exit /b 1

set "IDX=0"
set "line="
set "line_nr="
set "header_line="
set "profile_name="
set "profile_line_nr="
for /f "usebackq tokens=1* delims=:" %%a in (`call "%FINDSTR_EXE%" /N /C:"[" "%CONF_FILE%" 2^>nul`) do (
    set "line_nr=%%a"
    set "line=%%b"
    
    :: for error message
    set "header_line=%%b"
   
    if "!line:~0,1!"==" " ( call :error_23 & exit /b 1 )

    if "!line:~0,9!"=="[default]" (
        
        set "profile_line_nr=!line_nr!"
        set "profile_name=default"
        call :set_profile_type || ( call :error_29 & exit /b 1 )
        call :get_profile_services || ( call :error_30 & exit /b 1 )
        call :index_profile_data || exit /b 1

    ) else if "!line:~0,8!"=="[profile" (

        if "!line:~8,1!" neq " " ( call :error_24 & exit /b 1 )
        set "line=!line:~9!"
        call :validate_header_step2 || exit /b 1

        set "profile_line_nr=!line_nr!"
        set "profile_name=!line:~0,-1!"
        call :set_profile_type || ( call :error_29 & exit /b 1 )
        call :get_profile_services || ( call :error_30 & exit /b 1 )
        call :index_profile_data || exit /b 1

    ) else if "!line:~0,9!"=="[services" (

        if "!line:~9,1!" neq " " ( call :error_24 & exit /b 1 )
        set "line=!line:~10!"
        call :validate_header_step2 || exit /b 1

    ) else if "!line:~0,12!"=="[sso-session" (

        if "!line:~12,1!" neq " " ( call :error_24 & exit /b 1 )
        set "line=!line:~13!"
        call :validate_header_step2 || exit /b 1

    ) else (
        call :error_28
        exit /b 1
    )

)
goto :eof



:: List profiles in credentials file to assist in determining IAM-User profile types.
:: This subroutine is invoked only when a credentials file exists.
::
::   - List all profile headers in credentials file.
::   - Validate the header character set
::   - Detect duplicate profile names
::   - Build a space-delimited list of credential profile names.
::
:: When extracting profile data in config file, profile_list_cred variable is used
:: to define profile type. Note that credentials file data is not cached.
:get_credentials_profiles
set "header_source=credentials file"
set "target_file=%CRED_FILE%"
call :validate_header_step1 || exit /b 1

set "line="
set "line_nr="
set "header_line="
for /f "usebackq tokens=1* delims=:" %%a in (`call "%FINDSTR_EXE%" /N /C:"[" "%CRED_FILE%" 2^>nul`) do ( 
    set "line_nr=%%a"
    set "line=%%b"

    set "header_line=%%b"

    if "!line:~0,1!"==" " ( call :error_21 & exit /b 1 )

    set "line=!line:~1!"
    call :validate_header_step2 || exit /b 1
    
    set "line=!line:~0,-1!"
    if defined SWA_CRED_DUP_!line! (
        call :error_19
        exit /b 1
    ) else (
        set "SWA_CRED_DUP_!line!=1"
    )
    
    set "profile_list_cred=!profile_list_cred! !line!"

)
if not defined profile_list_cred exit /b 1
goto :eof




:: Validate header character set to avoid unexpected parsing errors caused by uncommon characters.
:: Trimmed lines are used when parsing the config file to safely rely on inexpensive string substitution instead of more costly for-loops or external tools.
:: Therefore, we must ensure the character order and encoding are exactly as expected to prevent incorrect results.

:: validation step-1 using regex: exceptionally allowing colon here (line number delimiter). caret could not be detected. checking both in step2
:: temporarily disabling DelayedExpansion to detect and print the exclamation character if any
:validate_header_step1
setlocal DisableDelayedExpansion

set "header_chars="
set "invalid_char="
for /f "usebackq delims=" %%L in (`
    call "%FINDSTR_EXE%" /N /C:"[" "%target_file%" ^| call "%FINDSTR_EXE%" /R /C:"[^A-Za-z0-9 ._\-\[\\\]:]"
`) do (
    set header_chars=%%L
    if defined header_chars (
        call :error_22
        set "header_chars="
        set "invalid_char=1"
    )

) 
if defined invalid_char ( call :info_3 & exit /b 1 )
endlocal
goto :eof


:: validation step-2 using iteration: checking length and other invalid characters
:validate_header_step2
set "ch="
set "found_cb="
set "header_chars="

for /L %%i in (0,1,65) do (

    set "ch=!line:~%%i,1!"
    if "!ch!" neq "" (

        if %%i gtr 64 ( call :error_25 & exit /b 1 )

        :: checking extra characters at end
        if "!ch!"=="]" (
            set "found_cb=1"
            if "!line:~%%i,2!" neq "]" (
                call :error_26
                exit /b 1
            )
        )

        :: checking space within the name of header e.g. [profile testing site]
        if "!ch!"==" " ( 
            set "header_chars=!line:~0,-1!"
            call :error_27
            exit /b 1
        )
        
        :: checking caret and colon that were not checked in regex step
        if "!ch!"=="^" ( 
            set "header_chars=!line_nr! !line:~0,-1!"
            call :error_22
            call :info_3
            exit /b 1 
        )
        if "!ch!"==":" ( 
            set "header_chars=!line_nr! !line:~0,-1!"
            call :error_22
            call :info_3
            exit /b 1
        )


    ) else (

        :: checking if closing bracket exists at all
        if not defined found_cb (
            call :error_28
            exit /b 1
        )
        
        exit /b 0
    
    )

)
goto :eof


:: This subroutine detects any service sections or indented service identifiers 
:: belonging to that profile.
::
:: Workflow:
::   1. Initialize a per-service counter for all known AWS services
::      listed in aws_services_list.
::   2. Read values under the target profile
::   3. For each service identifier, increment its occurrence counter.
::   4. Pair service_id and its count in the following format:
::
::        service_1:count service_2:count ... service_N:count
::
:: resulting profile_services string is appended to the corresponding
:: profile data line in SWA_PDATA_{N} variable and later written to profiles cache.
:get_profile_services
for %%S in (%aws_services_list%) do set "%%S_count=0"

set "line="
set "srv_id="
set "profile_services="
for /f "skip=%profile_line_nr% usebackq tokens=* delims=" %%s in ("%CONF_FILE%") do (
    set "line=%%s"
    set "line=!line: =!"

    if "!line!"=="[default]" goto :srv_stats
    if "!line:~0,8!"=="[profile" goto :srv_stats

    set "srv_id=!line:~0,-1!"
    for %%S in (%aws_services_list%) do if "%%S"=="!srv_id!" set /a !srv_id!_count+=1

)

    :srv_stats
    for %%S in (%aws_services_list%) do (
        for /f %%C in ("!%%S_count!") do ( 
            if %%C gtr 0 set "profile_services=!profile_services! %%S:%%C"
        )
    )

goto :eof



:: set_profile_type determines profile’s type during cache-building process.
::
:: workflow:
::  1. Credentials file lookup
::     - If credentials file exists, all profile names are stored in profile_list_cred in previous steps.
::     - If target profile name (extracted from config file) is found in this list,
::       the profile is classified as an IAM user and subroutine exits immediately.
::
::  2. Config file lookup
::     - If target profile is not found in credentials file, corresponding profile section is scanned in config.
::     - Presence of specific keys determines the profile type.
::
:: Profile type short forms:
::  - iam : IAM User
::  - sso : Single Sign-On
::  - ars : AssumeRole (source_profile)
::  - arc : AssumeRole (credential_source)
::  - web : Web Identity
::  - ext : External credential process
:set_profile_type
set "profile_type="

if defined profile_list_cred (

    for %%P in (%profile_list_cred%) do (           
    
        if "!profile_name!"=="%%P" set "profile_type=iam" && exit /b 0
    
    )

)

set "line="
for /f "skip=%profile_line_nr% usebackq tokens=1 delims==" %%a in ("%CONF_FILE%") do (
    set "line=%%a"
    set "line=!line: =!"

    if "!line:~0,1!"=="[" goto :validate_profile_type
    
    if "!line!"=="aws_access_key_id" (
        set "profile_type=iam"
    ) else if "!line!"=="sso_account_id" (
        set "profile_type=sso"
    ) else if "!line!"=="source_profile" ( 
        set "profile_type=ars"
    ) else if "!line!"=="credential_source" ( 
        set "profile_type=arc"
    ) else if "!line!"=="web_identity_token_file" ( 
        set "profile_type=web"
    ) else if "!line!"=="credential_process" ( 
        set "profile_type=ext" 
    )
    
)

:validate_profile_type
if not defined profile_type exit /b 1
goto :eof



:: Load profile data from the profiles cache and prompt user to select one.
:: If swa is invoked with -l or --list, the cached profiles and their data
:: are printed and subroutine exits without prompting.
:: Otherwise, the user is prompted to select a profile from the cached list.
::
:: After selection, the following values are resolved and exported to variables
:: for use in subsequent steps:
::   - AWS_PROFILE
::   - profile_type
::   - profile_line_nr
::   - profile_services
::
:: If service data exists for the selected profile, individual service identifiers
:: and their counts are extracted for later use.
:set_profile
if "%FLAG_LISTING%"=="1" call :list_profiles & exit /b 2

set "profile_list="
set "profile_type="
set "profile_line_nr="
set "profile_services="
set "select_item_count=0"

for /f "skip=1 usebackq tokens=1-3*" %%a in ("%PROFILES_CACHE%") do (
    set "profile_list=!profile_list! %%a"
    set "%%a_profile_type=%%b"
    set "%%a_profile_line_nr=%%c"
    set "%%a_profile_services=%%d"
    set /a select_item_count+=1
)

if not defined profile_list ( call :error_31 & exit /b 1 )

set "select_msg=%MSG_PREFIX% Select a profile:"
call :select_prompt 1 profile_list profile_selection || ( call :info_7 & exit /b 1 )

set "AWS_PROFILE=!selected!"
set "profile_type=!%AWS_PROFILE%_profile_type!"
set "profile_line_nr=!%AWS_PROFILE%_profile_line_nr!"
set "profile_services=!%AWS_PROFILE%_profile_services!"

set "svid="
set "svct="
set "profile_service_ids="
set "profile_services_sum=0"
if defined profile_services (
    
    for %%S in (%profile_services%) do (
        for /f "tokens=1,2 delims=:" %%x in ("%%S") do (
            set "svid=%%x"
            set "svct=%%y"
            set "profile_service_ids=!profile_service_ids! !svid!"
            set "SWA_SVCOUNT_!svid!=!svct!"
        )
        set /a profile_services_sum+=svct
    )
    set "profile_service_ids=!profile_service_ids:~1!"

)

if not defined profile_type ( call :error_32 & exit /b 1 )
if not defined profile_line_nr ( call :error_32 & exit /b 1 )
goto :eof



:: Main dispatcher to get config values for the selected profile.
:get_configs
if "%profile_type%"=="sso" (
    call :sso_login "%AWS_PROFILE%" || exit /b 1

) else if "%profile_type%"=="iam" (

    call :iam_global_config || ( call :error_37 & exit /b 1 )
    
    if "%FLAG_MFA%"=="1" call :mfa_login

    if %profile_services_sum% gtr 0 ( call :iam_service_config || exit /b 1 )
    
    call :verify_iam_config || exit /b 1


) else if "%profile_type%"=="ars" (

    if "%FLAG_MFA%"=="1" call :mfa_login

)
call :check_flag || exit /b 1
goto :eof





:: Invoked when the -m / --mfa option is used.
:: Checks for mfa_serial in the selected profile and prompts for MFA login.
:: If declined or MFA-Login is unsuccessful, workflow continues without a hard error.
:mfa_login
set "USE_MFA="
set "line="
for /f "skip=%profile_line_nr% usebackq tokens=* delims=" %%L in ("%CONF_FILE%") do (
    set "line=%%L"
    set "line=!line: =!"

    if "!line:~0,1!"=="[" goto :after_mfa_check

    for %%M in (%profile_service_ids%) do if "!line:~0,-1!"=="%%M" goto :after_mfa_check

    if "!line:~0,11!"=="mfa_serial=" set "USE_MFA=1"

)

    :after_mfa_check
    if defined USE_MFA (

        gum.exe confirm "%MSG_PREFIX% %GREEN%%AWS_PROFILE%%RESET% profile is using MFA option. Invoke 'aws configure mfa-login' ?" || exit /b 0
        aws.exe configure mfa-login --profile "%AWS_PROFILE%" && call :info_30
        exit /b 0

    ) else (
        call :info_31
    )

goto :eof




:: Validates authentication state of SSO profile and invokes SSO login if required.
:sso_login
set "SWA_SSO_PROFILE=%~1"
call :get_caller_identity "%SWA_SSO_PROFILE%" && ( call :info_8 & exit /b 0 ) || (
  
    call :info_9
    gum.exe confirm "Invoke 'aws sso login' ?" || exit /b 0

)
aws.exe sso login --no-browser --profile "%SWA_SSO_PROFILE%" && call :info_10 || call :error_34
goto :eof






:: Below subroutine serves as an authentication check for both
:: credential-based and SSO-based profiles by invoking the STS GetCallerIdentity API.
::
:: Workflow:
::  1. Temporarily unset AWS_ENDPOINT_URL (if defined) to ensure that 
::     the STS call is routed using AWS official credentials.
::  2. Invoke `aws sts get-caller-identity` and capture both
::     stdout (user's ARN) and stderr (for error message if failed).
:get_caller_identity
set "SWA_ID_PROFILE=%~1"
if defined AWS_ENDPOINT_URL set "SWA_BACKUP_URL=!AWS_ENDPOINT_URL!" && set "AWS_ENDPOINT_URL="

for /f "usebackq tokens=*" %%i in (`
    aws.exe sts get-caller-identity --profile "%SWA_ID_PROFILE%" --query "Arn" --output text 2^>^&1`
) do set "SWA_ARN=%%i"

if defined SWA_BACKUP_URL set "AWS_ENDPOINT_URL=!SWA_BACKUP_URL!" && set "SWA_BACKUP_URL="
if "%SWA_ARN:~0,3%" neq "arn" exit /b 1
goto :eof






:: Read global config values for IAM user profiles.
:: It scans profile’s section to extracts only below global values:
::   - region
::   - ca_bundle
::   - endpoint_url
::
:: Notes:
::   - ca_bundle value is intentionally stored in SWA_CA at this stage.
::     AWS_CA_BUNDLE environment variable is exported later only if CA_REQUIRED is set to 1.
::   - CA_REQUIRED becomes 1 when a ca_bundle is defined in the profile and it exists
::     or when -u option (verify_url subroutine) is used and, in verify_url step,
::     it is determined that the endpoint requires certificate.
:iam_global_config
set "line="
for /f "skip=%profile_line_nr% usebackq tokens=* delims=" %%L in ("%CONF_FILE%") do (
    set "line=%%L"
    set "line=!line: =!"

    if "!line:~0,1!"=="[" exit /b 0

    for %%M in (%profile_service_ids%) do if "!line:~0,-1!"=="%%M" exit /b 0

    if "!line:~0,7!"=="region=" set "AWS_REGION=!line:~7!"
    if "!line:~0,10!"=="ca_bundle=" set "SWA_CA=!line:~10!"
    if "!line:~0,13!"=="endpoint_url=" set "AWS_ENDPOINT_URL=!line:~13!"

)
goto :eof




:: Read service-specific config values for IAM user profiles.
::
:: This subroutine is invoked only when the selected profile defines one or more
:: service identifiers (profile_services_sum > 0).
:iam_service_config
if "!profile_services_sum!"=="1" (

    gum.exe confirm "%MSG_PREFIX% %BRIGHT_WHITE%!profile_service_ids!%RESET% service found. Set values?" || exit /b 0
    set "service_id=!profile_service_ids!"
    call :get_service_values || exit /b 1
    exit /b 0

)

set "select_msg=%MSG_PREFIX% %BRIGHT_WHITE%!profile_services_sum!%RESET% services found. Select (use Tab):"
set "select_item_count=!profile_services_sum!"
call :select_prompt 2 profile_service_ids service_selection || exit /b 0

for %%a in (%selected%) do (
    set "service_id="
    set "service_id=%%a"
    call :get_service_values || exit /b 1
)
set "select_item_count="
goto :eof



:get_service_values
set "skipLine=0"
set "select_item_count=0"

:: If there is only one instance of the target service_id,
:: skip section listing and jump to the step of setting values of the service_id.
if "!SWA_SVCOUNT_%service_id%!"=="1" (
    set skipLine=%profile_line_nr%
    goto :after_section_selection
)

:: Build service-sections list for selection when there are more than one
:: instance of the target service_id for the selected profile.
set "section_list="
set "selected="
set "skip_op="
set "scope="
set "line="
set "line_nr="
    
if !profile_line_nr! gtr 1 set /a skipLine=profile_line_nr-1
if !skipLine! gtr 1 set "skip_op=skip=!skipLine!"

for /f "%skip_op% usebackq tokens=1* delims=:" %%L in (`call "%FINDSTR_EXE%" /N ^^^^ "%CONF_FILE%" 2^>nul`) do (
    set "line_nr=%%L"
    set "line=%%M"
    set "line=!line: =!"

    if "!line!"=="[default]" (

        if "!AWS_PROFILE!" neq "default" goto :select_section
        set "service_seen=0"
        set "scope=Profile"
        set "section_name=default"
        set "SWA_LNR_!section_name!=!line_nr!"

    ) else if "!line:~0,8!"=="[profile" (

        if "!line!" neq "[profile!AWS_PROFILE!]" goto :select_section
        set "service_seen=0"
        set "scope=Profile"
        set "section_name=!AWS_PROFILE!"
        set "SWA_LNR_!section_name!=!line_nr!"
  
    ) else if "!line:~0,9!"=="[services" (
        set "service_seen=0"
        set "scope=Service"
        set "section_name=!line:~9,-1!"
        set "SWA_LNR_!section_name!=!line_nr!"

    )

    if "!line!"=="!service_id!=" (

        if "!service_seen!"=="1" ( call :error_38 & exit /b 1 )
        set "service_seen=1"

        if "!scope!"=="Profile" set "header_name=Profile: !section_name!"
        if "!scope!"=="Service" set "header_name=Service: !section_name!"
        
        set "section_list=!section_list! "!header_name!""
        set /a select_item_count+=1

    )

)

    :select_section
    if not defined section_list ( call :error_39 & exit /b 1 )

    set "select_msg=%MSG_PREFIX% Multiple %BRIGHT_WHITE%!service_id!%RESET% services found. Select one:"
    call :select_prompt 1 section_list !service_id!_service_sections || exit /b 0
    set "skipLine=!SWA_LNR_%selected:~9%!"


    :after_section_selection
    set "in_block=0"
    set "line="
    set "trimmed_line="
    set "SERVICE_REGION="
    set "SERVICE_ENDPOINT="
    for /f "skip=%skipLine% usebackq tokens=* delims=" %%L in ("%CONF_FILE%") do (
        set "line=%%L"
        set "trimmed_line=!line: =!"

        if "!in_block!"=="1" (

            if "!trimmed_line!" neq "!service_id!=" (
                if "!line:~0,1!" neq " " goto :validate_service_values
            )

            if "!trimmed_line:~0,7!"=="region=" set "SERVICE_REGION=!trimmed_line:~7!"
            if "!trimmed_line:~0,13!"=="endpoint_url=" set "SERVICE_ENDPOINT=!trimmed_line:~13!"
                 
        )

        if "!trimmed_line!"=="!service_id!=" set "in_block=1"

    )

    :validate_service_values
    if defined SERVICE_ENDPOINT (
        call :to_uppercase service_id
        set "AWS_ENDPOINT_URL_!service_id!=!SERVICE_ENDPOINT!"
    ) else (
        call :info_23
    )

    if defined SERVICE_REGION (
        set "SWA_REGIONS=!SWA_REGIONS! !SERVICE_REGION!"
    )

goto :eof



:: Verify values extracted for IAM User profile
:: If s3 endpoint_url is required (-i -3 -5 options) but not explicitly defined in config file,
:: below subroutines are called to define s3 endpoint_url.
:verify_iam_config
if not defined AWS_ENDPOINT_URL (
    if not defined AWS_ENDPOINT_URL_S3 (

        if "!FLAG_VERIFY_URL!"=="1" ( call :info_12 & set "FLAG_VERIFY_URL=-1" )

        if "!FLAG_MINIO!"=="1" set "URL_REQUIRED=1"
        if "!FLAG_S3CMD!"=="1" set "URL_REQUIRED=1"
        if "!FLAG_S5CMD!"=="1" set "URL_REQUIRED=1"
        
        if "!URL_REQUIRED!"=="1" (
           call :info_24
           call :get_caller_identity "!AWS_PROFILE!" || (
                call :error_33 
                call :info_27
                exit /b 1 
           )
           call :set_aws_s3_url || exit /b 1
        )

    )

)

:: If ca_bundle defined in config file exists, set CA_REQUIRED to 1 to export it at the end
:: If ca_bundle defined but not exist, invoke verify_url to check requirement and download it.
:: If verify_url exits successfully, set related flag to -1 to avoid invoking same step again
:: at check_flag subroutine in case -u option is used.
if defined SWA_CA (
    if exist "!SWA_CA!" (
       set "CA_REQUIRED=1"

    ) else (

       call :info_29
       call :verify_url || exit /b 1
       set "FLAG_VERIFY_URL=-1"

    )

)

:: If regions found under global and service-specific settings are different, user is prompted to select one.
if defined AWS_REGION (
    if defined SWA_REGIONS (
        call :set_unique_list SWA_REGIONS
        for %%R in (!SWA_REGIONS!) do (
            if /i "!AWS_REGION!" neq "%%R" (
                set "SWA_REGION_SELECT=1"
                set "REGIONS_OPT=!REGIONS_OPT! "Service Region: %%R""
            )

        )

    )

)

if defined SWA_REGION_SELECT (
 
    set "REGIONS_OPT=" Global Region: !AWS_REGION!" !REGIONS_OPT!"
    set "select_msg=%MSG_PREFIX% Different regions found. Select one:"
    call :select_prompt 1 REGIONS_OPT region_selection && set "AWS_REGION=!selected:~16!"

)
goto :eof






:: check_flag evaluates user-specified command-line flags and dispatches execution to
:: the corresponding subroutines.
::
:: Notes:
::  - The profile listing flag (-l / --list) is intentionally evaluated at the start of 
::    the set_profile subroutine. set_profile is the first entry point after startup initialization 
::    and before first user interaction.
:check_flag
if "%FLAG_CREDENTIALS%"=="1" (

    if "%profile_type%"=="arc" (
       call :get_credentials_option || exit /b 1
       if defined assumerole_crd_pn (
            call :export_credentials "!assumerole_crd_pn!" || ( call :error_75 & exit /b 1 )
       )

    ) else (
       call :export_credentials "%AWS_PROFILE%" || ( call :error_75 & exit /b 1 )
    )

)

if "%FLAG_VERIFY_URL%"=="1" (

    if "%profile_type%"=="iam" (
       call :verify_url || exit /b 1
    ) else (
       call :info_11
    )

)

if "%FLAG_S5CMD%"=="1" (
    if "%profile_type%" neq "iam" call :set_s5cmd || exit /b 1 
)

if "%FLAG_S3CMD%"=="1" call :set_s3cmd || exit /b 1
if "%FLAG_MINIO%"=="1" call :set_minio || exit /b 1
goto :eof



:: This subroutine is invoked only by set_aws_s3_url before setting s3 endpoint_url.
:: It checks whether target profile has FIPS or Dualstack options enabled.
:: If either option is enabled, it sets a flag that is used later to determine appropriate endpoint_url.
:get_fips_dualstack
set "line="
set "USE_FIPS="
set "USE_DUALSTACK="
for /f "skip=%profile_line_nr% usebackq tokens=* delims=" %%L in ("%CONF_FILE%") do (
    set "line=%%L"
    set "line=!line: =!"

    if "!line:~0,1!"=="[" exit /b 0

    for %%M in (%profile_service_ids%) do (
        if "!line:~0,-1!"=="%%M" exit /b 0
    )

    if "!line:~0,18!"=="use_fips_endpoint=" ( 
        if /i "!line:~18!"=="true" set "USE_FIPS=1"
    )
    
    if "!line:~0,23!"=="use_dualstack_endpoint=" ( 
        if /i "!line:~23!"=="true" set "USE_DUALSTACK=1"
    )
    
)
goto :eof



:: If s3 endpoint_url is required but not explicitly defined in the config,
:: below subroutine derives correct s3_endpoint_url based on user's ARN via
:: STS which detects one of below AWS partitions:
::   - aws        (commercial)
::   - aws-us-gov (GovCloud)
::   - aws-cn     (China)
::
:: Meanwhile, if FIPS or DualStack options are set to true for the selected profile,
:: resulting endpoint_url considers those options as well (via get_fips_dualstack subroutine)
:: and, if region is not defined in config file, default region of AWS partition is assigned.
::
:: This logic applies only to official AWS credentials. Custom s3 services must define 
:: endpoint_url explicitly in config file.
:set_aws_s3_url
if not defined SWA_ARN ( call :get_caller_identity "%AWS_PROFILE%" || ( call :error_33 & exit /b 1 ) )

call :get_fips_dualstack

if "!SWA_ARN:~0,8!"=="arn:aws:" (

    if not defined AWS_REGION set "AWS_REGION=us-east-1"

    if defined USE_FIPS (

        if defined USE_DUALSTACK (
           set "AWS_ENDPOINT_URL_S3=https://s3-fips.dualstack.!AWS_REGION!.amazonaws.com"
        ) else (
           set "AWS_ENDPOINT_URL_S3=https://s3-fips.!AWS_REGION!.amazonaws.com"
        )

    ) else if defined USE_DUALSTACK (
       set "AWS_ENDPOINT_URL_S3=https://s3.dualstack.!AWS_REGION!.amazonaws.com"
    )
    
    if not defined AWS_ENDPOINT_URL_S3 (
       set "AWS_ENDPOINT_URL_S3=https://s3.!AWS_REGION!.amazonaws.com"
    )


) else if "!SWA_ARN:~0,15!"=="arn:aws-us-gov:" (

    if not defined AWS_REGION set "AWS_REGION=us-gov-west-1"

    if defined USE_FIPS (

        if defined USE_DUALSTACK (
           set "AWS_ENDPOINT_URL_S3=https://s3-fips.dualstack.!AWS_REGION!.amazonaws.com"
        ) else (
           set "AWS_ENDPOINT_URL_S3=https://s3-fips.!AWS_REGION!.amazonaws.com"
        )

    ) else if defined USE_DUALSTACK (
       set "AWS_ENDPOINT_URL_S3=https://s3.dualstack.!AWS_REGION!.amazonaws.com"
    )

    if not defined AWS_ENDPOINT_URL_S3 (
       set "AWS_ENDPOINT_URL_S3=https://s3.!AWS_REGION!.amazonaws.com"
    )
  

) else if "!SWA_ARN:~0,11!"=="arn:aws-cn:" (

    if not defined AWS_REGION set "AWS_REGION=cn-north-1"
    
    if defined USE_DUALSTACK (
       set "AWS_ENDPOINT_URL_S3=https://s3.dualstack.!AWS_REGION!.amazonaws.com.cn"
    ) 
    
    if not defined AWS_ENDPOINT_URL_S3 (
       set "AWS_ENDPOINT_URL_S3=https://s3.!AWS_REGION!.amazonaws.com.cn"
    )

)

if not defined AWS_ENDPOINT_URL_S3 ( call :error_40 & exit /b 1 )

call :set_target_s3_url
goto :eof




:: Below subroutine defines effective s3_endpoint_url which is used internally.
:set_target_s3_url
if defined AWS_ENDPOINT_URL_S3 (
    set "SWA_TARGET_S3URL=!AWS_ENDPOINT_URL_S3!"
    set "s3url_source=SERVICE"
) else (
    set "SWA_TARGET_S3URL=!AWS_ENDPOINT_URL!"
    set "s3url_source=GLOBAL"
)

if not defined SWA_TARGET_S3URL ( call :error_40 & exit /b 1 )

set "HOST_BASE="
if /i "!SWA_TARGET_S3URL:~0,6!"=="https:" (
    set "HOST_BASE=!SWA_TARGET_S3URL:~8!"
) else (
    set "HTTP=1"
    set "HOST_BASE=!SWA_TARGET_S3URL:~7!"
)
goto :eof


:: Invoked when -c, -i or -3 option is used.
:: export_credentials exports AWS credentials for the specified profile using
:: the `aws configure export-credentials` command.
::
:: Each output line is validated to ensure it begins with `set` before being
:: executed via `call`, preventing execution if there is error.
:export_credentials
set "SWA_CRED_PROFILE=%~1"
set "line="
for /f "usebackq delims=" %%A in (`
    aws.exe configure export-credentials --profile "%SWA_CRED_PROFILE%" --format windows-cmd 2^>^&1`
) do (
    set "line=%%A"
    if /i "!line:~0,3!"=="set" (
        call %%A
    ) else (
        exit /b 1
    )
)
if not defined AWS_ACCESS_KEY_ID exit /b 1
if not defined AWS_SECRET_ACCESS_KEY exit /b 1
goto :eof


:mask_credentials
if defined AWS_ACCESS_KEY_ID (
    if not "!AWS_ACCESS_KEY_ID:~8!"=="" (
        set "MASKED_ACCESS_KEY=!AWS_ACCESS_KEY_ID:~0,4!**********!AWS_ACCESS_KEY_ID:~-4!"
    ) else (
        set "MASKED_ACCESS_KEY=!AWS_ACCESS_KEY_ID!"
    )
)
if defined AWS_SECRET_ACCESS_KEY (
    if not "!AWS_SECRET_ACCESS_KEY:~8!"=="" (
        set "MASKED_SECRET_KEY=!AWS_SECRET_ACCESS_KEY:~0,4!**********!AWS_SECRET_ACCESS_KEY:~-4!"
    ) else (
        set "MASKED_SECRET_KEY=!AWS_SECRET_ACCESS_KEY!"
    )
)
if defined AWS_SESSION_TOKEN (
    if not "!AWS_SESSION_TOKEN:~8!"=="" (
        set "MASKED_TOKEN=!AWS_SESSION_TOKEN:~0,4!**********!AWS_SESSION_TOKEN:~-4!"
    ) else (
        set "MASKED_TOKEN=!AWS_SESSION_TOKEN!"
    )
)
goto :eof








:: Get credentials option prepares credentials for AssumeRole-based profiles when credentials
:: are required e.g. -c, -i, -3 options.
::
:: This subroutine is invoked when AssumeRole profile is using credential_source.
:: First, it verifies if Environment option is used then:
::
::     * If valid credential environment variables already exist in the shell,
::       user is prompted to use them.
::     * Otherwise, user is prompted to select another profile (excluding arc
::       profiles) to supply credentials.
::
:: If selected credential profile is of type SSO and the SSO session
:: is not authenticated or has expired, user is prompted to perform an SSO login.
:get_credentials_option
set "cred_option_value="
set "assumerole_crd_pn="
set "assumerole_crd_pt="
for /f "skip=%profile_line_nr% usebackq tokens=1* delims==" %%A in ("%CONF_FILE%") do (
    set "opt=%%A"
    set "val=%%B"
    set "trimmed_opt=!opt: =!"
    set "trimmed_val=!val: =!"

    if "!trimmed_opt!"=="credential_source" set "cred_option_value=!trimmed_val!"
    if "!trimmed_opt:~0,1!"=="[" goto :verify_cred_option

)
    :verify_cred_option
    if not defined cred_option_value ( call :error_72 & exit /b 1 )
       
    if /i "!cred_option_value!"=="Environment" (
        call :info_26
        call :get_existing_credentials_envs && exit /b 0
        call :assumerole_credentials_source || exit /b 1
    ) else (
        call :error_71 & exit /b 1
    )

    

    if "!assumerole_crd_pt!"=="sso" (
        call :info_25
        call :sso_login "!assumerole_crd_pn!" || exit /b 1
    )

goto :eof



:: If AssumeRole profile is using credentials_source option with Environment value,
:: create a list of profiles excluding profiles of the same type to prompt user for selection.
:assumerole_credentials_source
set "filtered_list="
set "select_item_count=0"
for %%a in (!profile_list!) do (

    if "!%%a_profile_type!" neq "arc" ( 
        set "filtered_list=!filtered_list! %%a"
        set /a select_item_count+=1
    )

)

if not defined filtered_list ( call :error_73 & exit /b 1 )

call :info_28
set "select_msg=%MSG_PREFIX% Select profile:"
call :select_prompt 1 filtered_list credentials_profile || exit /b 1
set "assumerole_crd_pn=!selected!"
set "assumerole_crd_pt=!%assumerole_crd_pn%_profile_type!"
goto :eof



:: If AssumeRole profile is using credentials_source option with
:: Environment value and, AWS credentials already exists in envirnoment,
:: first prompt to ask if user prefers to use those.
:get_existing_credentials_envs
if defined SWA_ACCESS_KEY if defined SWA_SECRET_KEY if defined SWA_SESSION_TOKEN (
    gum.exe confirm "%MSG_PREFIX% AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY and AWS_SESSION_TOKEN exist in environment. Use them?" || exit /b 1
    set "AWS_ACCESS_KEY_ID=!SWA_ACCESS_KEY!"
    set "AWS_SECRET_ACCESS_KEY=!SWA_SECRET_KEY!"
    set "AWS_SESSION_TOKEN=!SWA_SESSION_TOKEN!"
    exit /b 0
)
if defined SWA_ACCESS_KEY if defined SWA_SECRET_KEY ( 
    set "line="
    gum.exe confirm "%MSG_PREFIX% AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY exist in environment. Use them?" || exit /b 1
    set "AWS_ACCESS_KEY_ID=!SWA_ACCESS_KEY!"
    set "AWS_SECRET_ACCESS_KEY=!SWA_SECRET_KEY!"
    exit /b 0
)
exit /b 1








:: Main dispatcher responsible for validating access to s3_endpoint_url and whether it requires CA Bundle.
::
:: Invoked when endpoint verification is required (e.g. -u, -i, -3).
:: It determines whether endpoint uses HTTPS or HTTP and whether a custom CA bundle is required.
:: if CA Bundle is already defined in config file, validates it.
::
:: Workflow:
::   1. Resolve effective S3 endpoint URL.
::   2. If HTTPS is used:
::        - If a CA bundle was defined in config file (CA_REQUIRED=1), validate it.
::        - Otherwise, attempt HTTPS connection.
::   3. If endpoint is already using HTTP (HTTP=1), attempt HTTP connection.
:verify_url
call :set_target_s3_url || exit /b 1

set "CURL_OPTS=-q -s -o nul --connect-timeout 5 --max-time 10"

if "!HTTP!"=="0" (
    if "!CA_REQUIRED!"=="1" (
        call :verify_config_ca || exit /b 1
    ) else (
        call :check_https || exit /b 1
    )

) else (     
    call :check_http || exit /b 1
)
goto :eof

:: Attempts to connect to endpoint_url over HTTPS.
::
:: curl exit code determines next step:
::   - 0 : Connection succeeded → retrieve HTTP status code for basic server-side validation.
::   - 6 : Host resolution failure → hard error.
::   - 7 : Could not connect to host with HTTPS → fall back to HTTP → 
::          - if failed, hard error.
::          - if HTTP succeed, marks endpoint as HTTP and update endpoint_url
::   - other (either 35 or 60):
::       Assume TLS or certificate-related failure and attempt to retrieve a CA bundle.
:check_https
set "rc="
"%CURL_EXE%" %CURL_OPTS% "%SWA_TARGET_S3URL%"
set "rc=%errorlevel%"
if "%rc%"=="0" (
    if "!FLAG_VERIFY_URL!"=="1" call :info_13
    call :get_http_code

) else if "%rc%"=="6" (
    call :error_45
    exit /b 1

) else if "%rc%"=="7" (
    call :info_14
    call :check_http || ( call :error_46 & exit /b 1 )
    call :info_18

) else (
    call :info_15
    call :download_ca_bundle || exit /b 1
    call :get_http_code
)
goto :eof


:: This is used when HTTPS is unavailable or rejected by the server or when endpoint is using HTTP explicitly.
:: curl exit code determines next step:
::   - 0 :  Marks endpoint as HTTP.
::          Updates effective endpoint depending on its source (global or service-specific).
::          Retrieves HTTP status code for server-side validation.
::   - other → hard error
:check_http
set "rc="
"%CURL_EXE%" %CURL_OPTS% "http://%HOST_BASE%"
set "rc=%errorlevel%"
if "%rc%"=="0" (
    
    set "HTTP=1"
    call :get_http_code
    if "!s3url_source!"=="GLOBAL" (
       set "AWS_ENDPOINT_URL=http://!HOST_BASE!"
    ) else (
       set "AWS_ENDPOINT_URL_S3=http://!HOST_BASE!"
    )

) else (
    call :error_48
    exit /b 1
)
goto :eof


:: Checking only common server-side errors 500, 502, 503, 504 using curl query
:: All status codes are considered acceptable and do not block further processing.
:get_http_code
if "!HTTP!"=="0" (
    if "!CA_REQUIRED!"=="1" (
       set "CURL_QUERY="%CURL_EXE%" %CURL_OPTS% --ssl-revoke-best-effort -w %%{http_code} --cacert "!SWA_CA!" "!SWA_TARGET_S3URL!""
    ) else (
       set "CURL_QUERY="%CURL_EXE%" %CURL_OPTS% --ssl-revoke-best-effort -w %%{http_code} "!SWA_TARGET_S3URL!""
    )        
) else (
    set "CURL_QUERY="%CURL_EXE%" %CURL_OPTS% -w %%{http_code} "http://!HOST_BASE!""
)
for /f "usebackq delims=" %%i in (`call %CURL_QUERY%`) do set "HTTP_CODE=%%i"
if not defined HTTP_CODE exit /b 0
if "!HTTP_CODE!"=="500" ( call :error_41 & exit /b 0 )
if "!HTTP_CODE!"=="502" ( call :error_42 & exit /b 0 )
if "!HTTP_CODE!"=="503" ( call :error_43 & exit /b 0 )
if "!HTTP_CODE!"=="504" ( call :error_44 & exit /b 0 )
goto :eof


:: Verifies HTTPS connectivity using a CA bundle provided in the config file.
::
:: curl exit code determines next step:
::   - 0 : CA is valid → continue and evaluate HTTP status code.
::   - 77: CA file missing or invalid → attempt to download new CA bundle.
::   - 6 : Host resolution failure → hard error.
::   - 7 : Could not connect to host with HTTPS → fall back to HTTP → 
::          - if failed, hard error.
::          - if HTTP succeed, marks the endpoint as HTTP and update endpoint_url
::   - other → hard error
:verify_config_ca
set "rc="
"%CURL_EXE%" %CURL_OPTS% --ssl-revoke-best-effort --cacert "%SWA_CA%" "%SWA_TARGET_S3URL%"
set "rc=%errorlevel%"
if "%rc%"=="0" (
    call :info_16
    call :get_http_code

) else if "%rc%"=="77" (
    call :info_17
    call :download_ca_bundle || exit /b 1
    call :get_http_code

) else if "%rc%"=="6" (
    call :error_45
    exit /b 1

) else if "%rc%"=="7" (
    call :info_14
    call :check_http || ( call :error_46 & exit /b 1 )
    call :info_18

) else (
    call :error_47
    exit /b 1
)
goto :eof


:: Downloads new CA bundle when the endpoint uses a self-signed or invalid certificate.
:: This subroutine is invoked when HTTPS is required and configured CA bundle is missing, 
:: invalid, or not trusted.
::
:: Workflow:
::   1. Ensure local certificate directory exists.
::   2. Download full certificate chain from endpoint.
::   3. Extract certificate blocks from raw certificate and store it in a PEM file.
::   4. Validate HTTPS connectivity using the new CA bundle.
::   5. Add new CA bundle path into config file for selected profile.
:download_ca_bundle
set "CA_REQUIRED=1"
set "CERT_DIR=%CONF_DIR%certs"
if not exist "%CERT_DIR%" ( 
    mkdir "%CERT_DIR%" >nul 2>&1 || (
        call :error_49
        exit /b 1 
    )
)

set "CA_FILENAME=%HOST_BASE%"
set "CA_FILENAME=%CA_FILENAME::=-%"
set "SWA_CA=%CERT_DIR%\%CA_FILENAME%-chain.pem"
set "RAW_CERT=%CERT_DIR%\raw_cert.txt"

copy nul "%RAW_CERT%" >nul 2>&1 || (
    call :error_50
    exit /b 1
)

set "rc="
:: Intentionally extracting certificates in two steps (instead of piping) for better error handling
"%CURL_EXE%" %CURL_OPTS% -k -w %%{certs} "%SWA_TARGET_S3URL%" > "%RAW_CERT%"
set "rc=%errorlevel%"
if "%rc%"=="0" (
    call :info_19
) else (
    call :error_51
    exit /b 1
)

set "rc="
set "IGNORE_LINE=Subject Issuer Version Serial Signature Start Expire Public ecPublicKey X509 RSA rsa("
"%FINDSTR_EXE%" /B /V "%IGNORE_LINE%" "%RAW_CERT%" > "%SWA_CA%"
set "rc=%errorlevel%"
if "%rc%"=="0" (
    call :info_20
) else (
    call :error_52
    exit /b 1
)

set "rc="
"%CURL_EXE%" %CURL_OPTS% --ssl-revoke-best-effort --cacert "%SWA_CA%" "%SWA_TARGET_S3URL%"
set "rc=%errorlevel%"
if "%rc%"=="0" (
    call :info_21
) else (
    call :error_53
    exit /b 1
)

set "rc="
aws.exe configure set profile.%AWS_PROFILE%.ca_bundle "%SWA_CA%" 2>&1
set "rc=%errorlevel%"
if "%rc%"=="0" (
    call :info_22
) else (
    call :error_54
    exit /b 1
)
goto :eof





:: Invoked when -i option is used to updates mc MinIO client's config file for s3 alias and, 
:: prompts user to export MC_HOST_S3 envirnoment variable.
:set_minio
"%WHERE_EXE%" /q mc.exe || ( call :error_55 & exit /b 1 )

:: Verify its MinIO CLI (not Midnight Commander)
( mc.exe -v | "%FINDSTR_EXE%" MinIO >nul 2>&1 ) || ( call :error_55 & exit /b 1 )

if "%profile_type%"=="iam" (

    if not "!FLAG_VERIFY_URL!"=="-1" ( call :verify_url || exit /b 1 )
    call :export_credentials "%AWS_PROFILE%" || ( call :error_70 & exit /b 1 )
    
) else if "%profile_type%"=="arc" (

    call :get_credentials_option || exit /b 1
    
    if defined assumerole_crd_pn (
        call :export_credentials "!assumerole_crd_pn!" || ( call :error_70 & exit /b 1 )
    )
    
    call :get_region
    call :set_aws_s3_url || exit /b 1

) else (

    if "%profile_type%"=="sso" (
        call :get_sso_region || exit /b 1
    ) else (
        call :get_region 
    )

    call :export_credentials "%AWS_PROFILE%" || ( call :error_70 & exit /b 1 )
    call :set_aws_s3_url || exit /b 1

)


mc.exe alias set s3 "%SWA_TARGET_S3URL%" "%AWS_ACCESS_KEY_ID%" "%AWS_SECRET_ACCESS_KEY%" --api S3v4 --path auto >nul 2>&1 || ( 
    call :error_56
    exit /b 1
)



if "!CA_REQUIRED!"=="1" (

    set "MC_CA_DIR=%USERPROFILE%\mc\certs\CAs"
    if not exist "!MC_CA_DIR!" (
        mkdir "!MC_CA_DIR!" >nul 2>&1 || (
            call :error_68
            exit /b 1
        )
    )

    set "MC_CA_FILENAME=!HOST_BASE!"
    set "MC_CA_FILENAME=!MC_CA_FILENAME::=-!"
    set "MC_CA_BUNDLE=!MC_CA_DIR!\!MC_CA_FILENAME!-chain.pem"

    if not exist "!MC_CA_BUNDLE!" (
        
        copy "!SWA_CA!" "!MC_CA_BUNDLE!" >nul 2>&1 && (
            call :info_32
        ) || (
            call :error_69
            exit /b 1
        )

    ) else (
        call :info_33
    )

    set "CA_REQUIRED=-1"

)

gum.exe confirm "Export %BRIGHT_WHITE%MC_HOST_S3%RESET% environment variable?" && (
    
    call :mask_credentials

    if defined AWS_SESSION_TOKEN (

        if "!HTTP!"=="0" (
            set MC_HOST_S3=https://!AWS_ACCESS_KEY_ID!:!AWS_SECRET_ACCESS_KEY!:!AWS_SESSION_TOKEN!@!HOST_BASE!
            set MASKED_MC_HOST_S3=https://!MASKED_ACCESS_KEY!:!MASKED_SECRET_KEY!:!MASKED_TOKEN!@!HOST_BASE!
        ) else (
            set MC_HOST_S3=http://!AWS_ACCESS_KEY_ID!:!AWS_SECRET_ACCESS_KEY!:!AWS_SESSION_TOKEN!@!HOST_BASE!
            set MASKED_MC_HOST_S3=http://!MASKED_ACCESS_KEY!:!MASKED_SECRET_KEY!:!MASKED_TOKEN!@!HOST_BASE!
        )

    ) else (

        if "!HTTP!"=="0" (
            set MC_HOST_S3=https://!AWS_ACCESS_KEY_ID!:!AWS_SECRET_ACCESS_KEY!@!HOST_BASE!
            set MASKED_MC_HOST_S3=https://!MASKED_ACCESS_KEY!:!MASKED_SECRET_KEY!@!HOST_BASE!
        ) else (
            set MC_HOST_S3=http://!AWS_ACCESS_KEY_ID!:!AWS_SECRET_ACCESS_KEY!@!HOST_BASE!
            set MASKED_MC_HOST_S3=http://!MASKED_ACCESS_KEY!:!MASKED_SECRET_KEY!@!HOST_BASE!
        )

    )

)


echo %MSG_PREFIX% INFO: Successfully updated %YELLOW%%USERPROFILE%\mc\config.json%RESET%
if not defined MC_HOST_S3 exit /b 2

for /f "usebackq tokens=1* delims==" %%A in (`set AWS_ 2^>nul`) do set "%%A="
goto :eof




:: Invoked when -3 option is used to update config file of s3cmd.
:set_s3cmd
if "%profile_type%"=="iam" (

    if not "!FLAG_VERIFY_URL!"=="-1" ( call :verify_url || exit /b 1 )
    call :export_credentials "!AWS_PROFILE!" || ( call :error_74 & exit /b 1 )

) else if "%profile_type%"=="arc" (

    call :get_credentials_option || exit /b 1
    
    if defined assumerole_crd_pn (
       call :export_credentials "!assumerole_crd_pn!" || ( call :error_74 & exit /b 1 )

    )
    
    call :get_region
    call :set_aws_s3_url || exit /b 1

) else (

    if "%profile_type%"=="sso" ( 
       call :get_sso_region || exit /b 1
    ) else (
       call :get_region
    )

    call :export_credentials "%AWS_PROFILE%" || ( call :error_74 & exit /b 1 )
    call :set_aws_s3_url || exit /b 1

)

set "S3CMD_INI=%USERPROFILE%\AppData\Roaming\s3cmd.ini"
copy nul "%S3CMD_INI%" >nul 2>&1 || (
    call :error_57
    exit /b 1
)

> "%S3CMD_INI%" (

    echo [%AWS_PROFILE%]
    echo host_base = %HOST_BASE%
    echo host_bucket = %HOST_BASE%_
    echo access_key = %AWS_ACCESS_KEY_ID%
    echo secret_key = %AWS_SECRET_ACCESS_KEY%
    
    if defined AWS_SESSION_TOKEN (
    echo access_token = %AWS_SESSION_TOKEN%
    )    

    if "!HTTP!"=="0" (
    echo use_https = True
    echo check_ssl_certificate = True
    ) else (
    echo use_https = False
    echo check_ssl_certificate = False
    )
    echo preserve = False
    echo progress_meter = False
    
    if "!CA_REQUIRED!"=="1" (
    echo ca_certs_file = "!SWA_CA!"
    )

)

for %%A in ("%S3CMD_INI%") do if %%~zA lss 1 (
    call :error_58
    exit /b 1
)

echo %MSG_PREFIX% INFO: Successfully updated %YELLOW%%S3CMD_INI%%RESET%
exit /b 2



:: set_s5cmd defines endpoint_url to export S3_ENDPOINT_URL variable of s5cmd.
::
:: Invoked only for non-IAM profile types. For IAM user profiles, 
:: s3 endpoint is either obtained directly from config file or already 
:: resolved earlier in verify_iam_config subroutine.
::
:: Workflow:
::  1. Determine AWS region of selected profile.
::  2. Invoke set_aws_s3_url to construct s3 endpoint_url.
:set_s5cmd
if "%profile_type%"=="sso" (
   call :get_sso_region || exit /b 1
) else (
   call :get_region || exit /b 1
)
call :set_aws_s3_url || exit /b 1
if "%profile_type%"=="sso" set "AWS_REGION="
goto :eof





:: Invoked only when selected profile types is AssumeRole (source_profile), Web Identity or 
:: External Process; and when -i or -3 option is used. 
:: It extracts region value to define s3_endpoint_url.
:get_region
set "line="
for /f "skip=%profile_line_nr% usebackq tokens=* delims=" %%L in ("%CONF_FILE%") do (
    set "line=%%L"
    set "line=!line: =!"

    if "!line:~0,1!"=="[" exit /b 0

    for %%M in (%profile_service_ids%) do if "!line:~0,-1!"=="%%M" exit /b 0

    if "!line:~0,7!"=="region=" set "AWS_REGION=!line:~7!"

)
goto :eof




:: Invoked if region value is required to construct s3 endpoint_url. 
:: SSO profiles may define region either under profile header (Legacy)
:: or under associated sso-session header (New-Format). 
:: Therefore, both sections are scanned.
::
:: Workflow:
::  1. Parse the selected profile section.
::     - Get `sso_region` if defined directly.
::     - Get `sso_session` name if present.
::  2. If `sso_region` was not found, scan sso-session.
:get_sso_region
set "line="
set "SSO_REGION="
set "SSO_SESSION_NAME="
for /f "skip=%profile_line_nr% usebackq tokens=* delims=" %%L in ("%CONF_FILE%") do (
    set "line=%%L"
    set "line=!line: =!"
    if "!line:~0,11!"=="sso_region=" set "SSO_REGION=!line:~11!"
    if "!line:~0,12!"=="sso_session=" set "SSO_SESSION_NAME=!line:~12!"
    if "!line:~0,1!"=="[" goto :check_sso_values
)

    :check_sso_values
    if defined SSO_REGION goto :assign_sso_region
    if not defined SSO_SESSION_NAME ( call :error_35 & exit /b 1 )

    set "in_block=0"
    set "line="
    for /f "usebackq tokens=* delims=" %%L in ("%CONF_FILE%") do (
        set "line=%%L"
        set "line=!line: =!"
        
        if "!in_block!"=="1" (

            if "!line:~0,11!"=="sso_region=" set "SSO_REGION=!line:~11!"
            if "!line:~0,1!"=="[" goto :assign_sso_region

        )

        if "!line!"=="[sso-session!SSO_SESSION_NAME!]" set "in_block=1"
   
    )

    :assign_sso_region
    set "AWS_REGION=!SSO_REGION!"
    if not defined AWS_REGION ( call :error_36 & exit /b 1 )
    
goto :eof





:: select prompt is the main dispatcher for all interactive selection prompts.
:: This subroutine invokes `gum` CLI whenever user is asked to select one or more
:: items from a list.
::
:: Argument-1 → Select mode
:: Argument-2 → Select options
:: 
:: Selection modes:
::  - Mode 1 (single_select): user selects exactly one item. It auto-selects if only one option.
::  - Mode 2 (custom_select): user may select one or more items.
::
:: Selection menu type:
::  - For lists ≤ 15 items, uses `gum choose` for direct navigation.
::  - For lists > 15 items, uses `gum filter` to allow search by typing.
::
:: Notes:
::  - Prompt options are passed indirectly to preserve quotes when used.
::  - Prompt header message (`select_msg`) is defined prior to invoking select prompt.
::    Since this variable name is consistent across the script, it is not passed as argument.
::    In contrast, prompt options (`select_opts`) vary by context and source, so it is passed as argument.
:select_prompt
set "select_mode=%~1"
set "select_opts_tmp=%~2"

:: for error message
set "prompt_src=%~3"

:: using indirect expansion to preserve quotes when used
set "select_opts="
call set "select_opts=%%%select_opts_tmp%%%"
set "select_opts_tmp="

if not defined select_opts ( call :error_66 & exit /b 1 )
if not defined select_mode set "select_mode=1"

set "selected="
set "selected_items="
set "select_command="

if "!select_mode!"=="1" (
   call :single_select || exit /b 1
) else (
   call :custom_select || exit /b 1
)
goto :eof


:single_select
set "select_command=gum.exe choose --select-if-one --header "!select_msg!" !select_opts!"
if !select_item_count! gtr 15 set "select_command=gum.exe filter --header "!select_msg!" !select_opts!"
for /f "usebackq tokens=* delims=" %%a in (`!select_command!`) do set "selected=%%a"
if not defined selected exit /b 1
goto :eof


:custom_select
set "select_command=gum.exe choose --no-limit --header "!select_msg!" !select_opts!"
if !select_item_count! gtr 15 set "select_command=gum.exe filter --no-limit --header "!select_msg!" !select_opts!"
for /f "usebackq tokens=* delims=" %%a in (`!select_command!`) do set "selected_items=!selected_items! %%a"
if not defined selected_items exit /b 1
set "selected=!selected_items:~1!"
goto :eof





:: Below subroutine is used to convert lowercased service_id values to uppercase before appending
:: them to AWS_ENDPOINT_URL_ variable.
::
:: Notes:
::  - Batch provides no native string case-conversion functionality.
::  - Conversion is implemented by iteratively replacing each lowercase letter
::    with its uppercase equivalent using delayed expansion.
::  - The target variable is updated in place with the converted value.
:to_uppercase
set "target_temp=%~1"
set "str="
call set "str=%%%target_temp%%%"

if not defined str ( call :error_65 & exit /b 1 )

set "alphabet_list=a=A b=B c=C d=D e=E f=F g=G h=H i=I j=J k=K l=L m=M n=N o=O p=P q=Q r=R s=S t=T u=U v=V w=W x=X y=Y z=Z"
for %%a in (%alphabet_list%) do set "str=!str:%%a=%%a!"

call set "%target_temp%=%str%"
goto :eof





:: set_unique_list removes duplicate entries from a space-delimited list.
::
:: Workflow:
::  1. Accepts the name of a variable containing a space-delimited list.
::  2. Resolves the variable value via indirect expansion.
::  3. Iterates over each list item.
::  4. Uses dynamically named guard variables (SWA_DUP_<item>) to track previously seen entries.
::  5. Appends unseen items to the result list.
::  6. Writes the unique list back to the original variable.
::
:: Note:
::  - Dynamic variables are prefixed with `SWA_` to allow bulk cleanup at start-up.
:set_unique_list
set "temp_dup_list=%~1"
call set "duped_list=%%%temp_dup_list%%%"

set "unique_list="
for %%A in (%duped_list%) do (
    if not defined SWA_DUP_%%A (
        set "unique_list=!unique_list! %%A"
        set "SWA_DUP_%%A=1"
    )

)
call set "%temp_dup_list%=!unique_list:~1!"
goto :eof



:: list_profiles prints a report of profiles currently defined in config file.
::
:: Workflow:
::  - If swa is invoked with -l or --list option, profiles are read from cache file,
::    report is printed on shell and swa exits immediately.
::
:: Note: 
::    Data is not parsed directly from config file and instead, it is read from cache for 
::    faster output, especially for large config files.
::
:: Report content:
::  - Profile name
::  - Profile type (Human-readable)
::  - Service-Specific (SS) count per profile
::  - Total of profiles and services at the footer
:list_profiles
set "profile_list="
for /f "skip=1 usebackq tokens=1-3*" %%a in ("%PROFILES_CACHE%") do (
    set "profile_list=!profile_list! %%a"
    
    if "%%b"=="iam" (
        set "SWA_PTYPE_%%a=IAM User          "
    ) else if "%%b"=="sso" (
        set "SWA_PTYPE_%%a=SSO               "
    ) else if "%%b"=="ars" (
        set "SWA_PTYPE_%%a=Assume Role       "
    ) else if "%%b"=="arc" (
        set "SWA_PTYPE_%%a=Assume Role       "
    ) else if "%%b"=="web" (
        set "SWA_PTYPE_%%a=Web Identity      "
    ) else if "%%b"=="ext" (
        set "SWA_PTYPE_%%a=External Process  "
    )
    
    set "services_sum=0"
    for %%S in (%%d) do (
        for /f "tokens=1,2 delims=:" %%x in ("%%S") do (
            set "svid=%%x"
            set "svct=%%y"
            set /a services_sum+=svct
            set "SWA_PSRV_%%a=!SWA_PSRV_%%a! !svid!"
            
        )
    )
    set SWA_SVSUM_%%a=!services_sum!

)

set "max_len=0"
for %%M in (!profile_list!) do (
    call :get_length "%%M"
    set SWA_LEN_%%M=!len!
    if !len! gtr !max_len! set max_len=!len!
)

set /a diff=max_len - 11
set "spaces=                "
set "spaces=%spaces%%spaces%%spaces%%spaces%"
set "header_spaces=!spaces:~0,%diff%!"

echo %MSG_PREFIX% Profiles list:
echo.
echo ProfileName%header_spaces%    ProfileType         SS
echo -----------%header_spaces%    -----------         --

set "total_profiles=0"
set "total_services=0"
for %%p in (!profile_list!) do (

    set "diff=0"
    set "prn_len=0"
    set prn_len=!SWA_LEN_%%p!
    set /a diff=max_len - prn_len
    call set "row_spaces=%%spaces:~0,!diff!%%"

    echo %%p!row_spaces!    !SWA_PTYPE_%%p!  !SWA_SVSUM_%%p!

    set /a total_profiles+=1
    set /a total_services+=!SWA_SVSUM_%%p!

)

set "footer_length=0"
set /a footer_length=max_len + 26
set "footer=------------------------------"
set "footer=%footer%%footer%%footer%"
set "footer=!footer:~0,%footer_length%!"

echo %footer%
echo    PROFILE: %total_profiles%
echo SERVICE-ID: %total_services%
echo.
echo %GRAY%*SS = "Service-Specific"%RESET%
goto :eof




:get_length
set "str=%~1"
set "len=0"
for /L %%i in (0,1,64) do (
    if "!str:~%%i,1!"=="" (
        set "len=%%i"
        exit /b 0
    )
)
goto :eof



:: Detects whether the current script was launched from Command-Prompt or PowerShell, 
:: and sets PARENT_SHELL value accordingly.
::
:: Since Windows Batch does not provide a reliable way to identify the calling shell,
:: this implementation uses a pragmatic, non-standard approach by inspecting the contents
:: the CMDCMDLINE dynamic environment variable.
::
:: Workflow:
::  1. Default PARENT_SHELL to `cmd`.
::  2. If ComSpec and CMDCMDLINE are identical, swa was invoked directly from cmd.exe.
::  3. Otherwise, check whether CMDCMDLINE matches known PowerShell launch patterns for cmd.exe:
::       - <ComSpec> /c ""
::       - "<ComSpec>" /c
::     If match is found, parent shell is assumed to be PowerShell.
::
:: Notes:
::  - While it may appear sufficient to assume PowerShell as the caller whenever 
::    ComSpec differs from CMDCMDLINE and we can conclude the whole caller detection
::    in a single if-else clause, this logic is intentionally more explicit because
::    different Windows versions, launch mechanisms etc. can produce varying command-line 
::    patterns and I have not tested all of them.
:get_parent_shell
set "PARENT_SHELL=cmd"
if /i "%ComSpec%"=="%CMDCMDLINE%" exit /b 0
set "PS_LAUNCH_MODE1=%ComSpec% /c \"\""
set "PS_LAUNCH_MODE2=\"%ComSpec%\" /c"
echo %CMDCMDLINE% | "%FINDSTR_EXE%" /I /C:"%PS_LAUNCH_MODE1%" >nul && ( set "PARENT_SHELL=ps" && exit /b 0 )
echo %CMDCMDLINE% | "%FINDSTR_EXE%" /I /C:"%PS_LAUNCH_MODE2%" >nul && set "PARENT_SHELL=ps"
exit /b 0



:: Below subroutine creates the main SWA initialization script which exports
:: AWS-related environment variables in the running shell after the main script 
:: ends the local scope.
::
:: Workflow:
::  1. Detect the parent shell (CMD vs PowerShell)
::  2. Create a common entry-point script (swa-init.cmd) as zero-byte file
::  3. Delegate shell-specific logic:
::      - CMD  : generates cmd-init.cmd and makes swa-init.cmd call it.
::      - PS   : generates ps-init.ps1 and prints instructions to source it.
::
:: Therefore, swa-init.cmd either exports variables (CMD) or instructs user for dot-sourcing (PowerShell).
:export_init
call :get_parent_shell

set "SWA_INIT=%SWA_DIR%\swa-init.cmd"
copy nul "%SWA_INIT%" >nul 2>&1 || (
    call :error_59
    exit /b 1
)

if "%PARENT_SHELL%"=="cmd" (
    call :cmd_init || exit /b 1
) else (
    call :ps_init || exit /b 1
)

for %%A in ("%SWA_INIT%") do if %%~zA lss 1 (
    call :error_60
    exit /b 1
)
goto :eof


:: cmd_init generates a Command-Prompt init script which exports variables to 
:: the current CMD process.
::
:: Workflow:
::  1. Create cmd-init.cmd as zero-byte file
::  2. List all AWS_* variables currently defined in the process and
::     SET commands to persist them in shell
::  3. Optionally export:
::      - AWS_CA_BUNDLE (when custom CA is required)
::      - S3_ENDPOINT_URL (when -5 option is used)
::      - MC_HOST_S3 (when -i option is used and user confirms exporting this variable)
::
:: Note:
::  - swa-init.cmd first clears all AWS_* variables from the running shell to prevent
::    conflict of AWS variables from previous runs except AWS_CONFIG_FILE and AWS_SHARED_CREDENTIALS_FILE.
::    If there are other AWS variables that you want to keep in the running CMD session, adjust the logic in SWA_INIT.
:cmd_init
set "CMD_INIT=%SWA_DIR%\cmd-init.cmd"
copy nul "%CMD_INIT%" >nul 2>&1 || ( call :error_61 & exit /b 1 )

> "%CMD_INIT%" (
   echo @echo off
   echo echo %MSG_PREFIX% INFO: Exported Variables:
) 

for /f "usebackq tokens=1* delims==" %%A in (`set AWS_ 2^>nul`) do (
>> "%CMD_INIT%" echo set "%%A=%%B"
>> "%CMD_INIT%" echo echo  %%A=%GREEN%%%B%RESET%
)

if "!CA_REQUIRED!"=="1" (
>> "%CMD_INIT%" echo set "AWS_CA_BUNDLE=!SWA_CA!"
>> "%CMD_INIT%" echo echo  AWS_CA_BUNDLE=%GREEN%!SWA_CA!%RESET%
)

if "%FLAG_S5CMD%"=="1" (
    if defined AWS_ENDPOINT_URL_S3 (
>> "%CMD_INIT%" echo set "S3_ENDPOINT_URL=!AWS_ENDPOINT_URL_S3!"
>> "%CMD_INIT%" echo echo  S3_ENDPOINT_URL=%GREEN%!AWS_ENDPOINT_URL_S3! %GRAY%[s5cmd]%RESET%
    ) else (
>> "%CMD_INIT%" echo set "S3_ENDPOINT_URL=!AWS_ENDPOINT_URL!"
>> "%CMD_INIT%" echo echo  S3_ENDPOINT_URL=%GREEN%!AWS_ENDPOINT_URL! %GRAY%[s5cmd]%RESET%
    )
)

if defined MC_HOST_S3 (
>> "%CMD_INIT%" echo set "MC_HOST_S3=!MC_HOST_S3!"
>> "%CMD_INIT%" echo echo  MC_HOST_S3=%GREEN%!MASKED_MC_HOST_S3!%RESET%
)

for %%A in ("%CMD_INIT%") do if %%~zA lss 1 (
    call :error_62
    exit /b 1
)

> "%SWA_INIT%" (
        
    echo @echo off
    echo set "SWA_CONF_ENV="
    echo set "SWA_CRED_ENV="
    echo if defined AWS_CONFIG_FILE set "SWA_CONF_ENV=%%AWS_CONFIG_FILE%%"
    echo if defined AWS_SHARED_CREDENTIALS_FILE set "SWA_CRED_ENV=%%AWS_SHARED_CREDENTIALS_FILE%%"
    echo for /f "usebackq tokens=1* delims==" %%%%A in ^(`set AWS_ 2^^^>nul`^) do set "%%%%A="
    echo if defined SWA_CONF_ENV set "AWS_CONFIG_FILE=%%SWA_CONF_ENV%%" ^&^& set "SWA_CONF_ENV="
    echo if defined SWA_CRED_ENV set "AWS_SHARED_CREDENTIALS_FILE=%%SWA_CRED_ENV%%" ^&^& set "SWA_CRED_ENV="
    echo call "%CMD_INIT%"

)
goto :eof


:: ps_init generates the PowerShell init script which exports variables to 
:: the current PowerShell process.
::
:: Workflow:
::  1. Create ps-init.ps1 as zero-byte file
::  2. Temporarily preserve AWS_CONFIG_FILE and AWS_SHARED_CREDENTIALS_FILE
::  3. Remove all existing AWS_* variables from the PowerShell environment
::  4. Restore preserved AWS_CONFIG_FILE and AWS_SHARED_CREDENTIALS_FILE
::       - Note: if there are other AWS variables that you want to keep in the running 
::         PowerShell session, adjust the logic in PS_INIT.
::  5. Export current AWS_* variables.
::  6. Optionally export:
::      - AWS_CA_BUNDLE (when a custom CA is required)
::      - S3_ENDPOINT_URL (when -5 option is used)
::      - MC_HOST_S3 (when -i option is used and user confirms exporting this variable)
::  7. Display exported variables on shell
::
:: Note:
::   Since exporting variables in PowerShell requires dot-sourcing, swa-init.cmd prints 
::   dot-sourcing command and additionally, copies it to clipboard for quick paste-and-run.
:ps_init
set "PS_INIT=%SWA_DIR%\ps-init.ps1"
copy nul "%PS_INIT%" >nul  2>&1 || ( call :error_63 & exit /b 1 )

>> "%PS_INIT%" echo if (Test-Path Env:SWA_CONF_ENV) { Remove-Item Env:SWA_CONF_ENV }
>> "%PS_INIT%" echo if (Test-Path Env:SWA_CRED_ENV) { Remove-Item Env:SWA_CRED_ENV }
>> "%PS_INIT%" echo if (Test-Path Env:AWS_CONFIG_FILE) { $Env:SWA_CONF_ENV = $Env:AWS_CONFIG_FILE }
>> "%PS_INIT%" echo if (Test-Path Env:AWS_SHARED_CREDENTIALS_FILE) { $Env:SWA_CRED_ENV = $Env:AWS_SHARED_CREDENTIALS_FILE }
>> "%PS_INIT%" echo Get-ChildItem Env: ^| Where-Object { $_.Name -like 'AWS_*' } ^| ForEach-Object { Remove-Item "Env:$($_.Name)" }
>> "%PS_INIT%" echo if ($Env:SWA_CONF_ENV) { $Env:AWS_CONFIG_FILE = $Env:SWA_CONF_ENV; Remove-Item Env:SWA_CONF_ENV }
>> "%PS_INIT%" echo if ($Env:SWA_CRED_ENV) { $Env:AWS_SHARED_CREDENTIALS_FILE = $Env:SWA_CRED_ENV; Remove-Item Env:SWA_CRED_ENV }
>> "%PS_INIT%" echo Write-Host ([char]27 + "[38;2;255;165;0m[swa]" + [char]27 + "[0m") "Exported variables:"

for /f "usebackq tokens=1* delims==" %%A in (`set AWS_ 2^>nul`) do (
>> "%PS_INIT%" echo [System.Environment]::SetEnvironmentVariable('%%A', '%%B', [System.EnvironmentVariableTarget]::Process^)
>> "%PS_INIT%" echo Write-Host " %%A=" -NoNewline; Write-Host -ForegroundColor Green "$env:%%A"
)

if "!CA_REQUIRED!"=="1" (
>> "%PS_INIT%" echo [System.Environment]::SetEnvironmentVariable('AWS_CA_BUNDLE', '!SWA_CA!', [System.EnvironmentVariableTarget]::Process^)
>> "%PS_INIT%" echo  Write-Host " AWS_CA_BUNDLE=" -NoNewline; Write-Host -ForegroundColor Green "$env:AWS_CA_BUNDLE"
)

if "%FLAG_S5CMD%"=="1" (
    if defined AWS_ENDPOINT_URL_S3 (
>> "%PS_INIT%" echo [System.Environment]::SetEnvironmentVariable('S3_ENDPOINT_URL', '!AWS_ENDPOINT_URL_S3!', [System.EnvironmentVariableTarget]::Process^)
>> "%PS_INIT%" echo Write-Host " S3_ENDPOINT_URL=" -NoNewline; Write-Host -ForegroundColor Green "$env:S3_ENDPOINT_URL" -NoNewline; Write-Host -ForegroundColor DarkGray ' [s5cmd]';
    ) else (
>> "%PS_INIT%" echo [System.Environment]::SetEnvironmentVariable('S3_ENDPOINT_URL', '!AWS_ENDPOINT_URL!', [System.EnvironmentVariableTarget]::Process^)
>> "%PS_INIT%" echo Write-Host " S3_ENDPOINT_URL=" -NoNewline; Write-Host -ForegroundColor Green "$env:S3_ENDPOINT_URL" -NoNewline; Write-Host -ForegroundColor DarkGray ' [s5cmd]';
    )
)

if defined MC_HOST_S3 (
>> "%PS_INIT%" echo [System.Environment]::SetEnvironmentVariable('MC_HOST_S3', '!MC_HOST_S3!', [System.EnvironmentVariableTarget]::Process^)
>> "%PS_INIT%" echo [System.Environment]::SetEnvironmentVariable('MASKED_MC_HOST_S3', '!MASKED_MC_HOST_S3!', [System.EnvironmentVariableTarget]::Process^)
>> "%PS_INIT%" echo Write-Host " MC_HOST_S3=" -NoNewline; Write-Host -ForegroundColor Green "$env:MASKED_MC_HOST_S3"
>> "%PS_INIT%" echo Remove-Item Env:MASKED_MC_HOST_S3
)

for %%A in ("%PS_INIT%") do if %%~zA lss 1 (
    call :error_64
    exit /b 1
)

> "%SWA_INIT%" (

    echo @echo off
    echo echo %MSG_PREFIX% INFO: Export variables by running:
    echo echo . "%PS_INIT%" ^| clip
    echo echo.
    echo echo    %BLUE%~%RESET%$ .%YELLOW% "%PS_INIT%" %RESET%     %GRAY%[Copied to Clipboard]%RESET%
    echo echo.

)
goto :eof





:: Following lines to the end of the script all are informational and error messages used
:: throughout this script, implemented as callable labels (:info_N, :error_N).
::
:: Workflow:
::  - Most of the labels prints a message and immediately returns to the caller except for
::    some error messages that additionally call to print a related info message as well.
::
:: Design decision to use centralized messages in the Batch version of the script was made to avoid 
:: repetitive ECHO statements and duplication. It helps keep the operational logic clear and concise.
::
:: However, in Bash implementation of swa, info and error messages are emitted inline at the point
:: of execution mainly because of how Bash version of swa has to be implemented and also, Bash’s function 
:: model, variable scoping, and expressive syntax make this approach concise and readable.
:info_1
echo %MSG_PREFIX% INFO: Updating cache...
goto :eof

:info_2
echo %MSG_PREFIX% INFO: service cache seems to be corrupted. invoke 'swa -f' to force cache rebuild.
goto :eof

:info_3
echo %MSG_PREFIX% INFO: allowed characters are A-Za-z0-9._-[] and one space ^(only one in middle^)
goto :eof

:info_4
echo %MSG_PREFIX% INFO: If config file contains valid data, invoke 'swa -f' to force cache rebuild.
goto :eof

:info_5
echo %MSG_PREFIX% INFO: Successfully downloaded and cached AWS services list.
goto :eof

:info_6
echo %MSG_PREFIX% INFO: Successfully cached profiles data as of %current_timestamp% ^(config timestamp^).
goto :eof

:info_7
echo %MSG_PREFIX% INFO: No Profile Selected.
goto :eof

:info_8
echo %MSG_PREFIX% INFO: %GREEN%%AWS_PROFILE%%RESET% profile is already logged-on.
goto :eof

:info_9
echo %MSG_PREFIX% INFO: Token is expired for SSO Profile %GREEN%%AWS_PROFILE%%RESET%.
goto :eof

:info_10
echo %MSG_PREFIX% INFO: Successful SSO login.
goto :eof

:info_11
echo %MSG_PREFIX% INFO: -u flag ignored. %GREEN%%AWS_PROFILE%%RESET% profile is using official AWS endpoint.
goto :eof

:info_12
echo %MSG_PREFIX% INFO: -u flag ignored. endpoint_url is not defined for %GREEN%%AWS_PROFILE%%RESET% profile.
goto :eof

:info_13
echo %MSG_PREFIX% INFO: Endpoint is using Valid Public Certificate.
goto :eof

:info_14
echo %MSG_PREFIX% INFO: HTTPS verification failed. Fallback HTTP...
goto :eof

:info_15
echo %MSG_PREFIX% INFO: ca_bundle is required. Downloading...
goto :eof

:info_16
echo %MSG_PREFIX% INFO: Successfully verified ca_bundle in config file.
goto :eof

:info_17
echo %MSG_PREFIX% INFO: ca_bundle specified in config file is invalid. Downloading...
goto :eof

:info_18
echo %MSG_PREFIX% INFO: Endpoint only supports HTTP.
goto :eof

:info_19
echo %MSG_PREFIX% INFO: Successfully downloaded raw certificate chain.
goto :eof

:info_20
echo %MSG_PREFIX% INFO: Successfully extracted certificates.
goto :eof

:info_21
echo %MSG_PREFIX% INFO: Successfully verified new ca_bundle.
goto :eof

:info_22
echo %MSG_PREFIX% INFO: Successfully added new ca_bundle path to config file.
goto :eof

:info_23
echo %MSG_PREFIX% INFO: %BRIGHT_WHITE%!service_id!%RESET% service endpoint_url is not defined in config.
goto :eof

:info_24
echo %MSG_PREFIX% INFO: endpoint_url is not defined. it is required for s3 client tool config file.
echo %MSG_PREFIX% INFO: Attempting to define endpoint_url...
goto :eof

:info_25
echo %MSG_PREFIX% INFO: Credentials source_profile %BRIGHT_WHITE%!assumerole_crd_pn!%RESET% is of ^t^ype SSO.
echo %MSG_PREFIX% INFO: Verifying login status...
goto :eof

:info_26
echo %MSG_PREFIX% INFO: %GREEN%%AWS_PROFILE%%RESET% profile uses %BRIGHT_WHITE%Environment%RESET% option for credential_source.
goto :eof

:info_27
echo %MSG_PREFIX% INFO: credentials are not official AWS or incorrect parameter in config.
goto :eof

:info_28
if !FLAG_CREDENTIALS! == 1 ( echo %MSG_PREFIX% INFO: credentials of another profile is required to export. & exit /b 0 )
if !FLAG_S3CMD! == 1 ( echo %MSG_PREFIX% INFO: credentials of another profile is required for s3cmd config file. & exit /b 0 )
if !FLAG_MINIO! == 1 ( echo %MSG_PREFIX% INFO: credentials of another profile is required for mc ^(MinIO^) config file. & exit /b 0 )
goto :eof

:info_29
echo %MSG_PREFIX% INFO: ca_bundle defined in config file does not exist.
echo %MSG_PREFIX% INFO: Verifying ca_bundle requirement...
goto :eof

:info_30
echo %MSG_PREFIX% INFO: Successful MFA Login for %GREEN%%AWS_PROFILE%%RESET% profile.
goto :eof

:info_31
echo %MSG_PREFIX% INFO: -m flag ignored. mfa_serial is not defined for %GREEN%%AWS_PROFILE%%RESET% profile.
goto :eof

:info_32
echo %MSG_PREFIX% INFO: Successfully copied certificate to %YELLOW%!MC_CA_BUNDLE!%RESET% profile.
goto :eof

:info_33
echo %MSG_PREFIX% INFO: Certificate exists %YELLOW%!MC_CA_BUNDLE!%RESET%. Ignored copying to ~\mc\certs\CAs.
goto :eof







:error_1
echo %MSG_PREFIX% ERROR ^(1^): Unknown flag. Use -h ^f^o^r help.%RESET%
goto :eof

:error_2
echo %MSG_PREFIX% ERROR ^(2^): AWS config file was not found on %YELLOW%%CONF_FILE%%RESEST%
goto :eof

:error_3
echo %MSG_PREFIX% ERROR ^(3^): unable to read AWS config file %YELLOW%%CONF_FILE%%RESEST%
goto :eof

:error_4
echo %MSG_PREFIX% ERROR ^(4^): unable to read AWS credentials file %YELLOW%%CRED_FILE%%RESEST%
goto :eof

:error_5
echo %MSG_PREFIX% ERROR ^(5^): ^where cli was not found on %YELLOW%%WHERE_EXE%%RESET% 
goto :eof

:error_6
echo %MSG_PREFIX% ERROR ^(6^): ^findstr cli was not found on %YELLOW%%FINDSTR_EXE%%RESET% 
goto :eof

:error_7
echo %MSG_PREFIX% ERROR ^(7^): ^curl cli was not found on %YELLOW%%CURL_EXE%%RESET%
goto :eof

:error_8
echo %MSG_PREFIX% ERROR ^(8^): ^aws cli was not found.
goto :eof

:error_9
echo %MSG_PREFIX% ERROR ^(9^): ^gum cli was not found.
goto :eof

:error_10
echo %MSG_PREFIX% ERROR ^(10^): failed to create swa directory ^at %YELLOW%%SWA_DIR%%RESET%
goto :eof

:error_11
echo %MSG_PREFIX% ERROR ^(11^): failed to update cache.
goto :eof

:error_12
echo %MSG_PREFIX% ERROR ^(12^): failed to access %YELLOW%%CONF_DIR%%RESET% directory to get %YELLOW%%CONF_FILENAME%%RESET% file timestamp.
goto :eof

:error_13
echo %MSG_PREFIX% ERROR ^(13^): failed to get timestamp of %YELLOW%%CONF_FILE%%RESET%
goto :eof

:error_14
echo %MSG_PREFIX% ERROR ^(14^): failed to connect to %YELLOW%%AWS_SS_TABLE%%RESET% to download service list.
goto :eof

:error_15
echo %MSG_PREFIX% ERROR ^(15^): failed to download and build aws services list from %YELLOW%%AWS_SS_TABLE%%RESET%
goto :eof

:error_16
echo %MSG_PREFIX% ERROR ^(16^): unknown error while building aws services list.
goto :eof

:error_17
echo %MSG_PREFIX% ERROR ^(17^): failed to create service cache file ^at %YELLOW%%SERVICES_CACHE%%RESET%
goto :eof

:error_18
echo %MSG_PREFIX% ERROR ^(18^): failed writing to service cache file ^at %YELLOW%%PROFILES_CACHE%%RESET%
goto :eof

:error_19
echo %MSG_PREFIX% ERROR ^(19^): failed to create profiles cache file ^at %YELLOW%%PROFILES_CACHE%%RESET%
goto :eof

:error_20
echo %MSG_PREFIX% ERROR ^(20^): failed writing to profiles cache file ^at %YELLOW%%PROFILES_CACHE%%RESET%
goto :eof

:error_21
echo %MSG_PREFIX% ERROR ^(21^): profile name ^at line !line_nr! of %header_source% is duplicate.
goto :eof

:error_22
echo %MSG_PREFIX% ERROR ^(22^): invalid character found in %header_source% header -^> "line %header_chars%"
goto :eof

:error_23
echo %MSG_PREFIX% ERROR ^(23^): space detected before header, ^at ^start of the line !line_nr! of %header_source%
goto :eof

:error_24
echo %MSG_PREFIX% ERROR ^(24^): one space required between header prefix and its name ^at line !line_nr! of config file. e.g. ^[profile devops^]
goto :eof

:error_25
echo %MSG_PREFIX% ERROR ^(25^): header's name length has exceeded 64 characters limit ^at line !line_nr! of %header_source%
goto :eof

:error_26
echo %MSG_PREFIX% ERROR ^(26^): extra character detected after closing bracket ^at line !line_nr! of %header_source%
goto :eof

:error_27
echo %MSG_PREFIX% ERROR ^(27^): space detected in header's name position ^at line !line_nr! of %header_source% -^> ^{%header_chars%^}
goto :eof

:error_28
echo %MSG_PREFIX% ERROR ^(28^): invalid header ^at line !line_nr! of %header_source% -^> !header_line!
goto :eof

:error_29
echo %MSG_PREFIX% ERROR ^(29^): failed to ^set profile ^type of !profile_name! profile.
goto :eof

:error_30
echo %MSG_PREFIX% ERROR ^(30^): unknown error occured while counting services of !profile_name! profile.
goto :eof

:error_31
echo %MSG_PREFIX% ERROR ^(31^): failed to define profile list ^f^or selection. & call :info_4
goto :eof

:error_32
echo %MSG_PREFIX% ERROR ^(32^): unknown error occured while reading data from cache. & call :info_4
goto :eof

:error_33
echo %MSG_PREFIX% ERROR ^(33^): failed to get user's ARN.
echo %MSG_PREFIX% "%SWA_ARN%"
goto :eof

:error_34
echo %MSG_PREFIX% ERROR ^(34^): SSO Login failed.
goto :eof

:error_35
echo %MSG_PREFIX% ERROR ^(35^): sso_session name and sso_region not found.
goto :eof

:error_36
echo %MSG_PREFIX% ERROR ^(36^): sso_region not found.
goto :eof

:error_37
echo %MSG_PREFIX% ERROR ^(37^): unknown error occured while reading %GREEN%%AWS_PROFILE%%RESET% profile data from config file.
goto :eof

:error_38
echo %MSG_PREFIX% ERROR ^(38^): duplicate !service_id! service identifier found in section !section_name!
goto :eof

:error_39
echo %MSG_PREFIX% ERROR ^(39^): unable to list !service_id! services of %GREEN%%AWS_PROFILE%%RESET% profile.
goto :eof

:error_40
echo %MSG_PREFIX% ERROR ^(40^): failed to define s3 endpoint_url.
goto :eof

:error_41
echo %MSG_PREFIX% ERROR ^(41^): 500 Internal Error.
goto :eof

:error_42
echo %MSG_PREFIX% ERROR ^(42^): 502 Bad Gateway ^(backend refused connection^).
goto :eof

:error_43
echo %MSG_PREFIX% ERROR ^(43^): 503 Service Unavailable ^(backend unavailable^).
goto :eof

:error_44
echo %MSG_PREFIX% ERROR ^(44^): 504 Gateway Timeout.
goto :eof

:error_45
echo %MSG_PREFIX% ERROR ^(45^): could not resolve host: %HOST_BASE%
goto :eof

:error_46
echo %MSG_PREFIX% ERROR ^(46^): could not connect to %HOST_BASE% on port ^443 and 80.
goto :eof

:error_47
echo %MSG_PREFIX% ERROR ^(47^): curl error %rc% while verifying existing ca_bundle.
goto :eof

:error_48
echo %MSG_PREFIX% ERROR ^(48^): curl error %rc% as endpoint is unreachable via both HTTP and HTTPS.
goto :eof

:error_49
echo %MSG_PREFIX% ERROR ^(49^): failed to create certificates directory ^at %YELLOW%%CERT_DIR%%RESET%
goto :eof

:error_50
echo %MSG_PREFIX% ERROR ^(50^): failed to create raw_cert file ^at %YELLOW%%RAW_CERT%%RESET%
goto :eof

:error_51
echo %MSG_PREFIX% ERROR ^(51^): failed to download raw certificate chain from %SWA_TARGET_S3URL%
goto :eof

:error_52
echo %MSG_PREFIX% ERROR ^(52^): failed to ^extract ca_bundle from raw certificate chain.
goto :eof

:error_53
echo %MSG_PREFIX% ERROR ^(53^): new ca_bundle is invalid.
goto :eof

:error_54
echo %MSG_PREFIX% ERROR ^(54^): failed to update AWS config with new ca_bundle path.
goto :eof

:error_55
echo %MSG_PREFIX% ERROR ^(55^): mc ^(MinIO^) cli was not found.
goto :eof

:error_56
echo %MSG_PREFIX% ERROR ^(56^): failed to update config.json of mc ^(MinIO^).
goto :eof

:error_57
echo %MSG_PREFIX% ERROR ^(57^): failed to create s3cmd config file ^at %YELLOW%%S3CMD_INI%%RESET%
goto :eof

:error_58
echo %MSG_PREFIX% ERROR ^(58^): failed writing to s3cmd config file ^at %YELLOW%%S3CMD_INI%%RESET%
goto :eof

:error_59
echo %MSG_PREFIX% ERROR ^(59^): failed to create swa-init wrapper file ^at %YELLOW%%SWA_INIT%%RESET%
goto :eof

:error_60
echo %MSG_PREFIX% ERROR ^(60^): failed writing to swa-init wrapper.
goto :eof

:error_61
echo %MSG_PREFIX% ERROR ^(61^): failed to create init-script ^f^or Command-Prompt.
goto :eof

:error_62
echo %MSG_PREFIX% ERROR ^(62^): failed writing to init-script of Command-Prompt.
goto :eof

:error_63
echo %MSG_PREFIX% ERROR ^(63^): failed to create init-script ^f^or PowerShell.
goto :eof

:error_64
echo %MSG_PREFIX% ERROR ^(64^): failed writing to init-script of PowerShell.
goto :eof

:error_65
echo %MSG_PREFIX% ERROR ^(65^): string is not defined to ^convert to uppercase.
goto :eof

:error_66
echo %MSG_PREFIX% ERROR ^(66^): !prompt_src! list is not defined ^f^or selection.
goto :eof

:error_67
echo %MSG_PREFIX% ERROR ^(67^): failed to create %GREEN%"%AWS_SS_TABLE%"%RESET% ^f^or writing AWS documentation page.
goto :eof

:error_68
echo %MSG_PREFIX% ERROR ^(68^): failed to create mc ^(MinIO^) certificate directory ^at %YELLOW%!MC_CA_DIR!%RESET%
goto :eof

:error_69
echo %MSG_PREFIX% ERROR ^(69^): failed copying ca_bundle to %YELLOW%!MC_CA_DIR!%RESET%
goto :eof

:error_70
echo %MSG_PREFIX% ERROR ^(70^): failed to define credentials required ^f^or mc ^(MinIO^) config file.
goto :eof

:error_71
echo %MSG_PREFIX% ERROR ^(71^): credential_source option is unknown or not suppored.
goto :eof

:error_72
echo %MSG_PREFIX% ERROR ^(72^): failed to get credentials option ^f^or %GREEN%%AWS_PROFILE%%RESET% profile.
goto :eof

:error_73
echo %MSG_PREFIX% ERROR ^(73^): unknown error occured while defining list of profiles ^f^or credentials source.
goto :eof

:error_74
echo %MSG_PREFIX% ERROR ^(74^): failed to define credentials required ^f^or s3cmd config file.
goto :eof

:error_75
if "!profile_type!"=="ars" (
    echo %MSG_PREFIX% ERROR ^(75^): failed to export credentials from source_profile of %GREEN%%AWS_PROFILE%%RESET%.
) else if "!profile_type!"=="arc" (
    echo %MSG_PREFIX% ERROR ^(75^): failed to export credentials from %BRIGHT_WHITE%!assumerole_crd_pn!%RESET% source_profile of %GREEN%%AWS_PROFILE%%RESET%. 
) else if "!profile_type!"=="ext" (
    echo %MSG_PREFIX% ERROR ^(75^): failed to export credentials using %BRIGHT_WHITE%credential_process%RESET% option used by %GREEN%%AWS_PROFILE%%RESET% profile. 
) else if "!profile_type!"=="web" (
    echo %MSG_PREFIX% ERROR ^(75^): failed to export credentials using %BRIGHT_WHITE%web_identity_token_file%RESET% option of %GREEN%%AWS_PROFILE%%RESET% profile.
) else (
    echo %MSG_PREFIX% ERROR ^(75^): failed to export credentials ^f^or %GREEN%%AWS_PROFILE%%RESET% profile.
)
echo %MSG_PREFIX% ERROR ^(75^): "!line!"
goto :eof


exit /b 0       :: success
exit /b 1       :: failed and exit
exit /b 2       :: exit script