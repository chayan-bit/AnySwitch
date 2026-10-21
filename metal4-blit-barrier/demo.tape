# Demo: copy-encoder barrier names only compute-encoder stages (seedds/nxnative)
# Prebuilt test binaries: /tmp/nxdemo/before (upstream main) and /tmp/nxdemo/after (fix branch)
# Render: nix-shell -p vhs --run 'vhs demo.tape'
Output demo.gif
Set Shell bash
Set FontSize 16
Set Width 1200
Set Height 700
Set Padding 16
Set TypingSpeed 12ms
Set Theme "Dracula"

Hide
Type "export PS1='$ ' && cd /tmp/nxdemo && clear"
Enter
Sleep 500ms
Show

Type 'echo "== fix(gfx): copy-encoder barrier names only compute-encoder stages =="'
Enter
Sleep 1s
Type 'echo "-- BEFORE (upstream main), Metal validation layer on --"'
Enter
Type 'MTL_DEBUG_LAYER=1 ./before/t_reorder_chain > o.log 2>&1; echo "exit=$?"'
Enter
Sleep 4s
Type 'grep -m1 -o "valid combination of MTLStages for the current encoder type" o.log'
Enter
Sleep 2s
Type 'MTL_DEBUG_LAYER=1 ./before/t_rt_range > o.log 2>&1; echo "exit=$?"'
Enter
Sleep 4s
Type 'grep -m1 -o "valid combination of MTLStages for the current encoder type" o.log'
Enter
Sleep 3s

Type 'echo "-- AFTER (this PR): no barrier assertion, the tests run to their summary --"'
Enter
Sleep 1s
Type 'MTL_DEBUG_LAYER=1 ./after/t_reorder_chain > o.log 2>&1; echo "exit=$?"; grep -c MTLStages o.log; tail -n1 o.log'
Enter
Sleep 5s
Type 'MTL_DEBUG_LAYER=1 ./after/t_rt_range > o.log 2>&1; echo "exit=$?"; grep -c MTLStages o.log; tail -n1 o.log'
Enter
Sleep 5s
Type 'echo "(remaining failures are separate test-fixture issues, out of scope)"'
Enter
Sleep 4s
