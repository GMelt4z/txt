#!/usr/bin/env bash

set -u

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BIN="$ROOT_DIR/philo"
LOG_DIR="/tmp/philo_test_logs_$(date +%Y%m%d_%H%M%S)"
SHOW_FULL=0
RUN_TOOLS=0
RUN_HELGRIND=0
SKIP_BUILD=0
TIMEOUT_BIN=""
USE_STDBUF=0
TOTAL_CASES=0
PASSED_CASES=0
FAILED_CASES=0

RED=""
GREEN=""
YELLOW=""
BLUE=""
BOLD=""
RESET=""

if [ -t 1 ]; then
	RED=$'\033[31m'
	GREEN=$'\033[32m'
	YELLOW=$'\033[33m'
	BLUE=$'\033[34m'
	BOLD=$'\033[1m'
	RESET=$'\033[0m'
fi

usage()
{
	cat <<EOF2
Usage: ./test_philo.sh [options]

Options:
  --tools         Run extra valgrind memcheck and drd checks.
  --helgrind      Run extra helgrind checks.
  --show-full     Print full logs instead of head/tail excerpts.
  --skip-build    Reuse the existing ./philo binary.
  --log-dir DIR   Store logs in DIR instead of /tmp.
  --help          Show this help.

Examples:
  ./test_philo.sh
  ./test_philo.sh --tools
  ./test_philo.sh --helgrind
  ./test_philo.sh --tools --helgrind
  ./test_philo.sh --show-full --log-dir ./test_logs
EOF2
}

section()
{
	printf '\n%s== %s ==%s\n' "$BOLD$BLUE" "$1" "$RESET"
}

info()
{
	printf '  %s\n' "$1"
}

ok()
{
	printf '  %s[OK]%s %s\n' "$GREEN" "$RESET" "$1"
}

warn()
{
	printf '  %s[WARN]%s %s\n' "$YELLOW" "$RESET" "$1"
}

ko()
{
	printf '  %s[FAIL]%s %s\n' "$RED" "$RESET" "$1"
}

case_fail()
{
	ko "$1"
	CURRENT_OK=0
}

finish_case()
{
	TOTAL_CASES=$((TOTAL_CASES + 1))
	if [ "$CURRENT_OK" -eq 1 ]; then
		PASSED_CASES=$((PASSED_CASES + 1))
		printf '  %s[PASS]%s %s\n' "$GREEN" "$RESET" "$CURRENT_NAME"
	else
		FAILED_CASES=$((FAILED_CASES + 1))
		printf '  %s[FAIL]%s %s\n' "$RED" "$RESET" "$CURRENT_NAME"
	fi
}

parse_args()
{
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--tools)
				RUN_TOOLS=1
				;;
			--helgrind)
				RUN_HELGRIND=1
				;;
			--show-full)
				SHOW_FULL=1
				;;
			--skip-build)
				SKIP_BUILD=1
				;;
			--log-dir)
				shift
				if [ "$#" -eq 0 ]; then
					printf 'Missing value after --log-dir\n' >&2
					exit 2
				fi
				LOG_DIR="$1"
				;;
			--help)
				usage
				exit 0
				;;
			*)
				printf 'Unknown option: %s\n' "$1" >&2
				usage >&2
				exit 2
				;;
		esac
		shift
	done
}

choose_timeout()
{
	if command -v timeout >/dev/null 2>&1; then
		TIMEOUT_BIN="timeout"
	elif command -v gtimeout >/dev/null 2>&1; then
		TIMEOUT_BIN="gtimeout"
	else
		printf 'timeout or gtimeout is required\n' >&2
		exit 2
	fi
}

require_cmd()
{
	if ! command -v "$1" >/dev/null 2>&1; then
		printf 'Missing required command: %s\n' "$1" >&2
		exit 2
	fi
}

prepare_env()
{
	require_cmd awk
	require_cmd grep
	require_cmd make
	require_cmd sed
	require_cmd tail
	require_cmd wc
	choose_timeout
	if command -v stdbuf >/dev/null 2>&1; then
		USE_STDBUF=1
	fi
	mkdir -p "$LOG_DIR"
}

