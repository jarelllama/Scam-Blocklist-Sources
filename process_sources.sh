#!/bin/bash

# Retrieve results from the configured sources and save them into monthly
# results files.
# Prune monthly results files from the sources that are not within the source's
# configured rolling period.
# Collate results from each source into their own collated results file.
# Collate results from all sources into a collective collated results file.

readonly TIMEZONE='Asia/Singapore'

readonly SOURCES_CONFIG='sources.csv'
readonly SOURCES_CONFIG_HEADER='Source name,Retrieve enabled (y/N),Source function,Prune enabled (y/N),Rolling period (months),Collate enabled (y/N),Include in raw (y/N)'
readonly SOURCES_ROOT_DIR='sources'

readonly RETRIEVE_ENABLED=false
readonly RETRIEVE_LOG='logs/retrieve_log.csv'
readonly RETRIEVE_SOURCES_SCRIPT='sources.sh'

readonly PRUNE_ENABLED=false
readonly PRUNE_LOG='logs/prune_log.csv'
readonly PRUNE_DEFAULT_ROLLING_PERIOD=1  # In months

readonly COLLATE_ENABLED=false
readonly COLLATE_LOG='logs/collate_log.csv'

readonly COLLATE_ALL_ENABLED=false
readonly COLLATE_ALL_LOG='logs/collate_all_log.csv'
readonly COLLATE_ALL_RESULTS_FILE='collated.txt'

readonly LOG_ENABLED=true
readonly LOG_MAX_ENTRIES=1000  # Does not include the header
declare -A LOG_HEADERS=(
    ["$RETRIEVE_LOG"]='Results,New results,Function,Save path,Processing time (seconds)'
    ["$PRUNE_LOG"]='File path,Rolling period (months),Cut-off month'
    ["$COLLATE_LOG"]='Results path,Results count,Collated results path, Collated results count'
    ["$COLLATE_ALL_LOG"]='Results path,Results count,Collated results path, Collated results count'
)

main() {
    # Set the timezone
    timedatectl set-timezone "$TIMEZONE"

    validate_sources_config
    validate_sources_root_dir
    validate_log_files

    # Process sources if any are found in the sources config file
    if [[ -n "$(tail -n +2 "$SOURCES_CONFIG")" ]]; then
        process_sources
        return
    fi

    print_to_con 'warn' \
        "No sources found in sources config file '${SOURCES_CONFIG}'. Exiting"

    exit 1
}

# Validate the sources config file.
# Non-local variables:
#   $SOURCES_CONFIG
#   $SOURCES_CONFIG_HEADER
validate_sources_config() {
    # Ensure the sources config file exists
    if [[ ! -f "$SOURCES_CONFIG" ]]; then
        print_to_con 'warn' \
            "Sources config file '${SOURCES_CONFIG}' does not exist. Will create"
        mkdir -p "$(dirname "$SOURCES_CONFIG")"
        printf "%s\n" "$SOURCES_CONFIG_HEADER" > "$SOURCES_CONFIG"
        exit 1
    fi

    # Ensure the sources config file header is correct
    if ! grep -qFx "$SOURCES_CONFIG_HEADER" "$SOURCES_CONFIG"; then
        print_to_con 'info' \
            "Header in sources config file '${SOURCES_CONFIG}' is incorrect. Will update"
        # Escape slashes
        sed -i "1s/.*/${SOURCES_CONFIG_HEADER//\//\\/}/" "$SOURCES_CONFIG"
    fi

    # Check for missing fields in the sources config file
    if ! mawk -F ',' '
        # Count the number of fields in the header
        NR == 1 { fields_count = NF; next }
        # Check if the number of fields in the line is the same as the header
        NF != fields_count { exit 1 }
        ' "$SOURCES_CONFIG"
    then
        print_to_con 'warn' \
            "Sources config file '${SOURCES_CONFIG}' has missing fields. Exiting"
        # Exit to avoid configuration errors
        exit 1
    fi
}

