# scripts/machine.sh on the 06:36 readings (#42, #47).

test_load_of_13_on_10_cores_says_no() {
    use_fixture machine-0636
    use_fakes
    run machine.sh
    expect_status 0
    expect_out "room for more builders: no (load 13.07 over 5 min on 10 cores)"
}

test_low_power_mode_is_named() {
    use_fixture machine-0636
    use_fakes
    run machine.sh
    expect_out "Low Power Mode on"
    expect_out "warning: Low Power Mode is on"
}

test_top_processes_leave_out_lexicons_own_builds() {
    use_fixture machine-0636
    use_fakes
    run machine.sh --interval 3
    expect_out "top other processes: fseventsd 97%, Python 96%"
    expect_no_out "swift-frontend"
    expect_no_out "Lexicon"
}

test_no_slot_files_means_no_slot_in_use() {
    use_fixture machine-0636
    use_fakes
    run machine.sh
    expect_out "build slots 0 of 3 in use | queue: 0 waiting"
}

test_an_unreadable_reading_says_no() {
    use_fixture machine-0636
    use_fakes
    printf '10\n{ 1.00 1.00 1.00 }\n' > "$GH_FIXTURES/cmd/sysctl"
    echo "memory_pressure: no reading" > "$GH_FIXTURES/cmd/memory_pressure"
    run machine.sh
    expect_out "room for more builders: no (memory reading unknown)"
    use_fixture machine-0636
    printf '\n' > "$GH_FIXTURES/cmd/sysctl"
    echo "memory_pressure: no reading" > "$GH_FIXTURES/cmd/memory_pressure"
    run machine.sh
    expect_out "room for more builders: no (load reading unknown; memory reading unknown)"
}

test_a_load_just_under_1_per_core_says_yes() {
    use_fixture machine-0636
    use_fakes
    printf '10\n{ 9.96 9.96 9.96 }\n' > "$GH_FIXTURES/cmd/sysctl"
    run machine.sh
    expect_out "room for more builders: yes"
}

test_paging_out_50_a_second_says_no() {
    use_fixture machine-0636
    use_fakes
    printf '10\n{ 1.00 1.00 1.00 }\n' > "$GH_FIXTURES/cmd/sysctl"
    echo "Pageouts:                                   16559845." > "$GH_FIXTURES/cmd/vm_stat.2"
    run machine.sh --interval 3
    expect_out "room for more builders: no (paging out 50 pages/s)"
}

test_under_15_percent_memory_free_says_no() {
    use_fixture machine-0636
    use_fakes
    printf '10\n{ 1.00 1.00 1.00 }\n' > "$GH_FIXTURES/cmd/sysctl"
    echo "System-wide memory free percentage: 14%" > "$GH_FIXTURES/cmd/memory_pressure"
    run machine.sh
    expect_out "room for more builders: no (memory 14% free)"
}

test_an_unreadable_page_out_count_says_no() {
    use_fixture machine-0636
    use_fakes
    printf '10\n{ 1.00 1.00 1.00 }\n' > "$GH_FIXTURES/cmd/sysctl"
    echo "vm_stat: no reading" > "$GH_FIXTURES/cmd/vm_stat.2"
    run machine.sh
    expect_out "room for more builders: no (page-out reading unknown)"
}

test_slots_in_use_are_counted() {
    use_fixture machine-0636
    use_fakes
    mkdir -p "$HOME/Library/Application Support/Lexicon Dev/heavy"
    : > "$HOME/Library/Application Support/Lexicon Dev/heavy/slot1"
    : > "$HOME/Library/Application Support/Lexicon Dev/heavy/slot2"
    : > "$HOME/Library/Application Support/Lexicon Dev/heavy/slot3"
    echo "#153 builder (pid 4100) running scripts/check.sh since 06:30" > "$HOME/Library/Application Support/Lexicon Dev/heavy/slot1.holder"
    echo 75 > "$GH_FIXTURES/cmd/lockf.1.exit"
    : > "$GH_FIXTURES/cmd/lockf.1"
    : > "$GH_FIXTURES/cmd/lockf.2"
    : > "$GH_FIXTURES/cmd/lockf.3"
    # The fourth call checks slot 1 again before naming its holder.
    echo 75 > "$GH_FIXTURES/cmd/lockf.4.exit"
    : > "$GH_FIXTURES/cmd/lockf.4"
    run machine.sh
    expect_out "build slots 1 of 3 in use | queue: 0 waiting"
    expect_out "slot 1: #153 builder (pid 4100)"
    # Without -k, lockf deletes the file it locked: the probe would remove the slot.
    expect_log "lockf -k -s -n -t 0 $HOME/Library/Application Support/Lexicon Dev/heavy/slot1 true"
}

test_waiters_in_line_are_counted() {
    use_fixture machine-0636
    use_fakes
    queue="$HOME/Library/Application Support/Lexicon Dev/heavy/queue"
    mkdir -p "$queue"
    # A live waiter, one whose process is gone, and one whose pid now names a
    # process that started after it queued. The fake ps says every process is
    # running and started on 1 January 2026.
    echo "S    Thu Jan  1 00:00:00 2026" > "$GH_FIXTURES/cmd/ps"
    : > "$queue/0000000001.$$"
    sh -c 'exit 0' & dead=$!
    wait "$dead"
    : > "$queue/0000000002.$dead"
    : > "$queue/0000000003.$PPID"
    touch -t 202001010000 "$queue/0000000003.$PPID"
    : > "$GH_FIXTURES/cmd/lockf"
    run machine.sh
    expect_out "build slots 0 of 3 in use | queue: 1 waiting"
}

test_a_quiet_mac_says_yes() {
    use_fixture machine-0636
    use_fakes
    printf '10\n{ 4.90 4.10 3.80 }\n' > "$GH_FIXTURES/cmd/sysctl"
    printf ' lowpowermode         0\n' > "$GH_FIXTURES/cmd/pmset"
    run machine.sh
    expect_out "room for more builders: yes"
    expect_no_out "warning"
}
