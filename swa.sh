#!/usr/bin/env bash
#
#      script: swa.sh
#     purpose: AWS context switcher for Linux Bash
#     version: 1.0.0
#     license: MIT
#      author: Hamed Davodi <retrogaming457 [at] gmail [dot] com>
#  repository: https://github.com/bruckware/swa
#


show_help() {

  print_msg "
  swa - an interactive AWS context switcher for Linux Bash shell.

  This tool uses environment variables to switch profile and avoids editing of config
  file for this purpose.

  swa exports variables of the global settings & service-specific settings, including
  all 380 AWS services. Note environment variables are only exported in current shell
  session and, this tool does not modify system-wide or user-wide variables table.

  swa is optimized to work with large config files, containing numerous profiles from 
  all AWS profile types (IAM User, SSO, Assume Role, Web Identity, External Process).
  it can parse values of profiles with services header as those values cannot be read
  by aws cli itself and,supports Amazon s3 and any s3-compatible implementation which
  is using AWS s3 API.

  In addition, it faciliates working with self-hosted s3 services in case s3 endpoint
  is using self-signed certificate and, it exports the config file of other s3 client
  tools on their default paths.
  
  Usage: swa [option]                                                          

       -h, --help      Show help
       -v, --version   Show version
       -l, --list      List all profiles
       -m, --mfa       Prompt for MFA-Login if profile has mfa_serial option
       -f              Force cache update for both profiles and services list
       -c              Export AWS credentials as environment variables
       -u              Verify endpoint_url access and download CA bundle if required
       -i              Update MinIO client (mc) config file for s3 alias
       -3              Update config file of s3cmd
       -5              Export S3 endpoint_url environment variable for s5cmd
"

}



# ---------------------------------------------------------------------------
# This script is intentionally heavily commented.
# While this may differ from the 'minimal comments' guideline as mentioned in
# Clean Code, this approach is deliberate in order to:
#
# - Serve as both source code and documentation
# - Avoid relying on a separate file for documentation
# - Capture workflow, intent, and decision rationale
# ---------------------------------------------------------------------------

# set default options and updates one if an argument is passed.
# at most one command-line argument is allowed per invocation.
set_options() {

    FLAG_CREDENTIALS=0
    FLAG_VERIFY_URL=0
    FLAG_LISTING=0
    FLAG_MFA=0
    FLAG_CACHE=0
    FLAG_MINIO=0
    FLAG_S3CMD=0
    FLAG_S5CMD=0

    [[ -n "${_ARG:-}" ]] || return 0

    case "$_ARG" in
        -h|--help)
            show_help
            return 1
            ;;

        -v|--version)
            print_msg "v${_VERSION}\n${_REPO}"
            return 1
            ;;

        -l|--list)
            FLAG_LISTING=1
            return 0
            ;;
        
        -m|--mfa)
            FLAG_MFA=1
            return 0
            ;;
        
        -f)
            FLAG_CACHE=1
            return 0
            ;;

        -c)
            FLAG_CREDENTIALS=1
            return 0
            ;;
        
        -u)
            FLAG_VERIFY_URL=1
            return 0
            ;;

        -i)
            FLAG_MINIO=1
            return 0
            ;;

        -3)
            FLAG_S3CMD=1
            return 0
            ;;

        -5)
            FLAG_S5CMD=1
            return 0
            ;;

        *)
            print_msg "${MSG_PREFIX} ERROR (2): Unknown flag '$_ARG'. Use -h for help."
            return 1
            ;;
    esac

}


requirement() {
    
    # Define default locations for AWS config and credentials files.
    # These defaults are overridden if user-defined paths are provided via environment variables. 
    # CONF_FILE and CRED_FILE variables are used when parsing files.
    #
    # credentials file is treated as optional throughout the script, as some
    # users may not use it or may combine credentials into config file.
    HOME=${HOME%/}    
    CRED_FILE="$HOME/.aws/credentials"
    CONF_FILE="$HOME/.aws/config"

    # Preserve existing AWS_CONFIG_FILE and AWS_SHARED_CREDENTIALS_FILE values (if any)
    # so they can be restored after clearing AWS-related environment variables.
    # This is necessary to avoid conflicts or incorrect behavior when AWS CLI
    # commands are executed later, particularly when user relies
    # on non-default file locations outside ~/.aws
    if [[ -n "${AWS_CONFIG_FILE:-}" && -f "${AWS_CONFIG_FILE:-}" ]]; then
        CONF_FILE="${AWS_CONFIG_FILE}" 
        SWA_CONF_ENV="${AWS_CONFIG_FILE}"
    fi
        
    if [[ -n "${AWS_SHARED_CREDENTIALS_FILE:-}" && -f "${AWS_SHARED_CREDENTIALS_FILE:-}" ]]; then
        CRED_FILE="${AWS_SHARED_CREDENTIALS_FILE}" 
        SWA_CRED_ENV="${AWS_SHARED_CREDENTIALS_FILE}"
    fi

    # After resolving CONF_FILE and CRED_FILE paths, verify if config file exist and is readable.
    # credentials file is optional; however, if it exists, read permission is verified.
    if [[ ! -r "${CONF_FILE}" ]]; then
      print_msg "${MSG_PREFIX} ERROR (3): AWS config file ${YELLOW}${CONF_FILE}${RESET} is missing or not readable."
      return 1
    fi

    if [[ -f ${CRED_FILE} ]]; then
      if [[ ! -r ${CRED_FILE} ]]; then
        print_msg "${MSG_PREFIX} ERROR (4): AWS credentials file ${YELLOW}${CONF_FILE}${RESET} is not readable."
        return 1
      fi
    fi

    # Clear all AWS-related environment variables to ensure a clean execution context.
    # This prevents stale or conflicting values from influencing aws cli queries.
    # Credential-related variables are preserved to support workflows
    # of AssumeRole profile with Environment option.
    declare -ga _ENV_SNAPSHOT=()
    local ev
    for ev in ${!AWS_@}; do
        value=${!ev}

        # Snapshot variable name to use at export_envs function
        _ENV_SNAPSHOT+=("$ev")

        case "$ev" in
            AWS_ACCESS_KEY_ID) SWA_ACCESS_KEY=$value ;;
            AWS_SECRET_ACCESS_KEY) SWA_SECRET_KEY=$value ;;
            AWS_SESSION_TOKEN) SWA_SESSION_TOKEN=$value ;;
        esac

    unset "$ev"
    done

    # Restore AWS_CONFIG_FILE and AWS_SHARED_CREDENTIALS_FILE if they were previously set
    [[ -n "${SWA_CONF_ENV:-}" ]] && export AWS_CONFIG_FILE="${SWA_CONF_ENV}"
    [[ -n "${SWA_CRED_ENV:-}" ]] && export AWS_SHARED_CREDENTIALS_FILE="${SWA_CRED_ENV}"

    # Verify if required tools exist in path
    local tool
    for tool in aws gum curl; do
       command -v "$tool" >/dev/null 2>&1 || {
          print_msg "${MSG_PREFIX} ERROR (5): $tool cli not found in PATH."
          return 1
       }
    done

    # Initialize default values for internal control flags.
    CA_REQUIRED=0
    HTTP=0

    # Ensure the following variables are unset by default.
    # They may be evaluted later when -i (minio) or -5 (s5cmd) options are used.
    unset MC_HOST_S3
    unset S3_ENDPOINT_URL

    # Define path to swa working directory under config file directory
    # and create it if not exist.
    #
    # swa directory in Linux is used to store:
    #  - Cache files (profiles data and aws services list)
    #  - AWS services-list HTML page
    #
    # Also define the paths for the main cache files. 
    # Both are required here at verify_cache step and later in workflow.
    SWA_DIR="$(dirname "${CONF_FILE}")/swa"
    PROFILES_CACHE="${SWA_DIR}/aws_profiles_data"
    SERVICES_CACHE="${SWA_DIR}/aws_services_list"

    if [[ ! -d "${SWA_DIR}" ]]; then
      mkdir "${SWA_DIR}" 2>&1 || {
        print_msg "${MSG_PREFIX} ERROR (6): failed to create swa cache directory ${YELLOW}${SWA_DIR}${RESET}"
        return 1
      }
    fi

    # Retrieve config file timestamp and validate cache.
    #
    # Workflow:
    #  - Extract last-modified timestamp of config file.
    #  - Verify the existing cache against this timestamp.
    #  - If cache is missing or outdated or -f option is used, rebuild it.
    local current_timestamp
    get_config_ts || return 1

    verify_cache || build_cache || { 
        print_msg "${MSG_PREFIX} ERROR (7): failed to update cache."
        return 1
    }

    return 0

}



# Retrieves the last-modified timestamp of the AWS config file.
#
# Timestamp is required everytime when swa is executed as part of pre-check phase,
# and during cache buidling process.
get_config_ts() {

  if stat --version >/dev/null 2>&1; then
    current_timestamp=$(stat -c %Y "${CONF_FILE}")
  else
    current_timestamp=$(stat -f %m "${CONF_FILE}")
  fi

  [[ -n "${current_timestamp}" ]] || {
    print_msg "${MSG_PREFIX} ERROR (8): failed to get timestamp of ${YELLOW}${CONF_FILE}${RESET}"
    return 1
  }

  return 0

}


# verify_cache function is called at the start to ensure cache integrity.
# cache is considered valid only if:
#   - Both profiles and services cache files exist
#   - Timestamp stored in profiles cache matches current timestamp of config file
# otherwise or if -f option is used, exits with code 1 to build the cache
#
# Note that if swa is invoked with -f option, if profile cache and services list exist,
# they are overwritten and a new cache is built.
verify_cache() {

  [[ "${FLAG_CACHE}" -eq 1 ]] && return 1

  [[ -f "${SERVICES_CACHE}" ]] || return 1
  [[ -f "${PROFILES_CACHE}" ]] || return 1

  local cached_timestamp
  read -r cached_timestamp < "${PROFILES_CACHE}"
  [[ -n "${cached_timestamp}" ]] || return 1

  [[ "$cached_timestamp" == "[$current_timestamp]" ]] || return 1

  return 0

}



# Main dispatcher to build cache for faster and simpler access to config data.
# Workflow:
#  - Read AWS service list from cache. if not available, download, validate and finally write to the 'services cache'.
#  - List profile headers, validate character sets, determine profile types and corresponding line numbers in config file.
#  - Count service id per profile (if any).
#  - Index all collected data.
#  - Write indexed data to the 'profile cache'.
build_cache() {
  
  print_msg "${MSG_PREFIX} INFO: Updating cache..."
  get_services_list || return 1
  get_config_profiles || return 1
  cache_profiles_data || return 1

  return 0

}



# Build a list of all AWS service IDs for validating and counting services per profile, then cache the result for reuse.
# The service list is downloaded if no local cache exists and, if the existing cache fails validation, 
# user is instructed to use -f option to trigger a new download of services list.
get_services_list() {
    
    declare -ga aws_services_list=()

    if [[ ! -f "${SERVICES_CACHE}" || "${FLAG_CACHE}" -eq 1 ]]; then
        download_services_list || {
            print_msg "${MSG_PREFIX} ERROR (9): failed to download AWS services list."
            return 1
        }
        return 0
    fi

    mapfile -t aws_services_list < "${SERVICES_CACHE}" || {
        print_msg "${MSG_PREFIX} ERROR (10): failed reading from service cache file ${YELLOW}${SERVICES_CACHE}${RESET}"
        return 1
    }
    
    local used_service_cache=1
    verify_services_list || return 1

    return 0

}