# Validate the source root directory and source directories
# Non-local variables:
#   $SOURCE_ROOT_DIR
#   $SOURCES_CONFIG
validate_sources_root_dir() {
    # Ensure the sources root directory exists
    if [[ ! -d "$SOURCES_ROOT_DIR" ]]; then
        print_to_con 'info' \
            "Sources root directory '${SOURCES_ROOT_DIR}' does not exist. Will create"
        mkdir -p "$SOURCES_ROOT_DIR"
        return
    fi

    # Check the source directories
    local source_dir source_name
    for source_dir in "${SOURCES_ROOT_DIR}"/*; do
        [[ ! -d "$source_dir" ]] && continue

        source_name="${source_dir##*/}"

        # Check for orphaned source directories
        if ! grep -qiF "${source_name//_/ }" "$SOURCES_CONFIG"; then
            print_to_con 'warn' "Source directory '${source_dir}' is an orphan"
        fi

        # Check for unwanted files
        while read -r unwanted_file; do
            [[ ! -f "$unwanted_file" ]] && continue
            print_to_con 'warn' \
                "Unwanted file '${unwanted_file}' found"
        done <<< "$(find "$source_dir" -type f -regextype posix-extended \
            ! -regex ".*/${source_name}(_[0-9]{4}-[0-9]{2})?\.txt")"
    done
}

# Validate the log files.
# Non-local variables:
#   $RETRIEVE_LOG
#   $PRUNE_LOG
#   $COLLATE_LOG
#   $COLLATE_ALL_LOG
#   $RETRIEVE_LOG_HEADER
#   $PRUNE_LOG_HEADER
#   $COLLATE_LOG_HEADER
#   $COLLATE_ALL_LOG_HEADER
validate_log_files() {
    # Ensure the log files exist with the correct header
    local log_file log_header
    for log_file in "$RETRIEVE_LOG" "$PRUNE_LOG" "$COLLATE_LOG" \
        "$COLLATE_ALL_LOG"; do

        log_header="Timestamp,Source name,${LOG_HEADERS[$log_file]}"

        # Ensure the log file exists
        if [[ ! -f "$log_file" ]]; then
            print_to_con 'info' \
                "Log file '${log_file}' does not exist. Will create"
            mkdir -p "$(dirname "$log_file")"
            printf "%s\n" "$log_header" > "$log_file"
            continue
        fi

        # Ensure the log file header is correct
        if ! grep -qFx "$log_header" "$log_file"; then
            print_to_con 'info' \
                "Header in log file '${log_file}' is incorrect. Will update"
            sed -i "1s/.*/${log_header}/" "$log_file"
        fi

        # Check for missing fields
        if ! mawk -F ',' '
            # Count the number of fields in the header
            NR == 1 { fields_count = NF; next }
            # Check if the number of fields in the line is the same as the header
            NF != fields_count { exit 1 }
        ' "$log_file"; then
            print_to_con 'warn' "Log file '${log_file}' has missing fields"
        fi
    done
}

# Process each source configured in the sources config file.
# Non-local variables:
#   $SOURCES_CONFIG
#   $SOURCES_ROOT_DIR
process_sources() {
    local source_number=0 source_name source_dir

    # Loop through sources from the sources config file
    while IFS=',' read -r source_original_name source_retrieve_enabled  \
        source_function source_prune_enabled source_rolling_period \
        source_collate_enabled source_include_in_raw; do

        source_number="$(( "$source_number" + 1 ))"

        print_to_con 'start' \
            "(#${source_number}) Processing source '${source_original_name}'"

        # Skip if the source name is empty
        if [[ -z "$source_original_name" ]]; then
            print_to_con 'warn' 'Source name is empty. Skipping'
            continue
        fi

        # Skip if the source name contains non-alphanumeric characters
        if grep -q '[^[:alnum:] ]' <<< "$source_original_name"; then
            print_to_con 'warn' 'Source name can only be alphanumeric'
            continue
        fi

        # Replace whitespaces with underscores and convert to lowercase
        source_name="$(printf "%s" "$source_original_name" \
            | tr ' [:upper:]' '_[:lower:]')"

        source_dir="${SOURCES_ROOT_DIR}/${source_name}"

        # Ensure the source directory exists
        if [[ ! -d "$source_dir" ]]; then
            print_to_con 'info' 'Source directory does not exist. Will create'
            mkdir "$source_dir"
        fi

        print_to_con 'info' "Using directory '${source_dir}'"

        [[ "$RETRIEVE_ENABLED" == true ]] && retrieve_source_results
        [[ "$PRUNE_ENABLED" == true ]] && prune_source_results
        [[ "$COLLATE_ENABLED" == true ]] && collate_source_results

    done <<< "$(tail -n +2 "$SOURCES_CONFIG")"  # Ignores header
}

