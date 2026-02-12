`timescale 1ns/1ps

module buffer_tb;

    // ─────────────────────────────────────────────────────────────
    //  Parameters — match the DUT
    // ─────────────────────────────────────────────────────────────
    parameter int DEPTH        = 16;
    parameter int WIDTH        = 32;
    parameter int ADDR_W       = $clog2(DEPTH);

    parameter real RE_CLK_PERIOD = 10.0;   // 100 MHz write/receiver clock
    parameter real TE_CLK_PERIOD = 15.0;   //  66 MHz read/transmitter clock

    // ─────────────────────────────────────────────────────────────
    //  DUT signals
    // ─────────────────────────────────────────────────────────────
    logic             re_clk;
    logic             re_reset_n;
    logic             re_valid;
    logic [WIDTH-1:0] data_in;
    logic             re_credit_pulse;     // one pulse per freed slot

    logic             te_clk;
    logic             te_reset_n;
    logic             te_ready;
    logic             te_valid;
    logic [WIDTH-1:0] te_data_out;

    // ─────────────────────────────────────────────────────────────
    //  Source-side credit counter — lives here, not inside DUT
    // ─────────────────────────────────────────────────────────────
    logic [ADDR_W:0] src_credit;

    always_ff @(posedge re_clk or negedge re_reset_n) begin
        if (!re_reset_n)
            src_credit <= DEPTH;                           // full credits at reset
        else unique case ({re_valid, re_credit_pulse})
            2'b10:   src_credit <= src_credit - 1'b1;     // sent a flit
            2'b01:   src_credit <= src_credit + 1'b1;     // got one back
            default: src_credit <= src_credit;
        endcase
    end

    // ─────────────────────────────────────────────────────────────
    //  Scoreboard — track expected data order
    // ─────────────────────────────────────────────────────────────
    logic [WIDTH-1:0] scoreboard[$];
    int               total_writes  = 0;
    int               total_reads   = 0;
    int               error_count   = 0;

    // watch every write commit in re_clk domain
    always @(posedge re_clk) begin
        if (re_reset_n && re_valid) begin
            scoreboard.push_back(data_in);
            total_writes++;
        end
    end

    // check every read output in te_clk domain
    always @(posedge te_clk) begin
        if (te_reset_n && te_valid) begin
            logic [WIDTH-1:0] expected;
            total_reads++;
            if (scoreboard.size() == 0) begin
                $error("[SCOREBOARD] t=%0t  spurious read! got 0x%08h, queue empty",
                       $time, te_data_out);
                error_count++;
            end else begin
                expected = scoreboard.pop_front();
                if (te_data_out !== expected) begin
                    $error("[SCOREBOARD] t=%0t  MISMATCH  expected=0x%08h  got=0x%08h",
                           $time, expected, te_data_out);
                    error_count++;
                end
            end
        end
    end

    // ─────────────────────────────────────────────────────────────
    //  Credit-pulse monitor — watch for unexpected over-return
    // ─────────────────────────────────────────────────────────────
    always @(posedge re_clk) begin
        if (re_reset_n && re_credit_pulse) begin
            if (src_credit == DEPTH) begin
                $error("[CREDIT] t=%0t  credit returned but already at max (%0d)!",
                       $time, DEPTH);
                error_count++;
            end
        end
    end

    // ─────────────────────────────────────────────────────────────
    //  DUT instantiation
    // ─────────────────────────────────────────────────────────────
    buffer #(
        .DEPTH (DEPTH),
        .WIDTH (WIDTH)
    ) dut (
        .re_clk          (re_clk),
        .re_reset_n      (re_reset_n),
        .re_valid        (re_valid),
        .data_in         (data_in),
        .re_credit_pulse (re_credit_pulse),
        .te_clk          (te_clk),
        .te_reset_n      (te_reset_n),
        .te_ready        (te_ready),
        .te_valid        (te_valid),
        .te_data_out     (te_data_out)
    );

    // ─────────────────────────────────────────────────────────────
    //  Clocks
    // ─────────────────────────────────────────────────────────────
    initial re_clk = 0;
    always  #(RE_CLK_PERIOD/2.0) re_clk = ~re_clk;

    initial te_clk = 0;
    always  #(TE_CLK_PERIOD/2.0) te_clk = ~te_clk;

    // ─────────────────────────────────────────────────────────────
    //  Tasks
    // ─────────────────────────────────────────────────────────────

    // full reset — both domains asserted then released in sequence
    task automatic do_reset();
        re_valid   = 0;
        te_ready   = 0;
        data_in    = '0;
        re_reset_n = 0;
        te_reset_n = 0;
        repeat(6) @(posedge re_clk);
        @(posedge re_clk); re_reset_n = 1;
        repeat(6) @(posedge te_clk);
        @(posedge te_clk); te_reset_n = 1;
        repeat(4) @(posedge re_clk);
        $display("[RESET] complete  credits=%0d  t=%0t", src_credit, $time);
    endtask

    // write a single word — only fires if a credit is available
    task automatic write_one(input logic [WIDTH-1:0] d);
        if (src_credit == 0) begin
            // wait for a credit to come back before sending
            @(posedge re_clk iff (src_credit > 0 || re_credit_pulse));
        end
        @(posedge re_clk);
        re_valid = 1;
        data_in  = d;
        @(posedge re_clk);
        re_valid = 0;
    endtask

    // write N words with optional idle gaps between them
    task automatic write_n(int n, bit gaps = 0);
        logic [WIDTH-1:0] d;
        for (int i = 0; i < n; i++) begin
            d = $urandom;
            write_one(d);
            if (gaps && ($urandom_range(0,3) == 0))
                repeat($urandom_range(1,3)) @(posedge re_clk);
        end
    endtask

    // drain the read side for a given number of te_clk cycles
    task automatic drain(int te_cycles);
        te_ready = 1;
        repeat(te_cycles) @(posedge te_clk);
        te_ready = 0;
    endtask

    // wait until scoreboard is empty or timeout
    task automatic wait_scoreboard_empty(int timeout_re_cycles = 500);
        int t = 0;
        while (scoreboard.size() > 0 && t < timeout_re_cycles) begin
            @(posedge re_clk);
            t++;
        end
        if (scoreboard.size() != 0)
            $warning("[WAIT] scoreboard not empty after %0d cycles (%0d items left)",
                     timeout_re_cycles, scoreboard.size());
    endtask

    // ─────────────────────────────────────────────────────────────
    //  TEST 1 — basic single write then read
    //  Verifies the simplest path: one word in, one word out.
    // ─────────────────────────────────────────────────────────────
    task automatic test_single_word();
        $display("\n[TEST 1] Single word write and read");
        write_one(32'hDEAD_BEEF);
        drain(40);
        wait_scoreboard_empty();
        $display("[TEST 1] credits after drain = %0d  (expect %0d)", src_credit, DEPTH);
    endtask

    // ─────────────────────────────────────────────────────────────
    //  TEST 2 — fill the buffer completely, then drain
    //  Verifies credit counter reaches zero and no overflow occurs.
    // ─────────────────────────────────────────────────────────────
    task automatic test_fill_and_drain();
        $display("\n[TEST 2] Fill buffer to capacity then drain");
        $display("         writing %0d words, credits start at %0d", DEPTH, src_credit);
        write_n(DEPTH);
        repeat(4) @(posedge re_clk);
        $display("         credits after fill = %0d  (expect 0)", src_credit);
        if (src_credit !== 0)
            $error("[TEST 2] expected 0 credits after full fill, got %0d", src_credit);
        drain(200);
        wait_scoreboard_empty();
        repeat(20) @(posedge re_clk);
        $display("         credits after drain = %0d  (expect %0d)", src_credit, DEPTH);
        if (src_credit !== DEPTH)
            $error("[TEST 2] expected full credits after drain, got %0d", src_credit);
    endtask

    // ─────────────────────────────────────────────────────────────
    //  TEST 3 — write beyond depth while draining simultaneously
    //  Confirms credit-return CDC keeps the counter consistent when
    //  both sides are active at the same time.
    // ─────────────────────────────────────────────────────────────
    task automatic test_concurrent_rw();
        $display("\n[TEST 3] Concurrent read and write (50 words)");
        fork
            write_n(50, 1);                 // write side with random gaps
            begin
                #300;                       // slight head start for writer
                drain(2000);                // read side keeps up
            end
        join
        wait_scoreboard_empty(800);
        repeat(20) @(posedge re_clk);
        $display("         credits after concurrent test = %0d", src_credit);
    endtask

    // ─────────────────────────────────────────────────────────────
    //  TEST 4 — credit return CDC latency check
    //  Fills buffer, then measures how many re_clk cycles pass
    //  before the first credit pulse returns after a read fires.
    // ─────────────────────────────────────────────────────────────
    task automatic test_credit_return_latency();
        int   cycle_count;
        logic got_pulse;

        $display("\n[TEST 4] Credit return CDC latency measurement");

        // fill up so credit count hits zero
        write_n(DEPTH);
        repeat(4) @(posedge re_clk);
        $display("         buffer full, credits = %0d, starting one read", src_credit);

        // trigger exactly one read
        te_ready = 1;
        @(posedge te_clk);
        @(posedge te_clk);
        te_ready = 0;

        // count re_clk cycles until re_credit_pulse lands
        cycle_count = 0;
        got_pulse   = 0;
        repeat(30) begin
            @(posedge re_clk);
            cycle_count++;
            if (re_credit_pulse && !got_pulse) begin
                got_pulse = 1;
                $display("         credit pulse received after %0d re_clk cycles", cycle_count);
                $display("         (expected ~3-5 cycles: 1 toggle FF + 2 sync + 1 edge detect)");
            end
        end

        if (!got_pulse)
            $error("[TEST 4] no credit pulse received within 30 re_clk cycles!");

        drain(100);
        wait_scoreboard_empty();
    endtask

    // ─────────────────────────────────────────────────────────────
    //  TEST 5 — pointer wraparound
    //  Writes and reads in alternating bursts so wr_ptr and rd_ptr
    //  both wrap around zero multiple times.
    // ─────────────────────────────────────────────────────────────
    task automatic test_wraparound();
        $display("\n[TEST 5] Pointer wraparound (3 full laps)");
        for (int lap = 0; lap < 3; lap++) begin
            write_n(DEPTH);
            drain(300);
            wait_scoreboard_empty(400);
            repeat(10) @(posedge re_clk);
            $display("         lap %0d done  wr_ptr=%0d  rd_ptr=%0d  credits=%0d",
                     lap+1, dut.wr_ptr, dut.rd_ptr, src_credit);
        end
    endtask

    // ─────────────────────────────────────────────────────────────
    //  TEST 6 — back-pressure: reader stalls mid-burst
    //  Writer fills the buffer, reader starts then suddenly stalls.
    //  Verifies te_valid deasserts correctly and no data is lost.
    // ─────────────────────────────────────────────────────────────
    task automatic test_backpressure();
        $display("\n[TEST 6] Back-pressure from reader");
        write_n(DEPTH);
        repeat(4) @(posedge re_clk);

        // read 4 words, then stall
        te_ready = 1;
        repeat(4) @(posedge te_clk);
        te_ready = 0;
        $display("         stalled after 4 reads, te_valid should deassert");
        repeat(20) @(posedge te_clk);

        // resume and drain the rest
        $display("         resuming read");
        drain(300);
        wait_scoreboard_empty();
        repeat(10) @(posedge re_clk);
        $display("         credits after backpressure test = %0d", src_credit);
    endtask

    // ─────────────────────────────────────────────────────────────
    //  TEST 7 — credit-gated write: source tries to send when
    //  credits = 0 and must wait. Verifies no lost or duplicate data.
    // ─────────────────────────────────────────────────────────────
    task automatic test_credit_gating();
        logic [WIDTH-1:0] extra_word;
        $display("\n[TEST 7] Credit-gated write (source blocks when credits = 0)");

        // fill completely
        write_n(DEPTH);
        repeat(4) @(posedge re_clk);
        $display("         buffer full, credits = %0d", src_credit);

        // try to send one more word — write_one will wait for a credit
        extra_word = 32'hCAFE_F00D;
        fork
            begin
                $display("         attempting write with 0 credits — should block");
                write_one(extra_word);
                $display("         write completed after credit returned");
            end
            begin
                // release one slot after a short delay
                #200;
                te_ready = 1;
                repeat(2) @(posedge te_clk);
                te_ready = 0;
            end
        join

        drain(200);
        wait_scoreboard_empty();
        $display("         credits after test = %0d", src_credit);
    endtask

    // ─────────────────────────────────────────────────────────────
    //  Main sequence
    // ─────────────────────────────────────────────────────────────
    initial begin
        $dumpfile("buffer_tb.vcd");
        $dumpvars(0, buffer_tb);

        $display("╔══════════════════════════════════════════════════════════╗");
        $display("║   buffer.sv — Source-Controlled Credit Interface TB      ║");
        $display("╚══════════════════════════════════════════════════════════╝");
        $display("  DEPTH=%0d  WIDTH=%0d  re_clk=%.0fMHz  te_clk=%.0fMHz",
                 DEPTH, WIDTH, 1000.0/RE_CLK_PERIOD, 1000.0/TE_CLK_PERIOD);

        do_reset();  test_single_word();
        do_reset();  test_fill_and_drain();
        do_reset();  test_concurrent_rw();
        do_reset();  test_credit_return_latency();
        do_reset();  test_wraparound();
        do_reset();  test_backpressure();
        do_reset();  test_credit_gating();

        // final drain to flush anything left over
        drain(300);
        wait_scoreboard_empty(500);

        $display("\n╔══════════════════════════════════════════════════════════╗");
        $display("║                     SUMMARY                              ║");
        $display("╚══════════════════════════════════════════════════════════╝");
        $display("  Total writes : %0d", total_writes);
        $display("  Total reads  : %0d", total_reads);
        $display("  Errors       : %0d", error_count);
        $display("  Queue leftover: %0d", scoreboard.size());
        $display("  Final credits : %0d / %0d", src_credit, DEPTH);

        if (error_count == 0 && scoreboard.size() == 0 && src_credit == DEPTH)
            $display("\n  ✓  ALL TESTS PASSED\n");
        else
            $display("\n  ✗  FAILURES DETECTED — see errors above\n");

        $finish;
    end

endmodule