# Retrieve the complete list of AWS service identifiers required to build
# the profiles cache. This list is downloaded once and cached locally.
# A new download is triggered only if -f option is used or cache is missing.
#
# Workflow:
#  - AWS documentation page contains a table with three columns (rows in raw html):
#      1. Service name
#      2. Service identifier key
#      3. AWS_ENDPOINT_URL_<SERVICE> environment variable
#
#  - Filtering HTML page for values with this tag → " <code class="code">accessanalyzer</code>"
#  - Only 'Service identifier key' in the 2nd row is extracted → accessanalyzer
#
# Note:
#   Not all three values from the AWS services table are required.
#   Service identifier key alone is sufficient for all current use cases:
#     - Validating service identifiers in config file
#     - Displaying options in the user selection menu
#     - Defining service-specific endpoint URLs
#       (service identifier is converted to uppercase and appended to
#        AWS_ENDPOINT_URL_<UPPERCASE_SERVICE_ID>)
download_services_list() {

    local AWS_SS_URL="https://docs.aws.amazon.com/sdkref/latest/guide/ss-endpoints-table.html"
    local html

    html=$(curl -q -s "$AWS_SS_URL") || {
        print_msg "${MSG_PREFIX} ERROR (11): failed to connect to ${YELLOW}${AWS_SS_URL}${RESET} to download service list."
        return 1
    }

    local line
    local count=0
    while IFS= read -r line; do
        
        [[ $line =~ ^[[:space:]]+\<code\ class=\"code\"\>([^<]+)\<\/code\> ]] || continue
        (( ++count ))
        (( count == 2 )) && aws_services_list+=( "${BASH_REMATCH[1]}" )
        (( count == 3 )) && count=0

    done <<< "$html"

    verify_services_list || return 1
    cache_services_list || return 1

    return 0

}





# Verify the integrity of the AWS services list, whether it was downloaded
# or loaded from the cached file.
#
# Workflow:
#  - A few widely used AWS services is selected.
#  - If all of these services are present in the list, the list is assumed
#    to be complete and valid.
#  - If any are missing, cache is considered corrupted or incomplete.
#    Execution terminates with a fatal error. If the cached list was used, 
#    user is instructed to invoke swa with -f option to download a new list.
verify_services_list(){

    if (( ${#aws_services_list[@]} == 0 )); then
        if [[ "$used_service_cache" == 1 ]]; then
            print_msg "${MSG_PREFIX} ERROR (12): unknown error while reading service list from cache."
        else
            print_msg "${MSG_PREFIX} ERROR (13): failed to download and build aws services list from ${YELLOW}${AWS_SS_URL}${RESET}"
        fi
        return 1
    fi

    local random_services=(s3 cloud9 dynamodb ec2 eks lambda sagemaker)
    local svc srv
    for svc in "${random_services[@]}"; do
        local found=0
        for srv in "${aws_services_list[@]}"; do
            if [[ "$svc" == "$srv" ]]; then
                found=1
                break
            fi
        done

        if [[ "$found" == 0 ]]; then
            print_msg "${MSG_PREFIX} ERROR (14): unknown error while building aws services list."
            [[ "$used_service_cache" == 1 ]] && print_msg "${MSG_PREFIX} INFO: Invalid service cache. Use -f to download new services list from AWS website."
            return 1
        fi
    done

    return 0

}


# Cache the AWS services list locally for reuse.
#
# Workflow:
#  - Create services cache file as a zero-byte file.
#  - Write the full services list from indexed array and write into service cache file.
#  - A minimum file-size check is performed to validate that the write
#    operation completed successfully.
cache_services_list() {

    :> "${SERVICES_CACHE}" || {
        print_msg "${MSG_PREFIX} ERROR (15): failed to create service cache file at ${YELLOW}${SERVICES_CACHE}${RESET}"
        return 1
    }

    {
        for svc in "${aws_services_list[@]}"; do
            printf '%s\n' "$svc"
        done
    
    } > "${SERVICES_CACHE}" || {
        print_msg "${MSG_PREFIX} ERROR (16): failed writing to service cache file at ${YELLOW}${SERVICES_CACHE}${RESET}"
        return 1
    }

    local size=$(stat -c%s "${SERVICES_CACHE}" 2>/dev/null || stat -f%z "${SERVICES_CACHE}")

    (( size < 1024 )) && {
        print_msg "${MSG_PREFIX} ERROR (17): service cache file is too small (size=${size}) at ${YELLOW}${SERVICES_CACHE}${RESET}"
        return 1
    }

    print_msg "${MSG_PREFIX} INFO: Successfully downloaded and cached AWS services list."
    return 0

}







# Profile data from the config file is validated, collected, and cached.
#
# Workflow:
#   - If a credentials file exists, invoke get_credentials_profiles to collect
#     all available profiles into the profile_list_cred variable
#     (see comments above get_credentials_profiles for details).
#
#   - Validate config file headers to ensure only the allowed character set
#     is used (step 1: regex-based validation).
#
#   - Parse the config file and identify one of the supported header types:
#       * [default]
#       * [profile ...]
#       * [services ...]
#       * [sso-session ...]
#     Anything else → hard error.
#
#   - For all supported header types, perform the second step of character
#     set validation.
#
#   - For profile headers:
#       * Determine the profile type → set_profile_type function
#       * Collect any indented services and their count → get_profile_services function
#       * Index the collected profile data into a single variable
#         to be written later to the profiles cache → index_profile_data function
get_config_profiles() {

    profile_list_cred=""
    if [[ -f "${CRED_FILE}" ]]; then 
        get_credentials_profiles || return 1
    fi
    
    # for error message
    local header_source="config file"
    validate_header_step1 "${CONF_FILE}" || return 1
    
    profile_data=()
    local line_nr line header_line profile_name profile_line_nr svc
    declare -A dup_conf

    declare -A allowed_services=()
    for svc in "${aws_services_list[@]}"; do allowed_services["$svc"]=1; done;
    unset svc

    while IFS=: read -r line_nr line; do

        [[ "$line" =~ ^[[:space:]] ]] && {
            print_msg "${MSG_PREFIX} ERROR (20): leading space at line $line_nr of config file."
            return 1
        }
        
        # for error message
        local header_line="$line"

        case "$line" in
        "[default]"*)
                profile_line_nr="$line_nr"
                profile_name="default"
                set_profile_type || return 1
                get_profile_services || return 1
                index_profile_data || return 1
                continue
                ;;

            "[profile "*)

                [[ "${line:8:1}" == " " ]] || {
                    print_msg "${MSG_PREFIX} ERROR (21): one space required between header prefix and its name at line $line_nr of config file. e.g. [profile devops]"
                    return 1
                }

                line="${line:9}"
                validate_header_step2 || return 1

                profile_line_nr="$line_nr"
                profile_name="${line%]}"
                set_profile_type || return 1
                get_profile_services || return 1
                index_profile_data || return 1
                continue
                ;;

            "[services "*)
                [[ "${line:9:1}" == " " ]] || {
                    print_msg "${MSG_PREFIX} ERROR (22): one space required between header prefix and its name at line $line_nr of config file. e.g. [services devops]"
                    return 1
                }
                line="${line:10}"
                validate_header_step2 || return 1
                continue
                ;;

            "[sso-session "*)
                 [[ "${line:12:1}" == " " ]] || {
                    print_msg "${MSG_PREFIX} ERROR (23): one space required between header prefix and its name at line $line_nr of config file. e.g. [sso-session devops]"
                    return 1
                }
                line="${line:13}"
                validate_header_step2 || return 1
                continue
                ;;

            *)
                print_msg "${MSG_PREFIX} ERROR (24): invalid header in ${header_source} at line $line_nr → $header_line"
                return 1
                ;;
        esac

    done < <(grep -n '\[' "${CONF_FILE}")

    return 0

}


# List profiles in credentials file to assist in determining IAM-User profile types.
# This function is invoked only when a credentials file exists.
#
#   - List all profile headers in credentials file.
#   - Validate the header character set
#   - Detect duplicate profile names
#   - Build an indexed array of profile names
#
# When extracting profile data in config file, profile_list_cred array is used
# to define profile type. Note that credentials file data is not cached.
get_credentials_profiles() {
    
    local header_source="credentials file"
    validate_header_step1 "${CRED_FILE}" || return 1

    local line_nr line header_line
    local profile_name
    declare -A dup_cred
    declare -a list=()

    while IFS=: read -r line_nr line; do

        local header_line="$line"
        
        [[ "$line" =~ ^[[:space:]] ]] && {
            print_msg "${MSG_PREFIX} ERROR (18): leading space at line $line_nr of credentials file."
            return 1
        }

        line="${line:1}"

        validate_header_step2 || return 1

        profile_name="${line%]}"
   
        [[ -n "${dup_cred[$profile_name]}" ]] && {
            print_msg "${MSG_PREFIX} ERROR (19): duplicate profile '$profile_name' at line $line_nr of credentials file."
            return 1
        }
        dup_cred["$profile_name"]=1
        list+=("$profile_name")

    done < <(grep -n '\[' "${CRED_FILE}")

    profile_list_cred=("${list[@]}")

    return 0

}




# Validate header character set to avoid unexpected parsing errors caused by uncommon characters.
# Trimmed lines are used when parsing the config file to safely rely on inexpensive string substitution.
# Therefore, we must ensure the character order and encoding are exactly as expected to prevent incorrect results.

# Validation step-1 using regex
validate_header_step1() {

    local target_file="$1"
    local line_nr=0
    local invalid_found=0
    local line

    while IFS= read -r line; do
        (( ++line_nr ))

        [[ $line != *'['* ]] && continue

        if [[ $line == *[!A-Za-z0-9._\ \[\]-]* ]]; then
            print_msg "${MSG_PREFIX} ERROR (25): invalid character found in header at ${header_source} → line ${line_nr}: ${line}"
            invalid_found=1
        fi
    done < "$target_file"

    (( invalid_found )) && return 1
    return 0
}