# TODO: include a way to send notifications for source errors
# Retrieve and save results from the source into a monthly results file.
# Non-local variables:
#   $source_retrieve_enabled
#   $RETRIEVE_SOURCES_SCRIPT
#   $source_function
#   $source_name
#   $source_dir
retrieve_source_results() {
    local function_name='retrieve'

    # Skip if retrieval is disabled
    if [[ "$source_retrieve_enabled" != 'y' ]]; then
        print_to_con 'Disabled. Skipping retrieval'
        return
    fi

    # Skip if $RETRIEVE_SOURCES_SCRIPT does not exist
    if [[ ! -f "$RETRIEVE_SOURCES_SCRIPT" ]]; then
        print_to_con 'warn' \
            "'${RETRIEVE_SOURCES_SCRIPT}' does not exist. Skipping retrieval"
        return
    fi

    # Set the default source function as the source name
    if [[ -z "$source_function" ]]; then
        source_function="$source_name"
        print_to_con "Using function '${source_function}()' by default"
    fi

    # Skip if the function does not exist in $RETRIEVE_SOURCES_SCRIPT
    if ! grep -qFx "${source_function}() {" "$RETRIEVE_SOURCES_SCRIPT"; then
        print_to_con 'warn' \
            "Function '${source_function}()' is not found in '${RETRIEVE_SOURCES_SCRIPT}'. Skipping retrieval"
        return
    fi

    # Install source dependencies
    bash "$RETRIEVE_SOURCES_SCRIPT" 'install_dependencies'

    local execution_time elapsed_time source_processing_time

    execution_time="$(date +%s%3N)"

    # Run the source function to retrieve and save results into
    # source_results.tmp
    bash "$RETRIEVE_SOURCES_SCRIPT" "$source_function"

    elapsed_time="$(( "$(date +%s%3N)" - "$execution_time" ))"
    source_processing_time="$(( "$elapsed_time" / 1000 )).$(( "$elapsed_time" % 1000 ))"

    print_to_con \
        "Function '${source_function}()' completed in ${source_processing_time} seconds"

    # Ensure source_results.tmp exists
    if [[ ! -f source_results.tmp ]]; then
        print_to_con 'warn' \
            "Potential source error: 'source_results.tmp' was not found"
        touch source_results.tmp
    fi

    sort -u source_results.tmp -o source_results.tmp

    local source_results_count
    source_results_count="$(wc -l < source_results.tmp)"

    # Return if no results were retrieved
    if (( "$source_results_count" == 0 )); then
        print_to_con 'warn' \
            'Potential source error: no results retrieved'
        log '0' '0' "${source_function}()" '' "$source_processing_time"
        rm source_results.tmp
        return
    fi

    print_to_con "Retrieved (${source_results_count}) results"

    # Ensure the monthly results file exists
    local source_monthly_file
    source_monthly_file="${source_dir}/${source_name}_$(date +%Y-%m).txt"
    touch "$source_monthly_file"

    local source_new_results_count
    source_new_results_count="$(comm -23 source_results.tmp \
        "$source_monthly_file" | wc -l)"

    # Save the results into the monthly results file
    sort -u source_results.tmp "$source_monthly_file" -o "$source_monthly_file"

    print_to_con \
        "Saved (${source_new_results_count}) new results to '${source_monthly_file##*/}'"

    log "$source_results_count" "$source_new_results_count" \
        "${source_function}()" "$source_monthly_file" "$source_processing_time"

    rm source_results.tmp
}

# Delete results files not within the rolling period.
# Non-local variables:
#   $source_prune_enabled
#   $source_rolling_period
#   $PRUNE_DEFAULT_ROLLING_PERIOD
#   $source_dir
#   $source_name
prune_source_results() {
    local function_name='prune'

    # Skip if pruning is disabled
    if [[ "$source_prune_enabled" != 'y' ]]; then
        print_to_con 'Disabled. Skipping pruning'
        return
    fi

    # If the source rolling period is not configured, use the default
    if [[ -z "$source_rolling_period" ]]; then
        source_rolling_period="$PRUNE_DEFAULT_ROLLING_PERIOD"
        print_to_con \
            "Rolling period set to ${source_rolling_period} month(s) by default"
    fi

    # Skip if the rolling period is not numerical or less than 1
    if [[ ! "$source_rolling_period" =~ ^[0-9]+$ ]] \
        || (( "$source_rolling_period" < 1 )) ; then
        print_to_con 'warn' \
            "Rolling period of '${source_rolling_period}' is invalid. Skipping pruning"
        return
    fi

    local source_cut_off_month
    source_cut_off_month="$(date -d "-${source_rolling_period} months" +%Y-%m)"

    print_to_con \
        "Using rolling period of ${source_rolling_period} month(s). Cut-off month is '${source_cut_off_month}'"

    # Prune results files saved before or in the cut-off month
    local source_pruned_count=0 source_monthly_file source_results_month
    for source_monthly_file in "${source_dir}"/"${source_name}"_????-??.txt; do
        [[ ! -f "$source_monthly_file" ]] && continue

        # Get the saved month of the results file
        source_results_month="${source_monthly_file##*"${source_name}"_}"
        source_results_month="${source_results_month%.txt}"

        # Skip if the results file was saved after the cut-off month
        if [[ "$source_results_month" > "$source_cut_off_month" ]]; then
            continue
        fi

        rm "$source_monthly_file"

        print_to_con "Pruned results file '${source_monthly_file##*/}'"

        log "$source_monthly_file" "$source_rolling_period" \
            "$source_cut_off_month"

        source_pruned_count="$(( "$source_pruned_count" + 1 ))"
    done

    if (( "$source_pruned_count" == 0 )); then
        print_to_con "Pruned (0) results files"
    fi
}