show_excerpt()
{
	local file
	local lines

	file="$1"
	if [ ! -f "$file" ]; then
		info "No log file was created."
		return
	fi
	lines=$(wc -l < "$file")
	info "Log file: $file"
	info "Log lines: $lines"
	if [ "$lines" -eq 0 ]; then
		info "Log is empty."
		return
	fi
	if [ "$SHOW_FULL" -eq 1 ] || [ "$lines" -le 30 ]; then
		sed -n '1,200p' "$file" | sed 's/^/    | /'
		return
	fi
	info "Log excerpt:"
	sed -n '1,12p' "$file" | sed 's/^/    | /'
	info "..."
	tail -n 12 "$file" | sed 's/^/    | /'
}

run_build()
{
	local build_log
	local noop_log
	local status

	section "Build"
	if [ "$SKIP_BUILD" -eq 1 ]; then
		info "Skipping build because --skip-build was requested."
		if [ ! -x "$BIN" ]; then
			printf './philo is missing or not executable\n' >&2
			exit 2
		fi
		return
	fi
	build_log="$LOG_DIR/build_make_re.log"
	noop_log="$LOG_DIR/build_make.log"
	info "Running: make re"
	(
		cd "$ROOT_DIR" && make re
	) > "$build_log" 2>&1
	status=$?
	show_excerpt "$build_log"
	if [ "$status" -ne 0 ]; then
		printf 'Build failed during make re\n' >&2
		exit 1
	fi
	ok "make re completed successfully"
	info "Running: make"
	(
		cd "$ROOT_DIR" && make
	) > "$noop_log" 2>&1
	status=$?
	show_excerpt "$noop_log"
	if [ "$status" -ne 0 ]; then
		printf 'Build failed during the second make\n' >&2
		exit 1
	fi
	if [ ! -x "$BIN" ]; then
		printf './philo was not produced by the build\n' >&2
		exit 1
	fi
	ok "make completed successfully with the existing binary"
}

begin_case()
{
	CURRENT_NAME="$1"
	CURRENT_OK=1
	section "$1"
	info "$2"
	info "$3"
}

run_philo()
{
	local timeout_s
	local log_file

	timeout_s="$1"
	shift
	log_file="$1"
	shift
	if [ "$USE_STDBUF" -eq 1 ]; then
		"$TIMEOUT_BIN" "${timeout_s}s" stdbuf -oL -eL "$BIN" "$@" > "$log_file" 2>&1
	else
		"$TIMEOUT_BIN" "${timeout_s}s" "$BIN" "$@" > "$log_file" 2>&1
	fi
	CURRENT_STATUS=$?
	info "Exit status: $CURRENT_STATUS"
	show_excerpt "$log_file"
	CURRENT_LOG="$log_file"
}

check_status_eq()
{
	if [ "$CURRENT_STATUS" -eq "$1" ]; then
		ok "$2"
	else
		case_fail "$2 (got $CURRENT_STATUS, expected $1)"
	fi
}

check_status_ne()
{
	if [ "$CURRENT_STATUS" -ne "$1" ]; then
		ok "$2"
	else
		case_fail "$2 (got $CURRENT_STATUS)"
	fi
}

check_log_empty()
{
	if [ ! -s "$CURRENT_LOG" ]; then
		ok "$1"
	else
		case_fail "$1"
	fi
}

check_log_contains()
{
	if grep -q "$1" "$CURRENT_LOG"; then
		ok "$2"
	else
		case_fail "$2"
	fi
}