# Validation step-2: checking length and other invalid characters
validate_header_step2() {

    local header="$line"
    local name

    # checking if closing bracket exists at all
    if [[ "$header" != *"]"* ]]; then
        print_msg "${MSG_PREFIX} ERROR (24): invalid header in ${header_source} at line $line_nr → $header_line"
        return 1
    fi

    # extra character after closing bracket
    if [[ "$header" =~ \].+ ]]; then
        print_msg "${MSG_PREFIX} ERROR (26): extra character detected after closing bracket in ${header_source} at line $line_nr → '$line'"
        return 1
    fi

    name="${header%]}"

    # length check
    if (( ${#name} > 64 )); then
        print_msg "${MSG_PREFIX} ERROR (27): header name exceeded maximum length of 64 chars in ${header_source} at line $line_nr"
        return 1
    fi

    # space within name e.g. [profile testing site]
    if [[ "$name" == *" "* ]]; then
        print_msg "${MSG_PREFIX} ERROR (28): space detected within the header name in ${header_source} at line $line_nr"
        return 1
    fi

    return 0

}





# set_profile_type determines profile’s type during cache-building process.
#
# workflow:
#  1. Credentials file lookup
#     - If credentials file exists, all profile names are stored in profile_list_cred array in previous steps.
#     - If target profile name (extracted from config file) is found in this list, 
#       the profile is classified as an IAM user and function exits immediately.
#
#  2. Config file lookup
#     - If target profile is not found in credentials file, corresponding profile section 
#       is scanned in config file.
#     - The presence of specific keys determines the profile type.
#
# Profile type short forms:
#  - iam : IAM User
#  - sso : Single Sign-On
#  - ars : AssumeRole (source_profile)
#  - arc : AssumeRole (credential_source)
#  - web : Web Identity
#  - ext : External credential process
set_profile_type() {
    
    local ptype=""
    local prn

    for prn in "${profile_list_cred[@]:-}"; do
        if [[ "$profile_name" == "$prn" ]]; then
            profile_type="iam"
            return 0
        fi
    done

    local key rest
    local start_line=$((profile_line_nr + 1))
    local line_nr=0 
    
    while IFS='=' read -r key rest; do
        
        (( ++line_nr < start_line )) && continue
        
        key=$(trim "$key")
        [[ "$key" == \[* ]] && break

        case "$key" in
            aws_access_key_id)       ptype="iam"  ;;
            sso_account_id)          ptype="sso"  ;;
            source_profile)          ptype="ars"  ;;
            credential_source)       ptype="arc"  ;;
            web_identity_token_file) ptype="web"  ;;
            credential_process)      ptype="ext"  ;;
        esac

        if [[ -n "$ptype" ]]; then
            profile_type="$ptype"
            return 0
        fi

    done < "${CONF_FILE}"

    print_msg "${MSG_PREFIX} ERROR (29): profile type could not be determined for '$profile_name' profile."
    return 1

}



# This function detects any service sections or indented service identifiers 
# belonging to that profile.
#
# Workflow:
#   1. Read values under the target profile
#   2. For each service identifier, increment its occurrence counter.
#   3. Pair service_id and its count in the following format:
#
#        service_1:count service_2:count ... service_N:count
#
# resulting profile_services variable is appended to profile_data array to be cached later.
get_profile_services() {

    local key rest
    local line_nr=0
    local start_line=$((profile_line_nr + 1))

    declare -A svc_count=()
    profile_services=""

    while IFS='=' read -r key rest; do
        
        (( ++line_nr < start_line )) && continue

        key=$(trim "$key")
        [[ -z $key ]] && continue

        case $key in
            "[default]"|"[profile"*) break ;;
        esac

        [[ -n ${allowed_services[$key]+x} ]] && (( svc_count[$key]++ ))

    done < "$CONF_FILE"

    for key in "${!svc_count[@]}"; do
        profile_services+=" $key:${svc_count[$key]}"
    done

    profile_services=${profile_services# }

}



# This function is invoked by get_config_profile for each profile
# in the config file. 
#
# Workflow:
#  1. Detect duplicate profile names within the config file.
#  2. Append all collected data for a single profile into profile_data array.
#
# Data layout per profile (single cache line):
#  - profile_name
#  - profile_type
#  - profile_line_nr
#  - service_1:count service_2:count ... service_N:count (optional)
#
# During cache_profiles_data, each record in profile_data array is read and
# and written into the cache file.
index_profile_data() {

    if [[ -n "${dup_conf[$profile_name]}" ]]; then
        print_msg "${MSG_PREFIX} ERROR (30): duplicate profile '$profile_name' at line $line_nr of config file."
        return 1
    fi

    dup_conf["$profile_name"]=1

    local record="$profile_name $profile_type $profile_line_nr"

    [[ -n "$profile_services" ]] && record+=" $profile_services"

    profile_data+=( "$record" )
    return 0

}


# Writes the fully collected and validated profile data into the cache file.
# This function is called only after all prerequisite steps have completed
# successfully and the in-memory profile data is considered valid.
#
# Workflow:
#  1. Create (or truncate) the cache file as a zero-byte file.
#  2. Retrieve the config file timestamp and writes it as the first line of the cache file
#  3. Read each record in profile_data array and write it to the cache file
#  4. Validate that the cache file is non-empty to confirm a successful write.
cache_profiles_data() {

    :> "${PROFILES_CACHE}" || {
        print_msg "${MSG_PREFIX} ERROR (31): cannot write to ${PROFILES_CACHE}"
        return 1
    }

    get_config_ts || return 1
    printf '[%s]\n' "$current_timestamp" > "${PROFILES_CACHE}"

    local record
    for record in "${profile_data[@]}"; do
        printf '%s\n' "$record" >> "${PROFILES_CACHE}"
    done

    profile_data=()

    if [[ ! -s "${PROFILES_CACHE}" ]]; then
        print_msg "${MSG_PREFIX} ERROR (32): profiles cache file is empty."
        return 1
    fi

    local ts
    if stat --version >/dev/null 2>&1; then
        ts="$(date -d "@$current_timestamp" "+%Y-%m-%d %H:%M:%S %Z")"
    else
        ts="$(date -r "$current_timestamp" "+%Y-%m-%d %H:%M:%S %Z")"
    fi

    print_msg "${MSG_PREFIX} INFO: Successfully cached profiles data as of $ts (config timestamp)."
    return 0

}




# Load profile data from the profiles cache and prompt user to select one.
# If swa is invoked with -l or --list, the cached profiles and their data
# are printed and the function exits without prompting.
# Otherwise, the user is prompted to select a profile from the cached list.
#
# After selection, the following values are resolved and exported to variables
# for use in subsequent steps:
#   - AWS_PROFILE
#   - profile_type
#   - profile_line_nr
#   - profile_services
#
# If service data exists for the selected profile, individual service identifiers
# and their counts are extracted for later use.
set_profile() {

    [[ "${FLAG_LISTING}" -eq 1 ]] && { list_profiles; return 1; }
    
    profile_list=()
    declare -Ag profile_type_map=()
    declare -Ag profile_line_nr_map=()
    declare -Ag profile_services_map=()
    declare -ag profile_service_ids=()
    declare -Ag service_count_map=()
    local line prof_name prof_type prof_line_nr prof_services
    local line_nr=0
    
    while IFS= read -r line; do
        
        (( ++line_nr < 2 )) && continue
            
        IFS=' ' read -r prof_name prof_type prof_line_nr prof_services <<< "$line"
        [[ -z "$prof_name" ]] && continue

        profile_list+=("$prof_name")
        profile_type_map["$prof_name"]="$prof_type"
        profile_line_nr_map["$prof_name"]="$prof_line_nr"
        profile_services_map["$prof_name"]="$prof_services"

    done < "${PROFILES_CACHE}"

    (( ${#profile_list[@]} == 0 )) && {
        print_msg "${MSG_PREFIX} ERROR (33): No profiles found in cache ${PROFILES_CACHE}"
        print_msg "${MSG_PREFIX} INFO: If config file contains valid data, delete cache and invoke swa to rebuild it."
        return 1
    }

    local select_msg="${MSG_PREFIX} Select a profile:"
    select_prompt 1 profile_list[@] || {
        print_msg "${MSG_PREFIX} INFO: No Profile selected"
        return 1
    }

    export AWS_PROFILE="$selected"
    profile_type="${profile_type_map[$AWS_PROFILE]}"
    profile_line_nr="${profile_line_nr_map[$AWS_PROFILE]}"
    profile_services="${profile_services_map[$AWS_PROFILE]}"

    profile_service_ids=()
    service_count_map=()
    profile_services_sum=0

    if [[ -n $profile_services ]]; then
        
        local -a svc_list
        read -ra svc_list <<< "$profile_services"
        
        local svc_pair svc_name svc_count
        for svc_pair in "${svc_list[@]}"; do
    
            IFS=':' read -r svc_name svc_count <<< "$svc_pair"
            [[ -z "$svc_name" || -z "$svc_count" ]] && continue
    
            profile_service_ids+=("$svc_name")
    
            service_count_map["$svc_name"]="$svc_count"
            (( profile_services_sum += svc_count ))
    
        done
    
    fi

    if [[ -z "$profile_type" || -z "$profile_line_nr" ]]; then
        print_msg "${MSG_PREFIX} ERROR (34): profile type or line number missing for profile $AWS_PROFILE"
        print_msg "${MSG_PREFIX} INFO: If config file contains valid data, use -f option to rebuild it."
        return 1
    fi

    return 0

}


# Main dispatcher to get config values for the selected profile.
get_configs() {

    if [[ "$profile_type" == "sso" ]]; then
        sso_login "$AWS_PROFILE" || return 1

    elif [[ "$profile_type" == "iam" ]]; then
        
        iam_global_config "$AWS_PROFILE" || {
            print_msg "${MSG_PREFIX} ERROR (35): failed to get profile's global config."
            return 1
        }

        [[ "${FLAG_MFA}" -eq 1 ]] && mfa_login

        [[ "${profile_services_sum:-0}" -gt 0 ]] && { iam_service_config || return 1; }

        verify_iam_config || return 1

    elif [[ "$profile_type" == "ars" ]]; then

        [[ "${FLAG_MFA}" -eq 1 ]] && mfa_login

    fi

    check_flag || return 1

    return 0

}




# Invoked when the -m / --mfa option is used.
# Checks for mfa_serial in the selected profile and prompts for MFA login.
# If declined or MFA-Login is unsuccessful, workflow continues without a hard error.
mfa_login() {

    local line trimmed srv use_mfa
    local start_line=$(( profile_line_nr + 1 ))
    local line_nr=0

    while IFS= read -r line; do

        (( ++line_nr < start_line )) && continue

        trimmed=$(trim "$line")

        [[ ${trimmed:0:1} == "[" ]] && break

        for srv in "${profile_service_ids[@]}"; do
            [[ ${trimmed%?} == "$srv" ]] && break 2
        done

        [[ ${trimmed:0:11} == "mfa_serial=" ]] && use_mfa=1

    done < "${CONF_FILE}"


    if [[ "${use_mfa}" == 1 ]]; then

        print_msg "${MSG_PREFIX} ${GREEN}${AWS_PROFILE}${RESET} profile is using MFA option."
        gum confirm "Invoke 'aws configure mfa-login'?" || return 0

        aws configure mfa-login --profile "$AWS_PROFILE" </dev/tty >/dev/tty 2>/dev/tty && {
            print_msg "${MSG_PREFIX} INFO: Successful MFA-login."
        }
    else
        print_msg "${MSG_PREFIX} INFO: -m flag ignored. mfa_serial is not defined for ${GREEN}${AWS_PROFILE}${RESET} profile."
    fi

    return 0

}



# Validates authentication state of SSO profile and invokes SSO login if required.
sso_login() {
    
    local target_profile="$1"
    get_caller_identity "$target_profile" && {
        print_msg "${MSG_PREFIX} INFO: SSO Profile is already logged in."
        return 0
    }

    print_msg "${MSG_PREFIX} INFO: Token is expired for SSO profile ${GREEN}${target_profile}${RESET}."
    gum confirm "Invoke 'aws sso login'?" || return 0

    aws sso login --no-browser --profile "$target_profile" </dev/tty >/dev/tty 2>/dev/tty && {
        print_msg "${MSG_PREFIX} INFO: Successful SSO login."
    }
}


# Below function serves as an authentication check for both
# credential-based and SSO-based profiles by invoking the STS GetCallerIdentity API.
#
# Workflow:
#  1. Temporarily unset AWS_ENDPOINT_URL (if defined) to ensure
#     the STS call is routed using AWS official credentials.
#  2. Invoke `aws sts get-caller-identity` and capture both
#     stdout (user's ARN) and stderr (for error message if failed).
get_caller_identity() {
    
    local target_profile="$1"
    local backup_url=""

    if [[ -n "$AWS_ENDPOINT_URL" ]]; then
        backup_url="$AWS_ENDPOINT_URL"
        unset AWS_ENDPOINT_URL
    fi

    USER_ARN=$(aws sts get-caller-identity --profile "$target_profile" --query Arn --output text 2>&1)

    [[ -n "$backup_url" ]] && export AWS_ENDPOINT_URL="$backup_url"
    
    [[ "${USER_ARN:0:3}" != "arn" ]] && {
        # strip leading space that may appear in AWS CLI error output
        USER_ARN="${USER_ARN#"${USER_ARN%%[![:space:]]*}"}"
        return 1
    }

    return 0

}



# Read global config values for IAM user profiles.
# It scans profile’s section to extracts only below global values:
#   - region
#   - ca_bundle
#   - endpoint_url
#
# Notes:
#   - The ca_bundle value is intentionally stored in SWA_CA at this stage.
#     AWS_CA_BUNDLE environment variable is exported later only if CA_REQUIRED is set to 1.
#   - CA_REQUIRED becomes 1 when a ca_bundle is defined in the profile and it exists
#     or when -u option (verify_url function) is used and, in verify_url step,
#     it is determined that the endpoint requires certificate.
iam_global_config() {

    local line key value srv
    local start_line=$(( profile_line_nr + 1 ))
    local line_nr=0

    while IFS= read -r line; do
        
        (( ++line_nr < start_line )) && continue

        line=$(trim "$line")
        [[ "${line:0:1}" == "[" ]] && break
        
        [[ -z "$line" ]] && continue

        key="${line%%=*}"
        value="${line#*=}"
 
        for srv in "${profile_service_ids[@]}"; do
            [[ "$key" == "$srv" ]] && return 0
        done

        case "$key" in
            region) export AWS_REGION="$value" ;;
            ca_bundle) SWA_CA="$value" ;;
            endpoint_url) export AWS_ENDPOINT_URL="$value" ;;
        esac

    done < "${CONF_FILE}"
           
    return 0

}


