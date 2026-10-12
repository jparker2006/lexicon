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

test_slots_are_unknown_without_the_slot_files() {
    use_fixture machine-0636
    use_fakes
    run machine.sh
    expect_out "build slots unknown"
}

test_slots_in_use_are_counted() {
    use_fixture machine-0636
    use_fakes
    mkdir -p "$HOME/Library/Application Support/Lexicon Dev/heavy"
    : > "$HOME/Library/Application Support/Lexicon Dev/heavy/slot1"
    : > "$HOME/Library/Application Support/Lexicon Dev/heavy/slot2"
    echo "#153 builder (pid 4100) running scripts/check.sh since 06:30" > "$HOME/Library/Application Support/Lexicon Dev/heavy/slot1.holder"
    echo 75 > "$GH_FIXTURES/cmd/lockf.1.exit"
    : > "$GH_FIXTURES/cmd/lockf.1"
    : > "$GH_FIXTURES/cmd/lockf.2"
    run machine.sh
    expect_out "build slots 1 of 2 in use"
    expect_out "slot 1: #153 builder (pid 4100)"
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
