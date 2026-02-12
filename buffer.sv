module buffer #(
    parameter int DEPTH  = 16,           // 10 (round trip) + 4 (CDC) + 2 (guard)
    parameter int WIDTH  = 32,
    parameter int ADDR_W = $clog2(DEPTH)
)(
    input  logic             re_clk,
    input  logic             re_reset_n,
    input  logic             re_valid,
    input  logic [WIDTH-1:0] data_in,
    output logic             re_credit_pulse,

    input  logic             te_clk,
    input  logic             te_reset_n,
    input  logic             te_ready,
    output logic             te_valid,
    output logic [WIDTH-1:0] te_data_out
);

    logic [WIDTH-1:0]  mem [0:DEPTH-1];
    logic [ADDR_W-1:0] wr_ptr;
    logic [ADDR_W-1:0] rd_ptr;

    // source owns the credit counter so we just write whenever valid comes in,
    // no local credit check needed here
    always_ff @(posedge re_clk or negedge re_reset_n) begin
        if (!re_reset_n) begin
            wr_ptr <= '0;
        end else if (re_valid) begin
            mem[wr_ptr] <= data_in;
            wr_ptr      <= wr_ptr + 1'b1;
        end
    end

    // write pointer needs to cross into the read domain so the read side
    // knows when there is data waiting — gray code makes this safe
    logic [ADDR_W-1:0] wr_ptr_gray;
    logic [ADDR_W-1:0] wr_ptr_gray_sync1, wr_ptr_gray_sync2;
    logic [ADDR_W-1:0] wr_ptr_bin_synced;

    always_ff @(posedge re_clk or negedge re_reset_n) begin
        if (!re_reset_n) wr_ptr_gray <= '0;
        else             wr_ptr_gray <= wr_ptr ^ (wr_ptr >> 1);
    end

    always_ff @(posedge te_clk or negedge te_reset_n) begin
        if (!te_reset_n) begin
            wr_ptr_gray_sync1 <= '0;
            wr_ptr_gray_sync2 <= '0;
        end else begin
            wr_ptr_gray_sync1 <= wr_ptr_gray;
            wr_ptr_gray_sync2 <= wr_ptr_gray_sync1;
        end
    end

    always_comb begin
        wr_ptr_bin_synced[ADDR_W-1] = wr_ptr_gray_sync2[ADDR_W-1];
        for (int i = ADDR_W-2; i >= 0; i--)
            wr_ptr_bin_synced[i] = wr_ptr_bin_synced[i+1] ^ wr_ptr_gray_sync2[i];
    end

    // read side just checks if write pointer has moved ahead of read pointer
    wire rd_enable = te_ready && (wr_ptr_bin_synced != rd_ptr);

    always_ff @(posedge te_clk or negedge te_reset_n) begin
        if (!te_reset_n) begin
            rd_ptr      <= '0;
            te_valid    <= 1'b0;
            te_data_out <= '0;
        end else begin
            if (rd_enable) begin
                te_data_out <= mem[rd_ptr];
                rd_ptr      <= rd_ptr + 1'b1;
                te_valid    <= 1'b1;
            end else begin
                te_valid    <= 1'b0;
            end
        end
    end

    // every time a read happens we need to tell the source a slot just freed up
    // a raw pulse would be too short to cross clock domains safely so we
    // toggle a bit instead — the transition itself carries the information
    logic te_rd_toggle;

    always_ff @(posedge te_clk or negedge te_reset_n) begin
        if (!te_reset_n)    te_rd_toggle <= 1'b0;
        else if (rd_enable) te_rd_toggle <= ~te_rd_toggle;
    end

    // bring that toggle safely into re_clk with two flip flops,
    // then a third just to compare against so we can spot the edge
    logic re_rd_sync1, re_rd_sync2, re_rd_sync3;

    always_ff @(posedge re_clk or negedge re_reset_n) begin
        if (!re_reset_n) begin
            re_rd_sync1 <= 1'b0;
            re_rd_sync2 <= 1'b0;
            re_rd_sync3 <= 1'b0;
        end else begin
            re_rd_sync1 <= te_rd_toggle;
            re_rd_sync2 <= re_rd_sync1;
            re_rd_sync3 <= re_rd_sync2;
        end
    end

    // when sync2 and sync3 disagree a transition just landed —
    // that is exactly one re_clk wide pulse the source can count as a returned credit
    assign re_credit_pulse = re_rd_sync2 ^ re_rd_sync3;

endmodule