# Read service-specific config values for IAM user profiles.
#
# This function is invoked only when the selected profile defines one or more
# service identifiers (profile_services_sum > 0).
iam_service_config() {

    if (( profile_services_sum == 1 )); then
        local service_id="${profile_service_ids[0]}"
        gum confirm "${MSG_PREFIX} ${BRIGHT_WHITE}${service_id}${RESET} service found. Set values?" && {
            get_service_values || return 1
        }
        return 0
    fi

    local select_msg="${MSG_PREFIX} ${BRIGHT_WHITE}${profile_services_sum}${RESET} services found. Select (use Tab):"
    select_prompt 2 "profile_service_ids[@]" || return 0
    
    for service_id in "${selected_items[@]}"; do
        [[ -n "$service_id" ]] && {
            get_service_values || return 1
        }
    done

    return 0

}


build_service_section() {

    if [[ -z "$service_id" ]]; then
        print_msg "${MSG_PREFIX} ERROR (37): service_id is not defined to build service section list."
        return 1
    fi

    local start_line=1
    [[ "$profile_line_nr" -gt 1 ]] && start_line="$profile_line_nr"

    section_list=()
    declare -Ag lnr_section
    local line trimmed scope section_name service_seen header_name
    local line_nr=0
    select_item_count=0

    while IFS= read -r line; do

        (( ++line_nr < start_line )) && continue

        trimmed=$(trim "$line")

        if [[ "$trimmed" == "[default]" ]]; then
            [[ "${AWS_PROFILE}" != "default" ]] && break
            service_seen=0
            scope="Profile"
            section_name="default"
            lnr_section["$section_name"]="$line_nr"
            continue
        fi

        if [[ "${trimmed:0:8}" == "[profile" ]]; then
            [[ "$trimmed" != "[profile$AWS_PROFILE]" ]] && break
            service_seen=0
            scope="Profile"
            section_name="${AWS_PROFILE:-}"
            lnr_section["$section_name"]="$line_nr"
            continue
        fi

        if [[ "${trimmed:0:9}" == "[services" ]]; then
            local rest="${trimmed#\[services}"
            section_name="${rest%\]}"
            service_seen=0
            scope="Service"
            lnr_section["$section_name"]="$line_nr"
            continue
        fi

        if [[ "$trimmed" == "$service_id=" ]]; then
            if [[ "${service_seen:-0}" -eq 1 ]]; then
                print_msg "${MSG_PREFIX} ERROR (38): duplicate service '${service_id}' found inside the same section at line: $line_nr"
                return 1
            fi
            service_seen=1

            if [[ "$scope" == "Profile" ]]; then
                header_name="Profile: $section_name"
            else
                header_name="Service: $section_name"
            fi
            section_list+=("$header_name")
            (( select_item_count++ ))
        fi

    done < "${CONF_FILE}"

    return 0


}




get_service_values() {

    local service_count="${service_count_map[$service_id]}"
    local start_line=$(( profile_line_nr + 1 ))
    
    # Build service-sections list for selection when there are more than one
    # instance of the target service_id for the selected profile.
    if [[ "${service_count:-0}" -gt 1 ]]; then

        build_service_section "$service_id" || return 1
        local select_msg="${MSG_PREFIX} Multiple ${service_id} services found. Select one:"
        select_prompt 1 "section_list[@]" || return 0
        start_line="${lnr_section[${selected:9}]}"
    
    fi

    local line trimmed
    local line_nr=0
    local in_block=0
    
    SERVICE_REGION=""
    SERVICE_ENDPOINT=""
    while IFS= read -r line; do
        
        (( ++line_nr < start_line )) && continue

        trimmed=$(trim "$line")
        
        if (( in_block == 1 )); then

            if [[ "$trimmed" != "$service_id=" ]]; then
                [[ "${line:0:1}" != " " ]] && break
            fi

            [[ "${trimmed:0:7}" == "region=" ]] && SERVICE_REGION="${trimmed:7}"
            [[ "${trimmed:0:13}" == "endpoint_url=" ]] && SERVICE_ENDPOINT="${trimmed:13}"
        
        fi

        [[ "$trimmed" == "$service_id=" ]] && in_block=1

    done < "${CONF_FILE}"


    validate_service_values
    return 0

}


validate_service_values() {
    
    if [[ -n "$SERVICE_ENDPOINT" ]]; then

        local sid_upper="$(to_uppercase "$service_id")"
        printf -v "AWS_ENDPOINT_URL_${sid_upper}" '%s' "$SERVICE_ENDPOINT"
        export AWS_ENDPOINT_URL_$sid_upper

    else
        print_msg "${MSG_PREFIX} INFO: ${BRIGHT_WHITE}${service_id}${RESET} service endpoint_url not defined in config."
    fi

    [[ -n "$SERVICE_REGION" ]] && SWA_REGIONS+=("$SERVICE_REGION")

}


to_uppercase() {
    printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}


