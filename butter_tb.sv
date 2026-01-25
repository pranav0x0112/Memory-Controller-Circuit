`timescale 1ns/1ps

module buffer_tb;

    parameter int DEPTH = 16; 
    parameter int WIDTH = 32;
    parameter int ADDR_W = $clog2(DEPTH);

    parameter real WR_CLK_PERIOD = 10; 
    parameter real RD_CLK_PERIOD = 15; 

    logic              re_clk;
    logic              re_reset;
    logic              re_valid;
    logic [WIDTH-1:0]  data_in;
    logic [ADDR_W:0]   re_credit;
    
    logic              te_clk;
    logic              te_reset;
    logic              te_ready;
    logic              te_valid;
    logic [WIDTH-1:0]  te_data_out;

    int write_count = 0;
    int read_count = 0;
    int error_count = 0;

    logic [WIDTH-1:0] expected_data_queue[$];
    
    buffer #(
        .DEPTH(DEPTH),
        .WIDTH(WIDTH),
        .ADDR_W(ADDR_W)
    ) dut (
        .re_clk(re_clk),
        .re_reset(re_reset),
        .re_valid(re_valid),
        .data_in(data_in),
        .re_credit(re_credit),
        .te_clk(te_clk),
        .te_reset(te_reset),
        .te_ready(te_ready),
        .te_valid(te_valid),
        .te_data_out(te_data_out)
    );
    
    initial begin
        re_clk = 0;
        forever #(WR_CLK_PERIOD/2) re_clk = ~re_clk;
    end
    
    initial begin
        te_clk = 0;
        forever #(RD_CLK_PERIOD/2) te_clk = ~te_clk;
    end

    always @(posedge re_clk) begin
        if (!re_reset && re_valid && re_credit != 0) begin
            $display("[WRITE] Time=%0t, Data=0x%08h, Ptr=%0d, Credits=%0d", 
                     $time, data_in, dut.wr_ptr, re_credit);
            expected_data_queue.push_back(data_in);
            write_count++;
        end
    end
    
    always @(posedge te_clk) begin
        if (!te_reset && te_valid && te_ready) begin
            logic [WIDTH-1:0] expected;
            
            if (expected_data_queue.size() > 0) begin
                expected = expected_data_queue.pop_front();
                
                if (te_data_out !== expected) begin
                    $error("[READ ERROR] Time=%0t, Expected=0x%08h, Got=0x%08h", 
                           $time, expected, te_data_out);
                    error_count++;
                end else begin
                    $display("[READ OK] Time=%0t, Data=0x%08h, Ptr=%0d", 
                             $time, te_data_out, dut.rd_ptr);
                end
            end else begin
                $error("[READ ERROR] Unexpected read! No data expected but got 0x%08h", 
                       te_data_out);
                error_count++;
            end
            
            read_count++;
        end
    end

    logic [ADDR_W:0] prev_credit;
    always @(posedge re_clk) begin
        if (!re_reset) begin
            if (re_credit !== prev_credit) begin
                $display("[CREDIT] Time=%0t, Credits: %0d -> %0d (Change: %0d)", 
                         $time, prev_credit, re_credit, 
                         $signed(re_credit) - $signed(prev_credit));
            end
            prev_credit <= re_credit;
        end
    end

    task reset_system();
        re_reset = 1;
        te_reset = 1;
        re_valid = 0;
        te_ready = 0;
        data_in = 0;
        
        repeat(5) @(posedge re_clk);
        re_reset = 0;
        
        repeat(5) @(posedge te_clk);
        te_reset = 0;
        
        repeat(10) @(posedge re_clk);
        $display("\n=== RESET COMPLETE ===\n");
    endtask

    task automatic write_items(int count, bit random_gaps = 0);
        int i;
        for (i = 0; i < count; i++) begin
            re_valid = 1;
            data_in = $random;
            @(posedge re_clk);
            re_valid = 0;
            @(posedge re_clk);
            
            if (random_gaps && ($urandom % 4 == 0)) begin
                @(posedge re_clk);
            end
        end
    endtask

    task test_cdc_latency();
        int initial_credits;
        int writes_before_stop;
        
        $display("\n========================================");
        $display("TEST: CDC Latency Analysis");
        $display("========================================\n");

        $display("Step 1: Writing %0d items to partially fill buffer...", DEPTH - 5);
        write_items(DEPTH - 5, 0);
        repeat(20) @(posedge re_clk);  
        
        initial_credits = re_credit;
        $display("Credits after partial fill: %0d", initial_credits);
        $display("Expected credits: ~5\n");

        $display("Step 2: Writing continuously until credits exhausted...");
        writes_before_stop = 0;
        
        fork
            begin
                repeat(20) begin
                    @(posedge re_clk);
                    re_valid = 1;
                    data_in = $random;
                    if (re_credit > 0) writes_before_stop++;
                    @(posedge re_clk);
                    re_valid = 0;
                end
            end
        join
        
        $display("Writes completed before credit exhaustion: %0d", writes_before_stop);
        $display("Final credits: %0d", re_credit);
        $display("Write pointer: %0d, Read pointer: %0d\n", dut.wr_ptr, dut.rd_ptr);

        $display("Step 3: Reading to return credits...");
        fork
            begin
                te_ready = 1;
                repeat(100) @(posedge te_clk);
                te_ready = 0;
            end
            begin
                repeat(30) begin
                    @(posedge re_clk);
                    if (re_credit > 0) begin
                        $display("  [CDC] Credits returned! Credits=%0d at time=%0t", 
                                 re_credit, $time);
                    end
                end
            end
        join
        
        repeat(50) @(posedge re_clk); 
        $display("Final credits after reads: %0d\n", re_credit);
    endtask

    task test_wraparound_scenario();
        int wr_ptr_before, rd_ptr_before;
        int safe_writes;
        
        $display("\n========================================");
        $display("TEST: Wraparound Scenario");
        $display("Buffer depth = %0d", DEPTH);
        $display("========================================\n");

        $display("Step 1: Filling buffer close to wraparound...");
        write_items(DEPTH - 2, 0);
        repeat(20) @(posedge re_clk);
        
        wr_ptr_before = dut.wr_ptr;
        $display("Write pointer at: %0d (next write wraps to 0)", wr_ptr_before);

        $display("\nStep 2: Reading 6 items to create space...");
        te_ready = 1;
        repeat(200) @(posedge te_clk);
        te_ready = 0;
        repeat(30) @(posedge re_clk);  
        
        rd_ptr_before = dut.rd_ptr;
        $display("Read pointer now at: %0d", rd_ptr_before);
        $display("Credits available: %0d", re_credit);
        $display("Physical space: positions 0-5 are free (6 slots)");
        $display("But with 2-stage sync, safe credits should be ~3-4\n");

        $display("Step 3: Writing continuously to test CDC safety margin...");
        safe_writes = 0;
        
        repeat(10) begin
            @(posedge re_clk);
            if (re_credit > 0) begin
                re_valid = 1;
                data_in = $random;
                safe_writes++;
                $display("  Write %0d: ptr=%0d, credits=%0d", 
                         safe_writes, dut.wr_ptr, re_credit);
                @(posedge re_clk);
                re_valid = 0;
            end else begin
                re_valid = 0;
                $display("  STOPPED: Credits exhausted at ptr=%0d", dut.wr_ptr);
            end
        end
        re_valid = 0;
        
        $display("\nResults:");
        $display("  Total safe writes before stop: %0d", safe_writes);
        $display("  Write pointer stopped at: %0d", dut.wr_ptr);
        $display("  Read pointer at: %0d", dut.rd_ptr);
        $display("  Safety margin: %0d positions", 
                 (rd_ptr_before - dut.wr_ptr + DEPTH) % DEPTH);
        $display("\nExpected: Stop at position 1-3 (with 2-stage synchronizer)");
        $display("Actual stop position: %0d\n", dut.wr_ptr);
    endtask

    task test_burst_transfers();
        $display("\n========================================");
        $display("TEST: Burst Transfers");
        $display("========================================\n");
        
        fork
            begin
                $display("Writing 30 items with random gaps...");
                write_items(30, 1);
            end
            begin
                #2000;
                $display("Reading 30 items with random gaps...");
                te_ready = 1;
                repeat(2000) @(posedge te_clk);
                te_ready = 0;
            end
        join
        
        repeat(50) @(posedge re_clk);
        $display("Burst test complete.\n");
    endtask

task test_overflow_protection();
    $display("\n========================================");
    $display("TEST: Overflow Protection");
    $display("========================================\n");
    
    $display("Attempting to write %0d items (more than depth %0d)...", 
             DEPTH + 10, DEPTH);
    
    fork
        begin
            write_items(DEPTH + 10, 0);
        end
    join
    
    repeat(50) @(posedge re_clk);
    
    if (re_credit == 0) begin
        $display("✓ PASS: Buffer correctly stopped accepting writes");
        $display("  Final credits: %0d", re_credit);
    end else begin
        $error("✗ FAIL: Buffer should have zero credits!");
    end
    
    // FLUSH THE BUFFER!
    $display("Flushing buffer...");
    te_ready = 1;
    repeat(100) @(posedge te_clk);
    te_ready = 0;
    repeat(20) @(posedge re_clk);
endtask

    initial begin
        $display("\n");
        $display("╔═══════════════════════════════════════════════════════╗");
        $display("║     DUAL-CLOCK FIFO TESTBENCH WITH CDC ANALYSIS       ║");
        $display("╚═══════════════════════════════════════════════════════╝");
        $display("\nConfiguration:");
        $display("  Buffer Depth: %0d", DEPTH);
        $display("  Data Width: %0d bits", WIDTH);
        $display("  Write Clock: %0.1f MHz", 1000.0/WR_CLK_PERIOD);
        $display("  Read Clock: %0.1f MHz", 1000.0/RD_CLK_PERIOD);
        $display("  Synchronizer stages: 2");
        $display("\n");

        reset_system();

        test_burst_transfers();
        reset_system();
        
        test_overflow_protection();
        reset_system();
        
        test_cdc_latency();
        reset_system();
        
        test_wraparound_scenario();
        $display("\nDraining remaining buffer contents...");
        te_ready = 1;
        repeat(200) @(posedge te_clk); 
        te_ready = 0;
        
        repeat(50) @(posedge re_clk);
        
        $display("After drain: Pending items = %0d\n", expected_data_queue.size());
        
        $display("\n");
        $display("╔═══════════════════════════════════════════════════════╗");
        $display("║                    TEST SUMMARY                       ║");
        $display("╚═══════════════════════════════════════════════════════╝");
        $display("  Total Writes: %0d", write_count);
        $display("  Total Reads: %0d", read_count);
        $display("  Errors: %0d", error_count);
        $display("  Pending in queue: %0d", expected_data_queue.size());
        
        if (error_count == 0 && expected_data_queue.size() == 0) begin
            $display("\n  ✓✓✓ ALL TESTS PASSED ✓✓✓\n");
        end else begin
            $display("\n  ✗✗✗ TESTS FAILED ✗✗✗\n");
        end
        
        $finish;
    end

    initial begin
        $dumpfile("buffer_tb.vcd");
        $dumpvars(0, buffer_tb);
    end

endmodule