check_runtime_format()
{
	local bad_line

	if [ ! -s "$CURRENT_LOG" ]; then
		case_fail "runtime log should not be empty"
		return
	fi
	bad_line=$(awk '
		NF == 0 { next }
		$0 !~ /^[0-9]+ [0-9]+ (has taken a fork|is eating|is sleeping|is thinking|died)$/ {
			printf("line %d: %s", NR, $0)
			exit 1
		}
	' "$CURRENT_LOG" 2>/dev/null)
	if [ "$?" -eq 0 ]; then
		ok "all runtime lines match the subject format"
	else
		case_fail "malformed runtime output: $bad_line"
	fi
}

check_timestamp_order()
{
	local report

	report=$(awk '
		NF == 0 { next }
		NR > 1 && $1 < prev {
			printf("line %d timestamp %s is smaller than previous %s", NR, $1, prev)
			exit 1
		}
		{ prev = $1 }
	' "$CURRENT_LOG" 2>/dev/null)
	if [ "$?" -eq 0 ]; then
		ok "timestamps are monotonic"
	else
		case_fail "$report"
	fi
}

check_single_death_and_stop()
{
	local death_count
	local death_line
	local last_line

	death_count=$(grep -Ec '^[0-9]+ [0-9]+ died$' "$CURRENT_LOG")
	if [ "$death_count" -ne 1 ]; then
		case_fail "expected exactly one death line, got $death_count"
		return
	fi
	death_line=$(awk '/^[0-9]+ [0-9]+ died$/ { print NR; exit }' "$CURRENT_LOG")
	last_line=$(awk 'NF { last = NR } END { print last + 0 }' "$CURRENT_LOG")
	if [ "$death_line" -eq "$last_line" ]; then
		ok "death is the final logged event"
	else
		case_fail "there is output after the death line"
	fi
}

check_no_death()
{
	if grep -qE '^[0-9]+ [0-9]+ died$' "$CURRENT_LOG"; then
		case_fail "$1"
	else
		ok "$1"
	fi
}

check_no_eating()
{
	if grep -qE '^[0-9]+ [0-9]+ is eating$' "$CURRENT_LOG"; then
		case_fail "$1"
	else
		ok "$1"
	fi
}

check_min_meals()
{
	local num_philos
	local min_meals
	local summary

	num_philos="$1"
	min_meals="$2"
	summary=$(awk -v n="$num_philos" -v min="$min_meals" '
		/^[0-9]+ [0-9]+ is eating$/ { count[$2]++ }
		END {
			ok = 1
			for (i = 1; i <= n; i++) {
				c = count[i] + 0
				printf("%d:%d%s", i, c, (i < n ? " " : ""))
				if (c < min)
					ok = 0
			}
			printf("\n")
			exit(ok ? 0 : 1)
		}
	' "$CURRENT_LOG")
	if [ "$?" -eq 0 ]; then
		ok "every philosopher ate at least $min_meals times ($summary)"
	else
		case_fail "not every philosopher reached $min_meals meals ($summary)"
	fi
}

check_death_delay()
{
	local time_to_die
	local report
	local status

	time_to_die="$1"
	report=$(awk -v ttd="$time_to_die" '
		/^[0-9]+ [0-9]+ is eating$/ {
			last_eat[$2] = $1
		}
		/^[0-9]+ [0-9]+ died$/ {
			found = 1
			pid = $2
			death = $1
			if (pid in last_eat)
				expected = last_eat[pid] + ttd
			else
				expected = ttd
			delay = death - expected
			printf("philo=%s death=%s expected=%s delay=%s", pid, death, expected, delay)
			if (delay < 0 || delay > 10)
				exit 1
			exit 0
		}
		END {
			if (!found)
				exit 2
		}
	' "$CURRENT_LOG")
	status=$?
	if [ "$status" -eq 0 ]; then
		ok "death delay is within 10 ms ($report)"
	elif [ "$status" -eq 2 ]; then
		case_fail "could not find a death line for the delay check"
	else
		case_fail "death delay is out of range ($report)"
	fi
}

run_invalid_input_case()
{
	local name
	local desc
	local timeout_s
	local log_file

	name="$1"
	desc="$2"
	timeout_s="$3"
	shift 3
	log_file="$LOG_DIR/${name}.log"
	begin_case "$name" "$desc" "Command: $BIN $*"
	run_philo "$timeout_s" "$log_file" "$@"
	check_status_ne 0 "invalid input should return a non-zero status"
	check_log_contains 'Error' "invalid input should print Error"
	finish_case
}

run_clean_exit_case()
{
	local name
	local desc
	local timeout_s
	local log_file

	name="$1"
	desc="$2"
	timeout_s="$3"
	shift 3
	log_file="$LOG_DIR/${name}.log"
	begin_case "$name" "$desc" "Command: $BIN $*"
	run_philo "$timeout_s" "$log_file" "$@"
	check_status_eq 0 "the program should exit cleanly"
	check_log_empty "the program should not print anything"
	finish_case
}

run_death_case()
{
	local name
	local desc
	local timeout_s
	local must_not_eat
	local death_delay
	local log_file

	name="$1"
	desc="$2"
	timeout_s="$3"
	must_not_eat="$4"
	death_delay="$5"
	shift 5
	log_file="$LOG_DIR/${name}.log"
	begin_case "$name" "$desc" "Command: $BIN $*"
	run_philo "$timeout_s" "$log_file" "$@"
	check_status_eq 0 "the simulation should stop before the timeout"
	check_runtime_format
	check_timestamp_order
	check_single_death_and_stop
	if [ "$must_not_eat" -eq 1 ]; then
		check_no_eating "the single philosopher must never eat"
	fi
	if [ "$death_delay" -gt 0 ]; then
		check_death_delay "$death_delay"
	fi
	finish_case
}

run_no_death_case()
{
	local name
	local desc
	local timeout_s
	local log_file

	name="$1"
	desc="$2"
	timeout_s="$3"
	shift 3
	log_file="$LOG_DIR/${name}.log"
	begin_case "$name" "$desc" "Command: $BIN $*"
	run_philo "$timeout_s" "$log_file" "$@"
	check_status_eq 124 "the test should still be running at the timeout"
	check_runtime_format
	check_timestamp_order
	check_no_death "no philosopher should die during this window"
	finish_case
}

run_meal_limit_case()
{
	local name
	local desc
	local timeout_s
	local num_philos
	local must_eat
	local log_file

	name="$1"
	desc="$2"
	timeout_s="$3"
	num_philos="$4"
	must_eat="$5"
	shift 5
	log_file="$LOG_DIR/${name}.log"
	begin_case "$name" "$desc" "Command: $BIN $*"
	run_philo "$timeout_s" "$log_file" "$@"
	check_status_eq 0 "the simulation should stop on its own"
	check_runtime_format
	check_timestamp_order
	check_no_death "no philosopher should die before the meal target is reached"
	check_min_meals "$num_philos" "$must_eat"
	finish_case
}

run_tool_case()
{
	local name
	local desc
	local log_file
	local status

	name="$1"
	desc="$2"
	shift 2
	log_file="$LOG_DIR/${name}.log"
	CURRENT_NAME="$name"
	CURRENT_OK=1
	section "$name"
	info "$desc"
	info "Command: $*"
	"$@" > "$log_file" 2>&1
	status=$?
	CURRENT_STATUS=$status
	info "Exit status: $CURRENT_STATUS"
	show_excerpt "$log_file"
	CURRENT_LOG="$log_file"
	check_status_eq 0 "tool run should finish without reporting errors"
	check_log_contains 'ERROR SUMMARY: 0' "tool should report zero errors"
	finish_case
}

run_main_suite()
{
	section "Main Suite"
	run_invalid_input_case \
		"parser_non_numeric" \
		"Reject malformed numeric input." \
		1 \
		++1 200 60 60
	run_invalid_input_case \
		"parser_zero_philos" \
		"Reject a zero philosopher count." \
		1 \
		0 800 200 200
	run_invalid_input_case \
		"parser_missing_argument" \
		"Reject an incomplete argument list." \
		1 \
		5 800 200
	run_clean_exit_case \
		"must_eat_zero" \
		"A must_eat value of 0 should exit immediately without logs." \
		1 \
		1 200 60 60 0
	run_death_case \
		"single_philo_death" \
		"Evaluation case: 1 800 200 200 must die without eating." \
		2 \
		1 \
		800 \
		1 800 200 200
	run_no_death_case \
		"eval_5_800_200_200" \
		"Evaluation case: 5 800 200 200 should keep running with no death." \
		4 \
		5 800 200 200
	run_meal_limit_case \
		"eval_5_800_200_200_7" \
		"Evaluation case: 5 800 200 200 7 should stop cleanly after 7 meals each." \
		8 \
		5 \
		7 \
		5 800 200 200 7
	run_no_death_case \
		"eval_4_410_200_200" \
		"Evaluation case: 4 410 200 200 should keep running with no death." \
		4 \
		4 410 200 200
	run_death_case \
		"eval_4_310_200_100" \
		"Evaluation case: 4 310 200 100 should stop on one death." \
		3 \
		0 \
		310 \
		4 310 200 100
	run_death_case \
		"eval_2_310_200_100" \
		"Two philosophers: death timing must not be delayed by more than 10 ms." \
		3 \
		0 \
		310 \
		2 310 200 100
}

run_tool_suite()
{
	section "Tool Suite"
	if ! command -v valgrind >/dev/null 2>&1; then
		warn "valgrind is not installed; skipping the memcheck/drd suite"
		return
	fi
	run_tool_case \
		"valgrind_memcheck_single" \
		"Memcheck on the one-philosopher death case." \
		"$TIMEOUT_BIN" 15s valgrind --leak-check=full \
		--show-leak-kinds=all --errors-for-leak-kinds=all \
		--error-exitcode=42 "$BIN" 1 800 200 200
	run_tool_case \
		"valgrind_drd_death_case" \
		"DRD on a deterministic death case." \
		"$TIMEOUT_BIN" 20s valgrind --tool=drd --error-exitcode=42 \
		"$BIN" 4 310 200 100
}

run_helgrind_suite()
{
	section "Helgrind Suite"
	if ! command -v valgrind >/dev/null 2>&1; then
		warn "valgrind is not installed; skipping the helgrind suite"
		return
	fi
	warn "helgrind is slower and may report tool-side internal errors on some systems"
	run_tool_case \
		"helgrind_single_death" \
		"Helgrind on the one-philosopher death case." \
		"$TIMEOUT_BIN" 20s valgrind --tool=helgrind --error-exitcode=42 \
		"$BIN" 1 800 200 200
	run_tool_case \
		"helgrind_even_death_case" \
		"Helgrind on a deterministic multi-philosopher death case." \
		"$TIMEOUT_BIN" 25s valgrind --tool=helgrind --error-exitcode=42 \
		"$BIN" 4 310 200 100
	run_tool_case \
		"helgrind_meal_limit_case" \
		"Helgrind on a clean meal-limit completion case." \
		"$TIMEOUT_BIN" 30s valgrind --tool=helgrind --error-exitcode=42 \
		"$BIN" 4 500 200 200 2
}

print_manual_review()
{
	section "Manual Review Items"
	info "The script cannot prove the code-review items below. Check them manually in the evaluator flow:"
	info "- no global variables managing shared state"
	info "- exactly one thread per philosopher"
	info "- exactly one fork and one mutex per fork"
	info "- the mutex strategy really prevents fork stealing and data races"
	info "- the source still passes norminette on your target machine"
}

print_summary()
{
	section "Summary"
	info "Passed: $PASSED_CASES"
	info "Failed: $FAILED_CASES"
	info "Total:  $TOTAL_CASES"
	info "Logs:   $LOG_DIR"
	if [ "$FAILED_CASES" -ne 0 ]; then
		exit 1
	fi
}

main()
{
	parse_args "$@"
	prepare_env
	run_build
	run_main_suite
	if [ "$RUN_TOOLS" -eq 1 ]; then
		run_tool_suite
	fi
	if [ "$RUN_HELGRIND" -eq 1 ]; then
		run_helgrind_suite
	fi
	print_manual_review
	print_summary
}

main "$@"