# Verify values extracted for IAM User profile
verify_iam_config() {

    if [[ -z "${AWS_ENDPOINT_URL}" ]]; then
        if [[ -z "${AWS_ENDPOINT_URL_S3}" ]]; then

            if [[ "${FLAG_VERIFY_URL}" -eq 1 ]]; then
                print_msg "${MSG_PREFIX} INFO: -u flag ignored. endpoint_url is not defined for ${GREEN}${AWS_PROFILE}${RESET} profile."
                FLAG_VERIFY_URL=-1
            fi

            # If s3 endpoint_url is required (-i -3 -5 options) but not explicitly defined in config file,
            # below functions are called to define s3 endpoint_url.
            [[ "${FLAG_MINIO}" -eq 1 ]] && local URL_REQUIRED=1
            [[ "${FLAG_S3CMD}" -eq 1 ]] && local URL_REQUIRED=1
            [[ "${FLAG_S5CMD}" -eq 1 ]] && local URL_REQUIRED=1

            if [[ "${URL_REQUIRED}" -eq 1 ]]; then
                
                if [[ "${FLAG_MINIO}" -eq 1 ]]; then
                    print_msg "${MSG_PREFIX} INFO: endpoint_url is not defined and it is required for mc (MinIO) config file."
                elif [[ "${FLAG_S3CMD}" -eq 1 ]]; then
                    print_msg "${MSG_PREFIX} INFO: endpoint_url is not defined and it is required for s3cmd config file."
                elif [[ "${FLAG_S3CMD}" -eq 1 ]]; then
                    print_msg "${MSG_PREFIX} INFO: endpoint_url is not defined and it is required for s5cmd variable S3_ENDPOINT_URL"
                fi

                print_msg "${MSG_PREFIX} INFO: Attempting to define endpoint_url..."
                get_caller_identity "${AWS_PROFILE}" || {
                    print_msg "${MSG_PREFIX} ERROR (39): failed to get user's ARN."
                    print_msg "${MSG_PREFIX} $USER_ARN"
                    print_msg "${MSG_PREFIX} INFO: credentials are not official AWS or incorrect parameter in config."
                    return 1
                }

                set_aws_s3_url || return 1

            fi

        fi
    fi


    # If ca_bundle defined in config file exists, set CA_REQUIRED to 1 to export it at the end
    # If ca_bundle defined but not exist, invoke verify_url step to check requirement and download it.
    # If verify_url exits successfully, set related flag to -1 to avoid invoking same step again
    # at check_flag function in case -u option is used.
    if [[ -n "${SWA_CA}" ]]; then
        if [[ -f "${SWA_CA}" ]]; then
            CA_REQUIRED=1
        else
            print_msg "${MSG_PREFIX} INFO: ca_bundle defined in config file does not exist."
            print_msg "${MSG_PREFIX} INFO: Verifying ca_bundle requirement..."
            verify_url || return 1
            FLAG_VERIFY_URL=-1
        fi
    fi


    # If regions found under global and service-specific settings are different, user is prompted to select one.
    if [[ -n "${AWS_REGION}" ]]; then
        if [[ ${#SWA_REGIONS[@]} -gt 0 ]]; then

            set_unique_list SWA_REGIONS
            REGIONS_OPT=()
          
            for R in "${SWA_REGIONS[@]}"; do
                if [[ "${AWS_REGION,,}" != "${R,,}" ]]; then
                    SWA_REGION_SELECT=1
                    REGIONS_OPT+=("Service Region: ${R}")
                fi
            done
        fi
    fi

    if [[ -n "${SWA_REGION_SELECT}" ]]; then

        REGIONS_OPT=(" Global Region: ${AWS_REGION}" "${REGIONS_OPT[@]}")
        local select_msg="${MSG_PREFIX} Different regions found. Select one:"
        select_prompt 1 "REGIONS_OPT[@]" && AWS_REGION="${selected:16}"

    fi

}


# removes duplicate entries from an array list.
set_unique_list() {

    local -n arr="$1"
    mapfile -t arr < <(printf "%s\n" "${arr[@]}" | sort -u)

}




# check_flag evaluates user-specified command-line flag and dispatches execution to
# the corresponding functions.
#
# Notes:
#  - The profile listing flag (-l / --list) is intentionally evaluated at the start of 
#    the set_profile function. set_profile is the first entry point after startup initialization 
#    where user interaction occurs in the execution flow. Therefore, when listing option is specified, 
#    swa reads profile data directly from the cache, prints the report, and exits immediately.
check_flag() {

    if [[ "${FLAG_CREDENTIALS}" -eq 1 ]]; then
        
        if [[ "${profile_type}" == "arc" ]]; then

            local assumerole_crd_pn assumerole_crd_pt
            get_credentials_option || return 1

            if [[ -n "${assumerole_crd_pn}" ]]; then
                export_credentials "${assumerole_crd_pn}" || { error_credentials; return 1; }
            fi

        else
            export_credentials "${AWS_PROFILE}" || { error_credentials; return 1; }
        fi

    fi

    if [[ "${FLAG_VERIFY_URL}" -eq 1 ]]; then

        if [[ "${profile_type}" == "iam" ]]; then
            verify_url || return 1
        else
            print_msg "${MSG_PREFIX} INFO: -u flag ignored. ${GREEN}${AWS_PROFILE}${RESET} profile is using official AWS endpoint."
        fi

    fi

    if [[ "${FLAG_S5CMD}" -eq 1 ]]; then
        if [[ "${profile_type}" != "iam" ]]; then
            set_s5cmd || return 1
        fi
    fi

    if [[ "${FLAG_S3CMD}" -eq 1 ]]; then
        set_s3cmd || return 1
    fi

    if [[ "${FLAG_MINIO}" -eq 1 ]]; then 
        set_minio || return 1
    fi
    
}


error_credentials() {

    if [[ "${profile_type}" == "ars" ]]; then
        print_msg "${MSG_PREFIX} ERROR (40): failed to export credentials from source_profile of ${GREEN}${AWS_PROFILE}${RESET}."

    elif [[ "${profile_type}" == "arc" ]]; then
        print_msg "${MSG_PREFIX} ERROR (40): failed to export credentials from ${BRIGHT_WHITE}${assumerole_crd_pn}${RESET} source_profile of ${GREEN}${AWS_PROFILE}${RESET}."

    elif [[ "${profile_type}" == "ext" ]]; then
        print_msg "${MSG_PREFIX} ERROR (40): failed to export credentials using ${BRIGHT_WHITE}credential_process${RESET} option used by ${GREEN}${AWS_PROFILE}${RESET} profile."

    elif [[ "${profile_type}" == "web" ]]; then
        print_msg "${MSG_PREFIX} ERROR (40): failed to export credentials using ${BRIGHT_WHITE}web_identity_token_file${RESET} option of ${GREEN}${AWS_PROFILE}${RESET} profile."

    else
        print_msg "${MSG_PREFIX} ERROR (40): failed to export credentials for ${GREEN}${AWS_PROFILE}${RESET} profile."
    fi

    print_msg "${MSG_PREFIX} ERROR (40): ${err_line}"
    unset err_line

}



# export_credentials exports AWS credentials for the specified profile using
# the `aws configure export-credentials` command.
#
# env format is used to export variables on Linux shell.
#
# Each output line is validated to ensure it begins with `export` before being
# executed via `eval`, preventing accidental execution of unexpected output.
export_credentials() {

    local prof="$1"
    local line

    if [[ -z "$prof" ]]; then
        print_msg "${MSG_PREFIX} ERROR (41): profile name is not defined to export credentials."
        return 1
    fi

    err_line=""
    while IFS= read -r line; do

        [[ -z "$line" ]] && continue

        if [[ "$line" == export\ * ]]; then
            eval "$line"
            continue
        fi

        err_line="$line"
        break
        
    done < <(aws configure export-credentials --profile "$prof" --format env 2>&1)

    [[ -n "$err_line" ]] && return 1
    [[ -n "$AWS_ACCESS_KEY_ID" ]] || return 1
    [[ -n "$AWS_SECRET_ACCESS_KEY" ]] || return 1

    return 0

}

mask_value() {
    local val="$1"
    (( ${#val} <= 8 )) && { printf '%s' "$val"; return; }
    printf '%s****%s' "${val:0:4}" "${val: -4}"
}


mask_credentials() {

    [[ -n "$AWS_ACCESS_KEY_ID" ]] && MASKED_ACCESS_KEY="$(mask_value "$AWS_ACCESS_KEY_ID")"
    [[ -n "$AWS_SECRET_ACCESS_KEY" ]] && MASKED_SECRET_KEY="$(mask_value "$AWS_SECRET_ACCESS_KEY")"
    [[ -n "$AWS_SESSION_TOKEN" ]] && MASKED_TOKEN="$(mask_value "$AWS_SESSION_TOKEN")"

}




# Get credentials option prepares credentials for AssumeRole-based profiles when credentials
# are required e.g. -c, -i, -3 options.
#
# This function is invoked when AssumeRole profile is using credential_source.
# First, it verifies if Environment option is used then:
#
#     * If valid credential environment variables already exist in the shell,
#       user is prompted to use them.
#     * Otherwise, user is prompted to select another profile (excluding arc
#       profiles) to supply credentials.
#
# If selected credential profile is of type SSO and the SSO session
# is not authenticated or has expired, user is prompted to perform an SSO login.
get_credentials_option(){

    local start_line=$(( profile_line_nr + 1 ))
    local line cred_option_value
    local line_nr=0
    
    while IFS= read -r line; do

        (( ++line_nr < start_line )) && continue

        local trimmed=$(trim "$line")
        local key="${trimmed%%=*}"
        local val="${trimmed#*=}"
    
        [[ "$key" == "credential_source" ]] && cred_option_value="$val"

        [[ "${trimmed:0:1}" == "[" ]] && break
        
    done < "${CONF_FILE}"


    if [[ "$cred_option_value" == "Environment" ]]; then
        print_msg "${MSG_PREFIX} INFO: ${GREEN}${AWS_PROFILE}${RESET} profile uses ${BRIGHT_WHITE}Environment${RESET} option for credential_source."
        get_existing_credentials_envs && return 0
        assumerole_credentials_source || return 1
    else
        print_msg "${MSG_PREFIX} ERROR (42): credential_source option is unknown or not suppored."
    fi

    if [[ "${assumerole_crd_pt}" == "sso" ]]; then
        print_msg "${MSG_PREFIX} INFO: Credentials source_profile ${BRIGHT_WHITE}${assumerole_crd_pn}${RESET} is of type SSO."
        print_msg "${MSG_PREFIX} INFO: Verifying login status..."
        sso_login "$assumerole_crd_pn" || return 1
    fi

    return 0

}

# If AssumeRole profile is using credentials_source option with Environment value,
# create a list of profiles excluding profiles of the same type to prompt user for selection.
assumerole_credentials_source() {

    local filtered_list=()
    local prn prof_type

    for prn in "${profile_list[@]}"; do
        prof_type="${profile_type_map[$prn]}"
        [[ "$prof_type" != "arc" ]] && filtered_list+=("$prn")
    done

    if (( ${#filtered_list[@]} == 0 )); then
        print_msg "${MSG_PREFIX} ERROR (43): unknown error occured while defining list of profiles for credentials source."
        return 1
    fi

    if (( FLAG_CREDENTIALS == 1 )); then
        print_msg "${MSG_PREFIX} INFO: credentials of another profile is required to export."
    elif (( FLAG_S3CMD == 1 )); then
        print_msg "${MSG_PREFIX} INFO: credentials of another profile is required for s3cmd config file."
    elif (( FLAG_MINIO == 1 )); then
        print_msg "${MSG_PREFIX} INFO: credentials of another profile is required for mc (MinIO) config file."
    fi

    local select_msg="${MSG_PREFIX} Select profile:"
    select_prompt 1 "filtered_list[@]" || return 1
    
    assumerole_crd_pn="${selected}"
    assumerole_crd_pt="${profile_type_map[$selected]}"

    return 0

}


# If AssumeRole profile is using credentials_source option with
# Environment value and, AWS credentials already exists in envirnoment,
# first prompt to ask if user prefers to use those.
get_existing_credentials_envs() {

    if [[ -n "$SWA_ACCESS_KEY" && -n "$SWA_SECRET_KEY" && -n "$SWA_SESSION_TOKEN" ]]; then
        gum confirm "${MSG_PREFIX} AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY and AWS_SESSION_TOKEN exist in environment. Use them?" || return 1
        export AWS_ACCESS_KEY_ID="$SWA_ACCESS_KEY"
        export AWS_SECRET_ACCESS_KEY="$SWA_SECRET_KEY"
        export AWS_SESSION_TOKEN="$SWA_SESSION_TOKEN"
        return 0
    fi

    if [[ -n "$SWA_ACCESS_KEY" && -n "$SWA_SECRET_KEY" ]]; then
        gum confirm "${MSG_PREFIX} AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY exist in environment. Use them?" || return 1
        export AWS_ACCESS_KEY_ID="$SWA_ACCESS_KEY"
        export AWS_SECRET_ACCESS_KEY="$SWA_SECRET_KEY"
        return 0
    fi

    return 1
}


# This function is invoked only by set_aws_s3_url before setting the s3 endpoint_url.
# It checks whether the target profile has FIPS or Dualstack options enabled.
# If either option is enabled, it sets a flag that is used later to determine appropriate endpoint_url.
get_fips_dualstack() {

    USE_FIPS=0
    USE_DUALSTACK=0

    local start_line=$(( profile_line_nr + 1 ))
    local line_nr=0 
    local line trimmed svc

    while IFS= read -r line; do

        (( ++line_nr < start_line )) && continue
        
        trimmed=$(trim "$line")
        [[ "${trimmed:0:1}" == "[" ]] && break

        for svc in "${profile_service_ids[@]}"; do
            [[ "${trimmed::-1}" == "$svc" ]] && return 0
        done

        if [[ "${trimmed:0:18}" == "use_fips_endpoint=" ]]; then
            [[ "${trimmed:18}" == "true" ]] && USE_FIPS=1
        fi

        if [[ "${trimmed:0:23}" == "use_dualstack_endpoint=" ]]; then
            [[ "${trimmed:23}" == "true" ]] && USE_DUALSTACK=1
        fi

    done < "${CONF_FILE}"

    return 0

}


# If s3 endpoint_url is required but not explicitly defined in the config,
# below function derives correct s3_endpoint_url based on user's ARN via
# STS which detects one of below AWS partitions:
#   - aws        (commercial)
#   - aws-us-gov (GovCloud)
#   - aws-cn     (China)
#
# Meanwhile, if FIPS or DualStack options are set to true for the selected profile,
# resulting endpoint_url considers those options as well (via get_fips_dualstack function)
# and, if region is not defined in config file, default region of AWS partition is assigned.
#
# This logic applies only to official AWS credentials. Custom s3 services must define 
# endpoint_url explicitly in config file.
set_aws_s3_url() {

    if [[ -z "$USER_ARN" ]]; then
        get_caller_identity "$AWS_PROFILE" || { 
            print_msg "${MSG_PREFIX} ERROR (44): failed to get user's ARN."
            print_msg "${MSG_PREFIX} $USER_ARN"
            return 1;
        }
    fi

    get_fips_dualstack

    if [[ "${USER_ARN:0:8}" == "arn:aws:" ]]; then

        [[ -z "$AWS_REGION" ]] && AWS_REGION="us-east-1"

        if [[ "${USE_FIPS:-0}" -eq 1 && "${USE_DUALSTACK:-0}" -eq 1 ]]; then
            AWS_ENDPOINT_URL_S3="https://s3-fips.dualstack.${AWS_REGION}.amazonaws.com"

        elif [[ "${USE_FIPS:-0}" -eq 1 ]]; then
            AWS_ENDPOINT_URL_S3="https://s3-fips.${AWS_REGION}.amazonaws.com"

        elif [[ "${USE_DUALSTACK:-0}" -eq 1 ]]; then
            AWS_ENDPOINT_URL_S3="https://s3.dualstack.${AWS_REGION}.amazonaws.com"
        fi

        [[ -z "$AWS_ENDPOINT_URL_S3" ]] && AWS_ENDPOINT_URL_S3="https://s3.${AWS_REGION}.amazonaws.com"


    elif [[ "${USER_ARN:0:15}" == "arn:aws-us-gov:" ]]; then

        [[ -z "$AWS_REGION" ]] && AWS_REGION="us-gov-west-1"

        if [[ "${USE_FIPS:-0}" -eq 1 && "${USE_DUALSTACK:-0}" -eq 1 ]]; then
            AWS_ENDPOINT_URL_S3="https://s3-fips.dualstack.${AWS_REGION}.amazonaws.com"

        elif [[ "${USE_FIPS:-0}" -eq 1 ]]; then
            AWS_ENDPOINT_URL_S3="https://s3-fips.${AWS_REGION}.amazonaws.com"

        elif [[ "${USE_DUALSTACK:-0}" -eq 1 ]]; then
            AWS_ENDPOINT_URL_S3="https://s3.dualstack.${AWS_REGION}.amazonaws.com"
        fi

        [[ -z "$AWS_ENDPOINT_URL_S3" ]] && AWS_ENDPOINT_URL_S3="https://s3.${AWS_REGION}.amazonaws.com"


    elif [[ "${USER_ARN:0:11}" == "arn:aws-cn:" ]]; then

        [[ -z "$AWS_REGION" ]] && AWS_REGION="cn-north-1"

        if [[ "${USE_DUALSTACK:-0}" -eq 1 ]]; then
            AWS_ENDPOINT_URL_S3="https://s3.dualstack.${AWS_REGION}.amazonaws.com.cn"
        fi

        [[ -z "$AWS_ENDPOINT_URL_S3" ]] && AWS_ENDPOINT_URL_S3="https://s3.${AWS_REGION}.amazonaws.com.cn"

    fi


    if [[ -z "$AWS_ENDPOINT_URL_S3" ]]; then
        print_msg "${MSG_PREFIX} ERROR (45): failed to define s3 endpoint_url."
        return 1
    fi

    set_target_s3_url

    return 0

}




# Below function defines effective s3_endpoint_url which is used internally.
set_target_s3_url() {

    if [[ -n "$AWS_ENDPOINT_URL_S3" ]]; then
        SWA_TARGET_S3URL="$AWS_ENDPOINT_URL_S3"
        S3URL_SRC="SERVICE"
    else
        SWA_TARGET_S3URL="$AWS_ENDPOINT_URL"
        S3URL_SRC="GLOBAL"
    fi

    [[ -n "$SWA_TARGET_S3URL" ]] || { 
        print_msg "${MSG_PREFIX} ERROR (46): failed to define target s3 endpoint_url."
        return 1
    }

    if [[ "${SWA_TARGET_S3URL:0:6}" == "https:" ]]; then
        HOST_BASE="${SWA_TARGET_S3URL:8}"
        HTTP=0
    else
        HOST_BASE="${SWA_TARGET_S3URL:7}"
        HTTP=1
    fi

    return 0

}








# Main dispatcher responsible for validating access to s3_endpoint_url and whether it requires CA Bundle.
#
# Invoked when endpoint verification is required (e.g. -u, -i, -3).
# It determines whether endpoint uses HTTPS or HTTP and whether a custom CA bundle is required.
# if CA Bundle is already defined in config file, validates it.
#
# Workflow:
#   1. Resolve effective S3 endpoint URL.
#   2. If HTTPS is used:
#        - If CA bundle was defined in config file (CA_REQUIRED=1), validate it.
#        - Otherwise, attempt HTTPS connection.
#   3. If endpoint is already using HTTP (HTTP=1), attempt HTTP connection.
verify_url() {

    set_target_s3_url || return 1

    local CURL_OPTS=(-q -s -o /dev/null --connect-timeout 5 --max-time 10)

    if [[ $HTTP -eq 0 ]]; then
        if [[ $CA_REQUIRED -eq 1 ]]; then
            verify_config_ca || return 1
        else
            check_https || return 1
        fi
    else
        check_http || return 1
    fi

    return 0

}


# Attempts to connect to endpoint_url over HTTPS.
#
# curl exit code determines next step:
#   - 0 : Connection succeeded → retrieve HTTP status code for basic server-side validation.
#   - 6 : Host resolution failure → hard error.
#   - 7 : Could not connect to host with HTTPS → fall back to HTTP → 
#          - if failed, hard error.
#          - if HTTP succeed, marks endpoint as HTTP and update endpoint_url
#   - other :
#       Assume TLS or certificate-related failure and attempt to retrieve a CA bundle.
check_https() {

    if curl "${CURL_OPTS[@]}" "$SWA_TARGET_S3URL" 2>/dev/null; then
        print_msg "${MSG_PREFIX} INFO: Endpoint is using Valid Public Certificate."
        get_http_code
        return 0

    else
        local rc=$?

        case $rc in
            6)
                print_msg "${MSG_PREFIX} ERROR (47): could not resolve host: ${HOST_BASE}"
                return 1
                ;;
            7)
                print_msg "${MSG_PREFIX} INFO: HTTPS verification failed. Fallback HTTP..."
                if check_http; then
                    print_msg "${MSG_PREFIX} INFO: Endpoint only supports HTTP."
                else
                    print_msg "${MSG_PREFIX} ERROR (48): could not connect to ${HOST_BASE} on port 443 and 80."
                    return 1
                fi
                return 0
                ;;
            *)
                print_msg "${MSG_PREFIX} INFO: ca_bundle is required. Downloading..."
                download_ca_bundle || return 1
                get_http_code
                return 0
                ;;
        esac
    fi

    return 0

}


# This is used when HTTPS is unavailable or rejected by the server or when endpoint is using HTTP explicitly.
# curl exit code determines next step:
#   - 0 :  Marks endpoint as HTTP.
#          Updates effective endpoint depending on its source (global or service-specific).
#          Retrieves HTTP status code for server-side validation.
#   - other → hard error
check_http() {

    if curl "${CURL_OPTS[@]}" "http://${HOST_BASE}"; then

        HTTP=1
        get_http_code

        if [[ "$S3URL_SRC" == "GLOBAL" ]]; then
            AWS_ENDPOINT_URL="http://${HOST_BASE}"
        else
            AWS_ENDPOINT_URL_S3="http://${HOST_BASE}"
        fi

    else
        print_msg "${MSG_PREFIX} ERROR (49): curl error $rc as endpoint is unreachable via both HTTP and HTTPS protocols."
        return 1
    fi

    return 0

}


# Checking only common server-side errors 500, 502, 503, 504 using curl query
# All status codes are considered acceptable and do not block further processing.
get_http_code() {
    
    local http_code
    local curl_query=()

    if [[ $HTTP -eq 0 ]]; then
        if [[ $CA_REQUIRED -eq 1 ]]; then
            curl_query=(curl "${CURL_OPTS[@]}" --ssl-revoke-best-effort -w "%{http_code}" --cacert "$SWA_CA" "$SWA_TARGET_S3URL")
        else
            curl_query=(curl "${CURL_OPTS[@]}" --ssl-revoke-best-effort -w "%{http_code}" "$SWA_TARGET_S3URL")
        fi
    else
        curl_query=(curl "${CURL_OPTS[@]}" -w "%{http_code}" "http://${HOST_BASE}")
    fi

    http_code="$("${curl_query[@]}")"
    [[ -z $http_code ]] && return 0
    case "$http_code" in
        500) print_msg "${MSG_PREFIX} ERROR (50): 500 Internal Error." ;;
        502) print_msg "${MSG_PREFIX} ERROR (52): 502 Bad Gateway (backend refused connection)." ;;
        503) print_msg "${MSG_PREFIX} ERROR (53): 503 Service Unavailable (backend unavailable)." ;;
        504) print_msg "${MSG_PREFIX} ERROR (54): 504 Gateway Timeout." ;;
    esac

    return 0


}



# Verifies HTTPS connectivity using a CA bundle provided in the config file.
#
# curl exit code determines next step:
#   - 0 : CA is valid → continue and evaluate HTTP status code.
#   - 77: CA file missing or invalid → attempt to download new CA bundle.
#   - 6 : Host resolution failure → hard error.
#   - 7 : Could not connect to host with HTTPS → fall back to HTTP → 
#          - if failed, hard error.
#          - if HTTP succeed, marks the endpoint as HTTP and update endpoint_url
#   - other → hard error
verify_config_ca() {

    if curl "${CURL_OPTS[@]}" --ssl-revoke-best-effort --cacert "$SWA_CA" "$SWA_TARGET_S3URL" 2>/dev/null; then
        print_msg "${MSG_PREFIX} INFO: Successfully verified ca_bundle in config file."
        get_http_code
        return 0

    else
        local rc=$?

        case $rc in
            77)
                print_msg "${MSG_PREFIX} INFO: ca_bundle specified in config file is invalid. Downloading..."
                download_ca_bundle || return 1
                get_http_code
                return 0
                ;;
            6)
                print_msg "${MSG_PREFIX} ERROR (47): could not resolve host: ${HOST_BASE}"
                return 1
                ;;
            7)
                print_msg "${MSG_PREFIX} INFO: HTTPS verification failed. Fallback HTTP..."
                if check_http; then
                    print_msg "${MSG_PREFIX} INFO: Endpoint only supports HTTP."
                else
                    print_msg "${MSG_PREFIX} ERROR (48): could not connect to ${HOST_BASE} on port 443 and 80"
                    return 1
                fi
                return 0
                ;;
            *)
                print_msg "${MSG_PREFIX} ERROR (51): curl error $rc while verifying existing ca_bundle."
                return 1
                ;;
        esac
    fi


    return 0


}