# Collate the source results files.
# Non-local variables:
#   $source_collate_enabled
#   $source_name
#   $source_dir
collate_source_results() {
    local function_name='collate'

    # Skip if collation is disabled
    if [[ "$source_collate_enabled" != 'y' ]]; then
        print_to_con 'Disabled. Skipping collation'
        return
    fi

    # Create the empty source collated results file
    local source_collated_file="${source_dir}/${source_name}.txt"
    : > "$source_collated_file"

    # Collate results files
    local source_collated_count=0 source_monthly_file
    for source_monthly_file in "${source_dir}"/"${source_name}"_*.txt; do
        if [[ ! -f "$source_monthly_file" ]]; then
            log '' '0' "$source_collated_file" '0'
            continue
        fi

        sort -u "$source_monthly_file" "$source_collated_file" \
            -o "$source_collated_file"

        log "$source_monthly_file" "$(wc -l < "$source_monthly_file")" \
            "$source_collated_file" "$(wc -l < "$source_collated_file")"

        source_collated_count="$(( "$source_collated_count" + 1 ))"
    done

    print_to_con "Collated (${source_collated_count}) results files"
    print_to_con \
        "Collated ($(wc -l < "$source_collated_file")) results to '${source_collated_file##*/}'"
}

# Print a message to console.
# Arguments:
#   $1: message type
#   $2: message to print
# Non-local variables:
#   $function_name
print_to_con() {
    local con_message_type="$1"
    local con_message="$2"

    # If there is only one argument, use the caller's $function_name as the
    # message type
    if [[ -z "$2" ]]; then
        con_message_type="$function_name"
        con_message="$1"
    fi

    # Validate the message type and print the message
    case "$con_message_type" in
        start)
            printf "\n[start] %b\n" "$con_message"
            ;;
        info|retrieve|prune|collate)
            printf "[%s] %b\n" "$con_message_type" "$con_message"
            ;;
        warn)
            # Print to stderr
            printf "\e[31m[warn]\e[0m %b\n" "$con_message" >&2
            ;;
        *)
            print_to_con 'warn' \
                "print_to_con(): Message type '${con_message_type}' is not recognized. Message was '${con_message}'"
            ;;
    esac
}

# Log an event into the caller function's log file and keep the log file within
# the maximum number of entries.
# Arguments:
#   $*: event to log (1 argument per field)
# Non-local variables:
#   $LOG_ENABLED
#   $function_name
#   $RETRIEVE_LOG
#   $PRUNE_LOG
#   $COLLATE_LOG
#   $source_original_name
#   $LOG_MAX_ENTRIES
log() {
    [[ "$LOG_ENABLED" != true ]] && return

    local log_file

    # Get the log file of the caller function
    case "$function_name" in
        retrieve) log_file="$RETRIEVE_LOG" ;;
        prune) log_file="$PRUNE_LOG" ;;
        collate) log_file="$COLLATE_LOG" ;;
        *)
            print_to_con 'warn' \
                "log(): Log file of function '${function_name}' is unknown"
            return
            ;;
    esac

    # Log the event
    local IFS=','
    printf "%s,%s,%s\n" "$(date +"%H:%M:%S %d-%m-%y")" "$source_original_name" \
        "${*}" >> "$log_file"

    local log_entries_count
    # -1 to not include the header
    log_entries_count="$(( "$(wc -l < "$log_file")" - 1 ))"

    # Keep the log file within the maximum number of entries
    if (( "$log_entries_count" > "$LOG_MAX_ENTRIES" )); then
        {
            head -n 1 "$log_file"
            tail -n "$LOG_MAX_ENTRIES" "$log_file"
        } > temp
        mv temp "$log_file"
    fi
}

# Entry point

set -e

# TODO
#trap 'rm ./*.tmp 2> /dev/null || true' EXIT

main
