// tb_async_fifo_credit.sv
// Self-checking testbench for async_fifo_credit
//
// Scenarios
//   1. wr faster  (wr=10ns  rd=25ns)
//   2. rd faster  (wr=25ns  rd=14ns)  within f_rd/f_wr < 2 constraint
//   3. equal      (wr=15ns  rd=15ns)
//   4. back-pressure (equal clocks, rd_ready toggled randomly)
//   5. async ratio (wr=7ns  rd=11ns)
//   6. fill-to-full then drain
//
// Scoreboard  : queue of written words; each read pops and compares
// Credit check: credit_pulse count must equal write-accepted count at end

`timescale 1ns/1ps

module tb_async_fifo_credit;

    // DUT parameters
    localparam int DW    = 32;
    localparam int DEPTH = 16;

    // clocks and resets
    logic wr_clk, rd_clk;
    logic wr_rst_n, rd_rst_n;

    // DUT ports
    logic          wr_valid;
    logic [DW-1:0] wr_data;
    logic          wr_credit_pulse;
    logic          rd_valid;
    logic          rd_ready;
    logic [DW-1:0] rd_data;

    // DUT
    async_fifo_credit #(
        .DEPTH  (DEPTH),
        .DATA_W (DW)
    ) dut (
        .wr_clk          (wr_clk),
        .wr_rst_n        (wr_rst_n),
        .wr_valid        (wr_valid),
        .wr_data         (wr_data),
        .wr_credit_pulse (wr_credit_pulse),
        .rd_clk          (rd_clk),
        .rd_rst_n        (rd_rst_n),
        .rd_valid        (rd_valid),
        .rd_ready        (rd_ready),
        .rd_data         (rd_data)
    );

    // Scoreboard and counters
    logic [DW-1:0] scoreboard [$];   // expected data queue
    int            wr_count;         // words accepted by DUT
    int            credit_count;     // wr_credit_pulse count

    // Clock period knobs (set per scenario)
    realtime WR_HALF, RD_HALF;

    // Clocks
    initial wr_clk = 0;
    always #(WR_HALF) wr_clk = ~wr_clk;

    initial rd_clk = 0;
    always #(RD_HALF) rd_clk = ~rd_clk;

    // Credit counter (wr_clk domain)
    always_ff @(posedge wr_clk)
        if (!wr_rst_n) credit_count <= 0;
        else if (wr_credit_pulse) credit_count <= credit_count + 1;

    // Scoreboard checker (rd_clk domain)
    always_ff @(posedge rd_clk) begin
        if (rd_valid && rd_ready) begin
            logic [DW-1:0] expected;
            if (scoreboard.size() == 0)
                $error("[UNDERFLOW] read when scoreboard empty at %0t", $time);
            else begin
                expected = scoreboard.pop_front();
                if (rd_data !== expected)
                    $error("[DATA MISMATCH] got 0x%08h expected 0x%08h at %0t",
                           rd_data, expected, $time);
            end
        end
    end


    // Task: reset both domains
    task do_reset();
        wr_rst_n = 0; rd_rst_n = 0;
        wr_valid = 0; wr_data  = 0;
        rd_ready = 0;
        wr_count = 0; credit_count = 0;
        scoreboard.delete();
        repeat (4) @(posedge wr_clk);
        repeat (4) @(posedge rd_clk);
        @(posedge wr_clk); wr_rst_n = 1;
        @(posedge rd_clk); rd_rst_n = 1;
        repeat (2) @(posedge wr_clk);
        repeat (2) @(posedge rd_clk);
    endtask

    // Task: write n words, one per wr_clk, stall on full
    task write_words(int n);
        for (int i = 0; i < n; i++) begin
            @(posedge wr_clk);
            while (dut.wr_full) @(posedge wr_clk);
            wr_valid = 1;
            wr_data  = $urandom();
            @(posedge wr_clk);
            scoreboard.push_back(wr_data);
            wr_count++;
            wr_valid = 0;
        end
    endtask

    // Task: read n words, rd_ready always asserted
    task read_words(int n);
        rd_ready = 1;
        for (int i = 0; i < n; i++) begin
            @(posedge rd_clk);
            while (!rd_valid) @(posedge rd_clk);
        end
        @(posedge rd_clk);
        rd_ready = 0;
    endtask

    // Task: read n words with random back-pressure
    task read_words_bp(int n);
        int done = 0;
        while (done < n) begin
            @(posedge rd_clk);
            rd_ready = $urandom_range(0, 1);
            if (rd_valid && rd_ready) done++;
        end
        @(posedge rd_clk);
        rd_ready = 0;
    endtask

    // Task: assert rd_ready until scoreboard is empty, then flush CDC pipeline
    task drain();
        rd_ready = 1;
        while (scoreboard.size() > 0) @(posedge rd_clk);
        repeat (10) @(posedge rd_clk);
        rd_ready = 0;
    endtask

    // Task: wait for credit pipeline to flush then check count
    task check_credits(string scenario);
        repeat (20) @(posedge wr_clk);
        if (credit_count !== wr_count)
            $error("[%s] CREDIT MISMATCH: %0d pulses, %0d writes",
                   scenario, credit_count, wr_count);
        else
            $display("[%s] PASS  credits=%0d  writes=%0d", scenario, credit_count, wr_count);
    endtask

    // Task: check scoreboard is empty
    task check_sb(string scenario);
        if (scoreboard.size() != 0)
            $error("[%s] LEFTOVER: %0d entries in scoreboard", scenario, scoreboard.size());
        else
            $display("[%s] PASS  scoreboard empty", scenario);
    endtask


    // MAIN TEST
    initial begin
        $dumpfile("tb_async_fifo_credit.vcd");
        $dumpvars(0, tb_async_fifo_credit);


        // ── 1. wr faster ──────────────────────────────────────────────────
        WR_HALF = 5.0; RD_HALF = 12.5;  // wr=10ns  rd=25ns
        $display("\n--- 1. wr faster (wr=10ns rd=25ns) ---");
        do_reset();
        fork
            write_words(20);
            read_words(20);
        join
        drain();
        check_credits("wr_faster");
        check_sb("wr_faster");


        // ── 2. rd faster (within f_rd/f_wr < 2 constraint) ───────────────
        WR_HALF = 12.5; RD_HALF = 7.0;  // wr=25ns  rd=14ns  ratio=0.56
        $display("\n--- 2. rd faster within constraint (wr=25ns rd=14ns) ---");
        do_reset();
        fork
            write_words(20);
            read_words(20);
        join
        drain();
        check_credits("rd_faster");
        check_sb("rd_faster");


        // ── 3. equal clocks ───────────────────────────────────────────────
        WR_HALF = 7.5; RD_HALF = 7.5;   // wr=15ns  rd=15ns
        $display("\n--- 3. equal clocks (15ns/15ns) ---");
        do_reset();
        fork
            write_words(24);
            read_words(24);
        join
        drain();
        check_credits("equal");
        check_sb("equal");


        // ── 4. back-pressure ──────────────────────────────────────────────
        WR_HALF = 5.0; RD_HALF = 5.0;   // wr=10ns  rd=10ns
        $display("\n--- 4. back-pressure (10ns/10ns, random rd_ready) ---");
        do_reset();
        fork
            write_words(16);
            read_words_bp(16);
        join
        drain();
        check_credits("backpressure");
        check_sb("backpressure");


        // ── 5. async ratio 7:11 ───────────────────────────────────────────
        WR_HALF = 3.5; RD_HALF = 5.5;   // wr=7ns  rd=11ns
        $display("\n--- 5. async ratio 7:11 ---");
        do_reset();
        fork
            write_words(20);
            read_words(20);
        join
        drain();
        check_credits("async_7_11");
        check_sb("async_7_11");


        // ── 6. fill to full, check backstop, then drain ───────────────────
        WR_HALF = 5.0; RD_HALF = 5.0;
        $display("\n--- 6. fill-to-full then drain ---");
        do_reset();
        rd_ready = 0;

        // fill until DUT raises wr_full
        begin
            int written = 0;
            @(posedge wr_clk);
            while (!dut.wr_full) begin
                wr_valid = 1;
                wr_data  = $urandom();
                @(posedge wr_clk);
                scoreboard.push_back(wr_data);
                wr_count++;
                written++;
                wr_valid = 0;
                @(posedge wr_clk);  // one idle so full propagates
            end
            $display("  wrote %0d entries before full", written);
        end

        // extra write attempt must be blocked
        @(posedge wr_clk);
        wr_valid = 1; wr_data = 32'hDEAD_BEEF;
        @(posedge wr_clk);
        if (!dut.wr_full)
            $error("[full_drain] OVERFLOW: wrote into a full FIFO");
        else
            $display("[full_drain] PASS  overflow correctly blocked");
        wr_valid = 0;

        drain();
        check_credits("full_drain");
        check_sb("full_drain");


        // ── Done ──────────────────────────────────────────────────────────
        repeat (20) @(posedge wr_clk);
        $display("\n=== all scenarios complete ===");
        $finish;
    end

    // Watchdog
    initial begin
        #1_000_000;
        $error("[WATCHDOG] simulation exceeded 1ms");
        $finish;
    end

endmodule