# Downloads new CA bundle when the endpoint uses a self-signed or invalid certificate.
# This function is invoked when HTTPS is required and configured CA bundle is missing, 
# invalid, or not trusted.
#
# Workflow:
#   1. Ensure local certificate directory exists.
#   2. Download full certificate chain from endpoint.
#   3. Extract certificate blocks from raw certificate and store it in a PEM file.
#   4. Validate HTTPS connectivity using the new CA bundle.
#   5. Add new CA bundle path into config file for selected profile.
download_ca_bundle() {
    
    CA_REQUIRED=1
    CERT_DIR="$(dirname "${CONF_FILE}")/certs"
    mkdir -p "$CERT_DIR" 2>/dev/null || {
        print_msg "${MSG_PREFIX} ERROR (55): failed to create certificates directory at ${YELLOW}${CERT_DIR}${RESET}"
        return 1
    }

    # Unlike the Windows, Linux does not require removing colons from filenames.
    # However, I am removing and replacing it with hyphen (same as swa's batch script),
    # so the certificate filename is consistent in both platforms.
    CA_FILENAME="${HOST_BASE//:/-}"
    SWA_CA="${CERT_DIR}/${CA_FILENAME}-chain.pem"

    RAW_CERT="${CERT_DIR}/raw_cert"
    : > "$RAW_CERT" || {
        print_msg "${MSG_PREFIX} ERROR (56): failed to create raw_cert file at ${YELLOW}${RAW_CERT}${RESET}"
        return 1
    }

    if curl -q -s -k -w "%{certs}" "$SWA_TARGET_S3URL" > "$RAW_CERT"; then
        print_msg "${MSG_PREFIX} INFO: Successfully downloaded raw certificate chain."
    else
        print_msg "${MSG_PREFIX} ERROR (57): failed to download raw certificate chain from $SWA_TARGET_S3URL"
        return 1
    fi

    if extract_cert_blocks; then
        print_msg "${MSG_PREFIX} INFO: Successfully extracted certificates."
    else
        print_msg "${MSG_PREFIX} ERROR (58): failed to extract ca_bundle from raw certificate chain."
        return 1
    fi

    if curl "${CURL_OPTS[@]}" --ssl-revoke-best-effort --cacert "$SWA_CA" "$SWA_TARGET_S3URL"; then
        print_msg "${MSG_PREFIX} INFO: Successfully verified new ca_bundle."
    else
        print_msg "${MSG_PREFIX} ERROR (59): new ca_bundle is invalid."
        return 1
    fi


    if aws configure set profile."$AWS_PROFILE".ca_bundle "$SWA_CA" 2>&1; then
        print_msg "${MSG_PREFIX} INFO: Successfully added new ca_bundle path to config file."
    else
        print_msg "${MSG_PREFIX} ERROR (60): failed to update AWS config with new ca_bundle path."
        return 1
    fi

    return 0

}


 
extract_cert_blocks() {

    local in_cert=0
    local line

    :> "$SWA_CA" || return 1

    while IFS= read -r line; do
        
        [[ $line == '-----BEGIN CERTIFICATE-----' ]] && in_cert=1
        (( in_cert )) && printf '%s\n' "$line"
        [[ $line == '-----END CERTIFICATE-----' ]] && in_cert=0

    done < "$RAW_CERT" >> "$SWA_CA"


}



