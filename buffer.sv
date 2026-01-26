module buffer #(
    parameter int DEPTH = 1024,           // FIFO depth
    parameter int WIDTH = 32,             // Data width in bits
    parameter int ADDR_W = $clog2(DEPTH)  // Address width
)(
    // write Clock Domain (Receiver side)
    input  logic              re_clk,       // Write/Receiver clock
    input  logic              re_reset_n,   // Active-low write reset
    input  logic              re_valid,     // Write valid signal
    input  logic [WIDTH-1:0]  data_in,      // Write data
    output logic [ADDR_W:0]   re_credit,    // Available write credits (free space)

    // read Clock Domain (Transmitter side)
    input  logic              te_clk,       // Read/Transmitter clock
    input  logic              te_reset_n,   // Active-low read reset
    input  logic              te_ready,     // Read ready (consumer ready)
    output logic              te_valid,     // Read valid signal
    output logic [WIDTH-1:0]  te_data_out   // Read data
);

    // memory Array (write clock domain only)
    logic [WIDTH-1:0] mem [0:DEPTH-1];
    logic [ADDR_W:0] wr_ptr_bin, rd_ptr_bin;
    logic [ADDR_W:0] wr_ptr_gray, rd_ptr_gray;
    
    // synchronized gray pointers in opposite domains
    logic [ADDR_W:0] wr_ptr_gray_sync1, wr_ptr_gray_sync2;
    logic [ADDR_W:0] rd_ptr_gray_sync1, rd_ptr_gray_sync2;  

    logic [ADDR_W:0] wr_ptr_bin_synced; 
    logic [ADDR_W:0] rd_ptr_bin_synced;  

    wire wr_enable = re_valid && (re_credit != 0);

    // write clock domain implementation

    always_ff @(posedge re_clk or negedge re_reset_n) begin
        if (!re_reset_n) begin
            wr_ptr_bin <= '0;
            wr_ptr_gray <= '0;
        end else if (wr_enable) begin
            wr_ptr_bin <= wr_ptr_bin + 1'b1;
            wr_ptr_gray <= (wr_ptr_bin + 1'b1) ^ ((wr_ptr_bin + 1'b1) >> 1);
        end
    end
    
    // memory write operation (only in write clock domain)
    always_ff @(posedge re_clk) begin
        if (wr_enable) begin
            mem[wr_ptr_bin[ADDR_W-1:0]] <= data_in;
        end
    end
    
    // two-stage synchronizer: read pointer gray code from read to write domain
    always_ff @(posedge re_clk or negedge re_reset_n) begin
        if (!re_reset_n) begin
            rd_ptr_gray_sync1 <= '0;
            rd_ptr_gray_sync2 <= '0;
        end else begin
            rd_ptr_gray_sync1 <= rd_ptr_gray;      
            rd_ptr_gray_sync2 <= rd_ptr_gray_sync1;
        end
    end
    
    // gray to binary conversion for synchronized read pointer
    always_comb begin
        rd_ptr_bin_synced[ADDR_W] = rd_ptr_gray_sync2[ADDR_W];
        for (int i = ADDR_W-1; i >= 0; i--) begin
            rd_ptr_bin_synced[i] = rd_ptr_bin_synced[i+1] ^ rd_ptr_gray_sync2[i];
        end
    end

    assign re_credit = DEPTH[ADDR_W:0] - (wr_ptr_bin - rd_ptr_bin_synced);

    // read clock domain implementation
    wire data_available = (wr_ptr_bin_synced != rd_ptr_bin);
    wire rd_enable = te_ready && data_available;
    
    // read pointer binary counter and gray code generation
    always_ff @(posedge te_clk or negedge te_reset_n) begin
        if (!te_reset_n) begin
            rd_ptr_bin <= '0;
            rd_ptr_gray <= '0;
        end else if (rd_enable) begin
            rd_ptr_bin <= rd_ptr_bin + 1'b1;
            rd_ptr_gray <= (rd_ptr_bin + 1'b1) ^ ((rd_ptr_bin + 1'b1) >> 1);
        end
    end
    
    // two-stage synchronizer: Write pointer Gray code from write to read domain
    always_ff @(posedge te_clk or negedge te_reset_n) begin
        if (!te_reset_n) begin
            wr_ptr_gray_sync1 <= '0;
            wr_ptr_gray_sync2 <= '0;
        end else begin
            wr_ptr_gray_sync1 <= wr_ptr_gray;      
            wr_ptr_gray_sync2 <= wr_ptr_gray_sync1; 
        end
    end
    
    // gray to binary conversion for synchronized write pointer
    always_comb begin
        wr_ptr_bin_synced[ADDR_W] = wr_ptr_gray_sync2[ADDR_W];
        for (int i = ADDR_W-1; i >= 0; i--) begin
            wr_ptr_bin_synced[i] = wr_ptr_bin_synced[i+1] ^ wr_ptr_gray_sync2[i];
        end
    end
    
    // read data output: memory read is asynchronous, but output is registered in read domain
    always_ff @(posedge te_clk or negedge te_reset_n) begin
        if (!te_reset_n) begin
            te_valid <= 1'b0;
            te_data_out <= '0;
        end else begin
            if (rd_enable) begin
                te_data_out <= mem[rd_ptr_bin[ADDR_W-1:0]];
                te_valid <= 1'b1;
            end else begin
                te_valid <= 1'b0;
            end
        end
    end

endmodule