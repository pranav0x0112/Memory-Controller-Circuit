module buffer #(
    parameter int DEPTH  = 16,           // slots: round_trip(10) + CDC(4) + guard(2)
    parameter int WIDTH  = 32,           // data word width in bits
    parameter int ADDR_W = $clog2(DEPTH) // bits needed to address DEPTH slots
)(
    input  logic             re_clk,          // receiver clock domain
    input  logic             re_reset_n,      // receiver reset, active low
    input  logic             re_valid,        // source sending a word now
    input  logic [WIDTH-1:0] data_in,         // word from source
    output logic             re_credit_pulse, // pulse per freed slot

    input  logic             te_clk,          // transmitter clock domain
    input  logic             te_reset_n,      // transmitter reset, active low
    input  logic             te_ready,        // consumer ready to receive
    output logic             te_valid,        // word on output is valid
    output logic [WIDTH-1:0] te_data_out      // word to consumer
);

    logic [WIDTH-1:0]  mem [0:DEPTH-1]; // backing storage array
    logic [ADDR_W-1:0] wr_ptr;          // next slot to write into
    logic [ADDR_W-1:0] rd_ptr;          // next slot to read from

    // source is trusted — write unconditionally when valid
    always_ff @(posedge re_clk or negedge re_reset_n) begin
        if (!re_reset_n) begin
            wr_ptr <= '0;
        end else if (re_valid) begin
            mem[wr_ptr] <= data_in;       // store word at current slot
            wr_ptr      <= wr_ptr + 1'b1; // advance, wraps at DEPTH
        end
    end

    logic [ADDR_W-1:0] wr_ptr_gray;       // gray-encoded write pointer
    logic [ADDR_W-1:0] wr_ptr_gray_sync1; // sync stage 1, metastability FF
    logic [ADDR_W-1:0] wr_ptr_gray_sync2; // sync stage 2, safe to use
    logic [ADDR_W-1:0] wr_ptr_bin_synced; // decoded back to binary in te domain

    // encode before crossing — only 1 bit changes per increment
    always_ff @(posedge re_clk or negedge re_reset_n) begin
        if (!re_reset_n) wr_ptr_gray <= '0;
        else             wr_ptr_gray <= wr_ptr ^ (wr_ptr >> 1);
    end

    // two-stage sync brings gray pointer safely into te_clk
    always_ff @(posedge te_clk or negedge te_reset_n) begin
        if (!te_reset_n) begin
            wr_ptr_gray_sync1 <= '0;
            wr_ptr_gray_sync2 <= '0;
        end else begin
            wr_ptr_gray_sync1 <= wr_ptr_gray;
            wr_ptr_gray_sync2 <= wr_ptr_gray_sync1;
        end
    end

    // decode synced gray back to binary for pointer comparison
    always_comb begin
        wr_ptr_bin_synced[ADDR_W-1] = wr_ptr_gray_sync2[ADDR_W-1];
        for (int i = ADDR_W-2; i >= 0; i--)
            wr_ptr_bin_synced[i] = wr_ptr_bin_synced[i+1] ^ wr_ptr_gray_sync2[i];
    end

    wire rd_enable = te_ready && (wr_ptr_bin_synced != rd_ptr); // fire when data exists and consumer ready

    // registered output — sample memory, advance pointer, drive valid
    always_ff @(posedge te_clk or negedge te_reset_n) begin
        if (!te_reset_n) begin
            rd_ptr      <= '0;
            te_valid    <= 1'b0;
            te_data_out <= '0;
        end else begin
            if (rd_enable) begin
                te_data_out <= mem[rd_ptr];   // latch word for consumer
                rd_ptr      <= rd_ptr + 1'b1; // advance, wraps at DEPTH
                te_valid    <= 1'b1;
            end else begin
                te_valid <= 1'b0;             // nothing to give consumer
            end
        end
    end

    logic te_rd_toggle; // flips every read — transition IS the event

    // toggle instead of pulse — safe to cross any clock ratio
    always_ff @(posedge te_clk or negedge te_reset_n) begin
        if (!te_reset_n)    te_rd_toggle <= 1'b0;
        else if (rd_enable) te_rd_toggle <= ~te_rd_toggle;
    end

    logic re_rd_sync1; // stage 1 — metastability FF
    logic re_rd_sync2; // stage 2 — resolved, safe
    logic re_rd_sync3; // stage 3 — delayed copy for edge detect

    // three FFs: two to resolve metastability, one to catch the edge
    always_ff @(posedge re_clk or negedge re_reset_n) begin
        if (!re_reset_n) begin
            re_rd_sync1 <= 1'b0;
            re_rd_sync2 <= 1'b0;
            re_rd_sync3 <= 1'b0;
        end else begin
            re_rd_sync1 <= te_rd_toggle; // sample toggle in re domain
            re_rd_sync2 <= re_rd_sync1;
            re_rd_sync3 <= re_rd_sync2;
        end
    end

    // disagreement between sync2 and sync3 means a transition just landed
    assign re_credit_pulse = re_rd_sync2 ^ re_rd_sync3;

endmodule