# Invoked when -3 option is used to update config file of s3cmd.
set_s3cmd() {

    if [[ "$profile_type" == "iam" ]]; then

        if [[ "$FLAG_VERIFY_URL" != "-1" ]]; then
            if [[ ! -n "$USER_ARN" ]]; then
                verify_url || return 1
            fi
        fi
        
        export_credentials "$AWS_PROFILE" || {
            print_msg "${MSG_PREFIX} ERROR (61): failed to define credentials required for s3cmd config file."
            return 1
        }

    elif [[ "${profile_type}" == "arc" ]]; then
    
        local assumerole_crd_pn dassumerole_crd_pt
        get_credentials_option || return 1
  
        if [[ -n "$assumerole_crd_pn" ]]; then
            export_credentials "$assumerole_crd_pn" || {
                print_msg "${MSG_PREFIX} ERROR (62): failed to define credentials required for s3cmd config file."
                return 1
            }
        fi

        get_region
        set_aws_s3_url || return 1

    else

        if [[ "$profile_type" == "sso" ]]; then
            get_sso_region || return 1
        else
            get_region
        fi

        export_credentials "$AWS_PROFILE" || {
            print_msg "${MSG_PREFIX} ERROR (63): failed to define credentials required for s3cmd config file."
            return 1
        }

        set_aws_s3_url || return 1
    
    fi


    local S3CFG="$HOME/.s3cfg"

    : > "$S3CFG" || {
        print_msg "${MSG_PREFIX} ERROR (64): failed to create s3cmd config file at ${YELLOW}${S3CFG}${RESET}"
        return 1
    }

    {
        printf '[%s]\n' "$AWS_PROFILE"
        printf 'host_base = %s\n' "$HOST_BASE"
        printf 'host_bucket = %s_\n' "$HOST_BASE"
        printf 'access_key = %s\n' "$AWS_ACCESS_KEY_ID"
        printf 'secret_key = %s\n' "$AWS_SECRET_ACCESS_KEY"

        [[ -n $AWS_SESSION_TOKEN ]] && printf 'access_token = %s\n' "$AWS_SESSION_TOKEN"

        if (( HTTP == 0 )); then
            printf 'use_https = True\n'
            printf 'check_ssl_certificate = True\n'
        else
            printf 'use_https = False\n'
            printf 'check_ssl_certificate = False\n'
        fi

        if (( CA_REQUIRED == 1 )); then
            printf 'ca_certs_file = "%s"\n' "$SWA_CA"
        fi

    } >> "$S3CFG" || {
        print_msg "${MSG_PREFIX} ERROR (65): failed writing to s3cmd config file at ${YELLOW}${S3CFG}${RESET}"
        return 1
    }


    print_msg "${MSG_PREFIX} INFO: Successfully updated ${YELLOW}${S3CFG}${RESET}" >&2

    local ev
    for ev in ${!AWS_@}; do unset "$ev"; done;
    
    return 2

}


# Invoked when -i option is used to updates mc MinIO client's config file for s3 alias and, 
# prompts user to export MC_HOST_S3 envirnoment variable.
set_minio() {

    if ! command -v mc >/dev/null 2>&1; then
        print_msg "${MSG_PREFIX} ERROR (66): MinIO client (mc) not found."
        return 1
    fi

    # Verify it's the MinIO CLI, not Midnight Commander
    if ! mc --version 2>/dev/null | grep -qi "MinIO"; then
        print_msg "${MSG_PREFIX} ERROR (66): MinIO client (mc) not found."
        return 1
    fi

    if [[ "$profile_type" == "iam" ]]; then

        if [[ "$FLAG_VERIFY_URL" != "-1" ]]; then
            if [[ ! -n "$USER_ARN" ]]; then
                verify_url || return 1
            fi
        fi

        export_credentials "$AWS_PROFILE" || {
            print_msg "${MSG_PREFIX} ERROR (67): failed to define credentials required for mc."
            return 1
        }

    elif [[ "${profile_type}" == "arc" ]]; then

        local assumerole_crd_pn dassumerole_crd_pt
        get_credentials_option || return 1

        if [[ -n "$assumerole_crd_pn" ]]; then
            export_credentials "$assumerole_crd_pn" || {
                print_msg "${MSG_PREFIX} ERROR (68): failed to define credentials required for mc."
                return 1
            }
        fi

        get_region
        set_aws_s3_url || return 1

    else

        if [[ "$profile_type" == "sso" ]]; then
            get_sso_region || return 1
        else
            get_region
        fi

        export_credentials "$AWS_PROFILE" || {
            print_msg "${MSG_PREFIX} ERROR (69): failed to define credentials required for mc (MinIO)."
            return 1
        }

        set_aws_s3_url || return 1
    fi

    mc alias set s3 "$SWA_TARGET_S3URL" \
        "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" \
        --api S3v4 --path auto >/dev/null 2>&1

    if [[ $? -ne 0 ]]; then
        print_msg "${MSG_PREFIX} ERROR (70): failed to update mc (MinIO) config file."
        return 1
    fi

    if [[ "$CA_REQUIRED" -eq 1 ]]; then

        MC_CA_DIR="$HOME/.mc/certs/CAs"
        mkdir -p "$MC_CA_DIR" >/dev/null 2>&1 || {
            print_msg "${MSG_PREFIX} ERROR (71): failed to create ~/.mc/certs/CAs directory."
            return 1
        }

        MC_CA_FILENAME="${HOST_BASE//:/-}"
        MC_CA_BUNDLE="$MC_CA_DIR/${MC_CA_FILENAME}-chain.pem"

        if [[ ! -f "$MC_CA_BUNDLE" ]]; then
            if cp "$SWA_CA" "$MC_CA_BUNDLE" >/dev/null 2>&1; then 
                print_msg "${MSG_PREFIX} INFO: Successfully copied certificate to ${YELLOW}${MC_CA_BUNDLE}${RESET}"
            else
                print_msg "${MSG_PREFIX} ERROR (72): failed copying CA bundle to ~/.mc/certs/CAs"
                return 1
            fi
        else
            print_msg "${MSG_PREFIX} INFO: Certificate exists ${YELLOW}${MC_CA_BUNDLE}${RESET}. Ignored copying to ~/.mc/certs/CAs"
            
        fi

        CA_REQUIRED=-1
  
    fi


    if gum confirm "Export ${BRIGHT_WHITE}MC_HOST_S3${RESET} environment variable?"; then

        mask_credentials

        if [[ -n "$AWS_SESSION_TOKEN" ]]; then
            if [[ "$HTTP" -eq 0 ]]; then
                MC_HOST_S3="https://${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}:${AWS_SESSION_TOKEN}@${HOST_BASE}"
                MASKED_MC_HOST_S3="https://${MASKED_ACCESS_KEY}:${MASKED_SECRET_KEY}:${MASKED_TOKEN}@${HOST_BASE}"
            else
                MC_HOST_S3="http://${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}:${AWS_SESSION_TOKEN}@${HOST_BASE}"
                MASKED_MC_HOST_S3="http://${MASKED_ACCESS_KEY}:${MASKED_SECRET_KEY}:${MASKED_TOKEN}@${HOST_BASE}"
            fi
        else
            if [[ "$HTTP" -eq 0 ]]; then
                MC_HOST_S3="https://${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}@${HOST_BASE}"
                MASKED_MC_HOST_S3="https://${MASKED_ACCESS_KEY}:${MASKED_SECRET_KEY}@${HOST_BASE}"
            else
                MC_HOST_S3="http://${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}@${HOST_BASE}"
                MASKED_MC_HOST_S3="http://${MASKED_ACCESS_KEY}:${MASKED_SECRET_KEY}@${HOST_BASE}"
            fi
        fi

    fi

    print_msg "${MSG_PREFIX} INFO: Successfully updated ${YELLOW}${HOME}/.mc/config.json${RESET}"

    local ev
    for ev in ${!AWS_@}; do unset "$ev"; done;

    [[ ! -n "$MC_HOST_S3" ]] && return 2

    return 0

}


# Invoked only when selected profile types is AssumeRole (source_profile), Web Identity or 
# External Process; and when -i or -3 option is used. 
# It extracts region value to define s3_endpoint_url.
get_region() {

    local start_line=$(( profile_line_nr + 1 ))
    local line_nr=0
    local line trimmed srv

    while IFS= read -r line; do
        
        (( ++line_nr < start_line )) && continue

        local trimmed=$(trim "$line")
        [[ "${trimmed:0:1}" == "[" ]] && return 0

        for srv in "${profile_service_ids[@]}"; do
            [[ "${trimmed%?}" == "$srv" ]] && return 0
        done

        [[ "${trimmed:0:7}" == "region=" ]] && AWS_REGION="${trimmed:7}"

    done < "${CONF_FILE}"

    return 0

}




