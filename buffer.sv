module buffer #(
    parameter int DEPTH = 1024,
    parameter int WIDTH = 32,
    parameter int ADDR_W = $clog2(DEPTH),
    parameter int SYNC_STAGES = 2 
)(
    input  logic              re_clk,
    input  logic              re_reset,
    input  logic              re_valid,
    input  logic [WIDTH-1:0]  data_in,
    output logic [ADDR_W:0]   re_credit,
    input  logic              te_clk,
    input  logic              te_reset,
    input  logic              te_ready,
    output logic              te_valid,
    output logic [WIDTH-1:0]  te_data_out
);

    localparam int CDC_MARGIN = (SYNC_STAGES * 2) + 2;  
    localparam int SAFE_DEPTH = DEPTH - CDC_MARGIN;
    
    logic [WIDTH-1:0] mem [0:DEPTH-1];
    logic [ADDR_W-1:0] wr_ptr, rd_ptr;
    logic [ADDR_W:0] credit_count, rd_count;
    
    logic credit_toggle, credit_sync1, credit_sync2, credit_sync_prev;
    logic wr_toggle, wr_sync1, wr_sync2, wr_sync_prev;
    
    wire wr_fire = re_valid && (re_credit != 0);
    
    // WRITE DOMAIN
    always_ff @(posedge re_clk or posedge re_reset) begin
        if (re_reset) begin
            wr_ptr <= 0;
            credit_count <= SAFE_DEPTH[ADDR_W:0];
            wr_toggle <= 0;
            credit_sync_prev <= 0;
        end else begin
            credit_sync_prev <= credit_sync2;
            
            if (wr_fire) begin
                mem[wr_ptr] <= data_in;
                wr_ptr <= wr_ptr + 1;
                wr_toggle <= ~wr_toggle;
            end
            
            if ((credit_sync2 != credit_sync_prev) && wr_fire) begin
                credit_count <= credit_count; 
            end else if (credit_sync2 != credit_sync_prev) begin
                credit_count <= credit_count + 1;
            end else if (wr_fire) begin
                credit_count <= credit_count - 1;  
            end
        end
    end
    
    assign re_credit = credit_count;
    
    always_ff @(posedge te_clk or posedge te_reset) begin
        if (te_reset) begin
            wr_sync1 <= 0;
            wr_sync2 <= 0;
        end else begin
            wr_sync1 <= wr_toggle;
            wr_sync2 <= wr_sync1;
        end
    end
    
    // READ DOMAIN
    always_ff @(posedge te_clk or posedge te_reset) begin
        if (te_reset) begin
            rd_ptr <= 0;
            rd_count <= 0;
            te_valid <= 0;
            credit_toggle <= 0;
            wr_sync_prev <= 0;
        end else begin
            if ((wr_sync2 != wr_sync_prev) && (te_ready && rd_count > 0)) begin
                rd_count <= rd_count;  
            end else if (wr_sync2 != wr_sync_prev) begin
                rd_count <= rd_count + 1;  
            end else if (te_ready && rd_count > 0) begin
                rd_count <= rd_count - 1; 
            end
            
            wr_sync_prev <= wr_sync2;
            if (te_ready && rd_count > 0) begin
                te_data_out <= mem[rd_ptr];
                te_valid <= 1;
                rd_ptr <= rd_ptr + 1;
                credit_toggle <= ~credit_toggle;
            end else begin
                te_valid <= 0;
            end
        end
    end
    
    always_ff @(posedge re_clk or posedge re_reset) begin
        if (re_reset) begin
            credit_sync1 <= 0;
            credit_sync2 <= 0;
        end else begin
            credit_sync1 <= credit_toggle;
            credit_sync2 <= credit_sync1;
        end
    end
endmodule