// metastability synchronizer
module cdc_sync #(
    parameter int unsigned W = 1
) (
    input  logic         clk,   // destination clock always
    input  logic         rst_n, // negative reset
    input  logic [W-1:0] d,     // data_in
    output logic [W-1:0] q      // data_out
);
    // ASYNC_REG: prevents tool merging s1/s2, co-locates them in same slice,
    // auto-applies set_false_path in STA. On ASIC replace with foundry sync_cell.
    (* ASYNC_REG = "TRUE" *) logic [W-1:0] s1, s2;

    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) {s2, s1} <= '0;
        else        {s2, s1} <= {s1, d};

    assign q = s2;
endmodule



module async_fifo_credit #(
    parameter int unsigned RT_TOTAL = 10,            // total round-trip (cycles)
    parameter int unsigned RT_CDC   = 4,             // CDC synchronizer round-trip
    parameter int unsigned DEPTH    = 16,            // must be pow2, >= RT_TOTAL
    parameter int unsigned ADDR_W   = $clog2(DEPTH), // 4
    parameter int unsigned PTR_W    = ADDR_W + 1,    // 5  (MSB = wrap bit)
    parameter int unsigned DATA_W   = 32
) (
    // Write domain
    input  logic              wr_clk,           // source clock
    input  logic              wr_rst_n,         // negative reset
    input  logic              wr_valid,         // source has data
    input  logic [DATA_W-1:0] wr_data,          // data_in
    output logic              wr_credit_pulse,  // 1-cycle pulse per completed read

    // Read domain
    input  logic              rd_clk,           // receiver clock
    input  logic              rd_rst_n,         // negative reset
    output logic              rd_valid,         // data available
    input  logic              rd_ready,         // consumer accepts
    output logic [DATA_W-1:0] rd_data           // data_out
);

    // storage
    logic [DATA_W-1:0] mem [0:DEPTH-1];

    // Write-domain signals
    logic [PTR_W-1:0] wr_ptr_bin;            // binary write pointer
    logic [PTR_W-1:0] wr_ptr_gray;           // Gray write pointer (→ rd domain)
    logic [PTR_W-1:0] rd_ptr_gray_sync_wr;   // rd Gray ptr synced into wr domain
    logic [PTR_W-1:0] rd_ptr_bin_wr;         // rd ptr decoded in wr domain
    logic             wr_full;               // full flag
    logic             credit_toggle_sync_wr; // credit toggle synced into wr domain
    logic             credit_toggle_prev_wr; // previous value for edge detect

    // Read-domain signals
    logic [PTR_W-1:0] rd_ptr_bin;            // binary read pointer
    logic [PTR_W-1:0] rd_ptr_gray;           // Gray read pointer (→ wr domain)
    logic [PTR_W-1:0] wr_ptr_gray_sync_rd;   // wr Gray ptr synced into rd domain
    logic [PTR_W-1:0] wr_ptr_bin_rd;         // wr ptr decoded in rd domain (monitor)
    logic             rd_empty;              // empty flag
    logic             credit_toggle_rd;      // toggles once per successful read


    // Write Domain
    always_ff @(posedge wr_clk or negedge wr_rst_n)
        if (!wr_rst_n) wr_ptr_bin <= '0;
        else if (wr_valid && !wr_full) wr_ptr_bin <= wr_ptr_bin + 1'b1;

    always_ff @(posedge wr_clk)
        if (wr_valid && !wr_full)
            mem[wr_ptr_bin[ADDR_W-1:0]] <= wr_data;

    assign wr_ptr_gray = wr_ptr_bin ^ (wr_ptr_bin >> 1); // bin → Gray


    // Read Domain
    assign rd_empty = (rd_ptr_gray == wr_ptr_gray_sync_rd);
    assign rd_valid = !rd_empty;
    assign rd_data  = mem[rd_ptr_bin[ADDR_W-1:0]];

    always_ff @(posedge rd_clk or negedge rd_rst_n)
        if (!rd_rst_n) rd_ptr_bin <= '0;
        else if (rd_valid && rd_ready) rd_ptr_bin <= rd_ptr_bin + 1'b1;

    assign rd_ptr_gray = rd_ptr_bin ^ (rd_ptr_bin >> 1); // bin → Gray


    // CREDIT TOGGLE  (rd_clk)
    always_ff @(posedge rd_clk or negedge rd_rst_n)
        if (!rd_rst_n) credit_toggle_rd <= 1'b0;
        else if (rd_valid && rd_ready) credit_toggle_rd <= ~credit_toggle_rd;


    // FULL FLAG  (wr_clk)
    // full: lower bits equal (same slot) AND wrap bits differ (wr lapped rd)
    always_comb begin : gray2bin_rd_in_wr
        rd_ptr_bin_wr[PTR_W-1] = rd_ptr_gray_sync_wr[PTR_W-1];
        for (int i = PTR_W-2; i >= 0; i--)
            rd_ptr_bin_wr[i] = rd_ptr_bin_wr[i+1] ^ rd_ptr_gray_sync_wr[i];
    end

    assign wr_full = (wr_ptr_bin[ADDR_W-1:0] == rd_ptr_bin_wr[ADDR_W-1:0]) &&
                     (wr_ptr_bin[ADDR_W]      != rd_ptr_bin_wr[ADDR_W]);

    // gray2bin in rd domain  (occupancy monitor — not in control path)
    always_comb begin : gray2bin_wr_in_rd
        wr_ptr_bin_rd[PTR_W-1] = wr_ptr_gray_sync_rd[PTR_W-1];
        for (int i = PTR_W-2; i >= 0; i--)
            wr_ptr_bin_rd[i] = wr_ptr_bin_rd[i+1] ^ wr_ptr_gray_sync_rd[i];
    end


    // CDC PATH 1  wr_ptr_gray → rd domain
    cdc_sync #(.W(PTR_W)) u_sync_wr_ptr (
        .clk   (rd_clk),
        .rst_n (rd_rst_n),
        .d     (wr_ptr_gray),
        .q     (wr_ptr_gray_sync_rd)
    );

    // CDC PATH 2  rd_ptr_gray → wr domain
    cdc_sync #(.W(PTR_W)) u_sync_rd_ptr (
        .clk   (wr_clk),
        .rst_n (wr_rst_n),
        .d     (rd_ptr_gray),
        .q     (rd_ptr_gray_sync_wr)
    );

    // CDC PATH 3  credit_toggle → wr domain
    cdc_sync #(.W(1)) u_sync_credit (
        .clk   (wr_clk),
        .rst_n (wr_rst_n),
        .d     (credit_toggle_rd),
        .q     (credit_toggle_sync_wr)
    );

    always_ff @(posedge wr_clk or negedge wr_rst_n)
        if (!wr_rst_n) credit_toggle_prev_wr <= 1'b0;
        else           credit_toggle_prev_wr <= credit_toggle_sync_wr;

    assign wr_credit_pulse = credit_toggle_sync_wr ^ credit_toggle_prev_wr;

endmodule