# Invoked if region is required to construct s3 endpoint_url. 
# SSO profiles may define region either under profile header (Legacy)
# or under associated sso-session header (New-Format). 
# Therefore, both sections are scanned.
#
# Workflow:
#  1. Parse the selected profile section.
#     - Get `sso_region` if defined directly.
#     - Get `sso_session` name if present.
#  2. If `sso_region` was not found, scan sso-session.
get_sso_region() {

    local start_line=$(( profile_line_nr + 1 ))
    local line_nr=0
    local line trimmed
    local SSO_SESSION_NAME="" SSO_REGION=""

    while IFS= read -r line; do
        
        (( ++line_nr < start_line )) && continue

        local trimmed=$(trim "$line")

        if [[ "${trimmed:0:12}" == "sso_session=" ]]; then
            SSO_SESSION_NAME="${trimmed:12}"
        elif [[ "${trimmed:0:11}" == "sso_region=" ]]; then
            SSO_REGION="${trimmed:11}"
        fi

        [[ "${trimmed:0:1}" == "[" ]] && break

    done < "${CONF_FILE}"

    if [[ -n "$SSO_REGION" ]]; then
        AWS_REGION="$SSO_REGION"
        return 0
    fi

    if [[ -z "$SSO_SESSION_NAME" ]]; then
        print_msg "${MSG_PREFIX} ERROR (73): sso_session name and sso_region not found."
        return 1
    fi

    local in_block=0
    while IFS= read -r line; do

        local trimmed=$(trim "$line")

        if [[ $in_block -eq 1 ]]; then
            [[ "${trimmed:0:11}" == "sso_region=" ]] && SSO_REGION="${trimmed:11}"
            [[ "${trimmed:0:1}" == "[" ]] && break
        fi

        [[ "$trimmed" == "[sso-session$SSO_SESSION_NAME]" ]] && in_block=1

    done < "${CONF_FILE}"

    AWS_REGION="$SSO_REGION"
    if [[ -z "$AWS_REGION" ]]; then
        print_msg "${MSG_PREFIX} ERROR (74): sso_region not found."
        return 1
    fi

    return 0

}



# set_s5cmd defines endpoint_url to export S3_ENDPOINT_URL variable of s5cmd.
#
# Invoked only for non-IAM profile types. For IAM user profiles, 
# s3 endpoint is either obtained directly from config file or already 
# resolved earlier in verify_iam_config function.
#
# Workflow:
#  1. Determine AWS region of selected profile.
#  2. Invoke set_aws_s3_url to construct s3 endpoint_url.
set_s5cmd() {

    if [[ "$profile_type" == "sso" ]]; then
        get_sso_region || return 1
    else
        get_region || return 1
    fi

    set_aws_s3_url || return 1

    [[ "$profile_type" == "sso" ]] && unset AWS_REGION

    return 0

}





# list_profiles prints a report of profiles currently defined in config file.
#
# Workflow:
#  - If swa is invoked with -l or --list option, profiles are read from cache file,
#    report is printed on shell and swa exits immediately.
#
# Note: 
#    Data is not parsed directly from config file and instead, it is read from cache for 
#    faster output, especially for large config files.
#
# Report content:
#  - Profile name
#  - Profile type (Human-readable)
#  - Service-Specific (SS) count per profile
#  - Total of profiles and services at the footer
list_profiles() {

    declare -A PTYPE_MAP
    declare -A PROFILE_TYPE
    declare -A PROFILE_SERVICES_SUM
    profile_list=()

    PTYPE_MAP=(
        [iam]="IAM User"
        [sso]="SSO"
        [ars]="Assume Role"
        [arc]="Assume Role"
        [web]="Web Identity"
        [ext]="External Process"
    )

    local pname ptype lnr services
    local line_nr=0
    while read -r pname ptype lnr services; do
        
        (( ++line_nr < 2 )) && continue

        profile_list+=("$pname")
        PROFILE_TYPE["$pname"]="${PTYPE_MAP[$ptype]}"

        local sum=0
        local svc id count
        for svc in $services; do
            IFS=':' read -r id count <<< "$svc"
            (( sum += count ))
        done
        PROFILE_SERVICES_SUM["$pname"]=$sum

    done < "${PROFILES_CACHE}"

    local max_len=0 
    local prn
    for prn in "${profile_list[@]}"; do
        (( ${#prn} > max_len )) && max_len=${#prn}
    done

    {
        printf "%s Profiles list:\n\n" "$MSG_PREFIX"
        printf "%-${max_len}s    %-17s %s\n" "ProfileName" "ProfileType" "SS"
        printf "%-${max_len}s    %-17s %s\n" \
            "$(printf '%.0s-' $(seq 1 ${max_len}))" \
            "-----------------" \
            "--"

        local total_profiles=0
        local total_services=0

        for prn in "${profile_list[@]}"; do
            printf "%-${max_len}s    %-17s %s\n" \
                "$prn" \
                "${PROFILE_TYPE["$prn"]}" \
                "${PROFILE_SERVICES_SUM["$prn"]}"

            (( total_profiles++ ))
            (( total_services += PROFILE_SERVICES_SUM["$prn"] ))
        done

        local footer_len=$((max_len + 24))
        printf "%s\n" "$(printf '%.0s-' $(seq 1 $footer_len))"

        printf "   PROFILE: %d\n" "$total_profiles"
        printf "SERVICE-ID: %d\n\n" "$total_services"
        printf "%s*SS = \"Service-Specific\"%s\n" "$GRAY" "$RESET"

    } >&2
    
}




# select prompt is the main dispatcher for all interactive selection prompts.
# This function invokes `gum` CLI whenever user is asked to select one or more
# items from a list.
#
# Argument-1 → Select mode
# Argument-2 → Select options
# 
# Selection modes:
#  - Mode 1 (single_select): user selects exactly one item. It auto-selects if only one option.
#  - Mode 2 (custom_select): user may select one or more items.
#
# Selection menu type:
#  - For lists ≤ 15 items, uses `gum choose` for direct navigation.
#  - For lists > 15 items, uses `gum filter` to allow search by typing.
#
# Notes:
#  - Prompt options are passed indirectly to preserve quotes when used.
#  - Prompt header message (`select_msg`) is defined prior to invoking select prompt.
#    Since this variable name is consistent across the script, it is not passed as argument.
#    In contrast, prompt options (`select_opts`) vary by context and source, so it is passed as argument.
select_prompt() {
    
    local select_mode="$1"
    local select_opts_tmp="$2"
    local select_opts=("${!select_opts_tmp}")
    
    if [[ ${#select_opts[@]} -eq 0 ]]; then
        print_msg "${MSG_PREFIX} ERROR (36): no options provided for gum selection list" >&2
        return 1
    fi

    [[ -z "$select_mode" ]] && select_mode=1

    if [[ "$select_mode" -eq 1 ]]; then
        single_select || return 1
    else
        custom_select || return 1
    fi

    return 0

}

single_select() {
    
    selected=""
    local select_command
    if (( ${#select_opts[@]} > 15 )); then
        select_command=(gum filter --header "$select_msg" "${select_opts[@]}")
    else
        select_command=(gum choose --select-if-one --header "$select_msg" "${select_opts[@]}")
    fi

    selected="$("${select_command[@]}")"

    [[ -z "$selected" ]] && return 1

    return 0

}

custom_select() {

    local select_command

    if (( ${#select_opts[@]} > 15 )); then
        select_command=(gum filter --no-limit --header "$select_msg" "${select_opts[@]}")
    else
        select_command=(gum choose --no-limit --header "$select_msg" "${select_opts[@]}")
    fi

    declare -ag selected_items
    mapfile -t selected_items < <("${select_command[@]}")
    
    (( ${#selected_items[@]} == 0 )) && return 1

    return 0

}


trim() {
    printf '%s' "$1" | tr -d '[:space:]'
}


print_msg() {
    printf '%b\n' "$*" >&2
}



main() {

   local _ARG="${1:-}"
   local _VERSION="1.0.0"
   local _REPO="https://github.com/bruckware/swa"

   LC_ALL=C
   LANG=C

   ESC=$'\033'
   RESET="${ESC}[0m"
   GRAY="${ESC}[90m"
   BLUE="${ESC}[34m"
   GREEN="${ESC}[32m"
   YELLOW="${ESC}[33m"
   BRIGHT_WHITE="${ESC}[97m"
   ORANGE="${ESC}[38;2;255;165;0m"
   MSG_PREFIX="${ORANGE}[swa]${RESET}"
   export GUM_FILTER_MATCH_FOREGROUND="#FFA500"
   export GUM_CHOOSE_CURSOR_FOREGROUND="#FFA500"
   export GUM_CONFIRM_PROMPT_FOREGROUND="#C0C0C0"
   export GUM_CHOOSE_SELECTED_FOREGROUND="#FFA500"
   export GUM_CONFIRM_SELECTED_BACKGROUND="#FFA500"
   export GUM_FILTER_INDICATOR_FOREGROUND="#FFA500"
   export GUM_FILTER_CURSOR_TEXT_FOREGROUND="#FFA500"
   export GUM_FILTER_SELECTED_PREFIX_FOREGROUND="#FFA500"

   if [[ $# -gt 1 ]]; then
      print_msg "${MSG_PREFIX} ERROR (1): Too many arguments. Use -h for help."
      return 1 
   fi
   
   # Set options and alter if argurment is passed, check requirements, 
   # select profile, get config values.
   set_options || return 1
   requirement || return 1
   set_profile || return 1
   get_configs || return 1

    
   
   # Export variables on running shell by printing `export` command to stdout for `eval`.
   # To prevent conflict of AWS variables from previous runs, first, clears all AWS_* variables 
   # from running shell by printing `unset` command for `eval` except for AWS_CONFIG_FILE and AWS_SHARED_CREDENTIALS_FILE if exist.
   # If there are other AWS variables that you want to keep in running shell session, adjust the logic in below for-loop.
   local ev
   print_msg "${MSG_PREFIX} INFO: Exported variables:"
   for ev in "${_ENV_SNAPSHOT[@]}"; do
       case "$ev" in
           AWS_CONFIG_FILE|AWS_SHARED_CREDENTIALS_FILE) continue ;;
           *) printf 'unset %s\n' "$ev" ;;
       esac
   done
     
   for ev in ${!AWS_@}; do
       printf 'export %s=%q\n' "$ev" "${!ev}"
       print_msg " $ev=${GREEN}${!ev}${RESET}"
   done

   if [[ "$CA_REQUIRED" -eq 1 ]]; then
       printf 'export AWS_CA_BUNDLE=%q\n' "$SWA_CA"
       print_msg " AWS_CA_BUNDLE=${GREEN}${SWA_CA}${RESET}"
   fi

   if [[ "$FLAG_S5CMD" -eq 1 ]]; then
       if [[ -n "$AWS_ENDPOINT_URL_S3" ]]; then
           printf 'export S3_ENDPOINT_URL=%q\n' "$AWS_ENDPOINT_URL_S3"
           print_msg " S3_ENDPOINT_URL=${GREEN}${AWS_ENDPOINT_URL_S3}${RESET}"
       else
           printf 'export S3_ENDPOINT_URL=%q\n' "$AWS_ENDPOINT_URL"
           print_msg " S3_ENDPOINT_URL=${GREEN}${AWS_ENDPOINT_URL}${RESET}"
       fi
   fi

   if [[ -n "$MC_HOST_S3" ]]; then
       printf 'export MC_HOST_S3=%q\n' "$MC_HOST_S3"
       print_msg " MC_HOST_S3=${GREEN}${MASKED_MC_HOST_S3}${RESET}"
   fi


}



main "$@"